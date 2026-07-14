const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;
const extractBaseType = core.extractBaseType;
const isNullable = core.isNullable;

pub const inferCallExpr = @import("infer_call.zig").inferCallExpr;
pub const inferGetExpr = @import("infer_member.zig").inferGetExpr;
pub const inferSetExpr = @import("infer_member.zig").inferSetExpr;
pub const inferIndexExpr = @import("infer_member.zig").inferIndexExpr;
pub const inferIndexSetExpr = @import("infer_member.zig").inferIndexSetExpr;
pub const inferArrayLiteral = @import("infer_literal.zig").inferArrayLiteral;
pub const inferMapLiteral = @import("infer_literal.zig").inferMapLiteral;


fn isValidType(self: *TypeChecker, t: *const AetherType) bool {
    switch (t.*) {
        .Int, .Bool, .String, .Void, .Null => return true,
        .Pointer => |elem| return isValidType(self, elem),
        .Array => |elem| return isValidType(self, elem),
        .Custom => |name| {
            var actual_name = name;
            if (std.mem.endsWith(u8, actual_name, "Opt")) {
                actual_name = actual_name[0 .. actual_name.len - 3];
            }
            return self.classes_ast.contains(actual_name) or self.global_scope.lookupVariable(actual_name) != null;
        },
        .Union => |u| return isValidType(self, u.left) and isValidType(self, u.right),
        else => return false,
    }
}

pub fn inferAssignment(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const a = node.data.assignment;
    const assigned_type = try self.inferNode(a.value, scope);
    if (scope.lookupVariableSymbol(a.name)) |vs| {
        if (!vs.is_mut) {
            self.reportError(node.line, node.column, "TypeError: Cannot reassign constant variable '{s}'.", .{a.name});
            return error.TypeError;
        }
        const expected = vs.aether_type;
        if (!self.isCompatible(expected, assigned_type)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} when reassigning variable '{s}'.", .{ expected.*, assigned_type.*, a.name });
            return error.TypeError;
        }
    } else {
        self.reportError(node.line, node.column, "TypeError: Undeclared variable '{s}'.", .{a.name});
        return error.TypeError;
    }
    t.* = assigned_type.*;
}

pub fn inferUnaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const u = node.data.unary_expr;
    const op_type = try self.inferNode(u.operand, scope);
    
    if (u.operator == .bang_bang) {
        t.* = extractBaseType(op_type).*;
    } else if (u.operator == .bang) {
        if (op_type.* != .Bool) {
            self.reportError(node.line, node.column, "TypeError: Operator '!' requires a Bool operand, but got {}.", .{op_type.*});
            return error.TypeError;
        }
        t.* = .Bool;
    } else if (u.operator == .minus) {
        if (op_type.* != .Int) {
            self.reportError(node.line, node.column, "TypeError: Operator '-' requires an Int operand, but got {}.", .{op_type.*});
            return error.TypeError;
        }
        t.* = .Int;
    } else {
        self.reportError(node.line, node.column, "TypeError: Unknown unary operator.", .{});
        return error.TypeError;
    }
}

pub fn inferBinaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const b = node.data.binary_expr;
    const left_type = try self.inferNode(b.left, scope);
    const right_type = try self.inferNode(b.right, scope);

    if (b.op == .elvis) {
        const l_base = extractBaseType(left_type);
        if (!self.isCompatible(l_base, right_type)) {
            self.reportError(node.line, node.column, "TypeError: Elvis right-hand side {} is incompatible with left base type {}.", .{ right_type.*, l_base.* });
            return error.TypeError;
        }
        t.* = l_base.*;
        return;
    }

    switch (b.op) {
        .plus => {
            if (left_type.* == .Int and right_type.* == .Int) {
                t.* = .Int;
            } else if (std.meta.activeTag(left_type.*) == .Pointer and right_type.* == .Int) {
                t.* = left_type.*;
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{
                    .line = node.line,
                    .column = node.column,
                    .resolved_type = null,
                    .data = .{ .get_expr = .{ .object = b.left, .name = "plus", .is_safe = false } },
                };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                try inferCallExpr(self, node, scope, t);
            }
        },
        .minus => {
            if (left_type.* == .Int and right_type.* == .Int) {
                t.* = .Int;
            } else if (std.meta.activeTag(left_type.*) == .Pointer and std.meta.activeTag(right_type.*) == .Pointer) {
                t.* = .Int;
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = b.left, .name = "minus", .is_safe = false } } };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                try inferCallExpr(self, node, scope, t);
            }
        },
        .star, .slash => {
            if (left_type.* != .Int or right_type.* != .Int) {
                self.reportError(node.line, node.column, "TypeError: Math operations require Int on both sides. Found {} and {}.", .{ left_type.*, right_type.* });
                return error.TypeError;
            }
            t.* = .Int;
        },
        .eq_eq, .bang_eq, .less, .greater, .less_eq, .greater_eq, .and_and, .or_or => {
            t.* = .Bool;
        },
        .kw_of => {
            const node_ident = try self.allocator.create(ASTNode);
            node_ident.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .identifier = .{ .name = "Node", .resolved_c_name = null } } };
            
            const null_lit = try self.allocator.create(ASTNode);
            null_lit.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .null_literal };
            
            var args = try self.allocator.alloc(*ASTNode, 3);
            args[0] = b.left;
            args[1] = b.right;
            args[2] = null_lit;
            
            node.data = .{ .call_expr = .{ .callee = node_ident, .arguments = args } };
            try inferCallExpr(self, node, scope, t);
        },
        else => return error.TypeError,
    }
}

pub fn inferIdentifier(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var i = &node.data.identifier;
    if (self.alias_map.get(i.name)) |c_name| {
        i.resolved_c_name = c_name;
    }
    if (scope.lookupVariable(i.name)) |found| {
        if (self.current_class_props) |props| {
            if (props.contains(i.name)) {
                i.is_class_property = true;
            }
        }
        t.* = found.*;
        return;
    }
    if (self.alias_map.get(i.name)) |c_name| {
        t.* = .{ .Custom = c_name };
        return;
    }
    self.reportError(node.line, node.column, "TypeError: Undeclared variable '{s}'.", .{i.name});
    return error.TypeError;
}

pub fn inferAsExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const a = node.data.as_expr;
    const val_type = try self.inferNode(a.value, scope);
    const target_type = try self.resolveTypeRef(a.type_ref);

    const base_val = extractBaseType(val_type);
    const base_target = extractBaseType(target_type);

    if (base_val.* == .Custom and base_target.* == .Custom) {
        const is_upcast = self.isSubclassOf(base_val.Custom, base_target.Custom);
        const is_downcast = self.isSubclassOf(base_target.Custom, base_val.Custom);
        if (!is_upcast and !is_downcast) {
            self.reportError(node.line, node.column, "TypeError: Incompatible types for cast: cannot cast {s} to {s}.", .{ base_val.Custom, base_target.Custom });
            return error.TypeError;
        }
    } else {
        if (!self.isCompatible(target_type, val_type)) {
            self.reportError(node.line, node.column, "TypeError: Cannot cast {} to {}.", .{ val_type.*, target_type.* });
            return error.TypeError;
        }
    }

    t.* = target_type.*;
}

pub fn inferIsExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const i = node.data.is_expr;
    const val_type = try self.inferNode(i.value, scope);
    const target_type = try self.resolveTypeRef(i.type_ref);

    const base_val = extractBaseType(val_type);
    const base_target = extractBaseType(target_type);

    if (base_val.* == .Custom and base_target.* == .Custom) {
        const is_upcast = self.isSubclassOf(base_val.Custom, base_target.Custom);
        const is_downcast = self.isSubclassOf(base_target.Custom, base_val.Custom);
        if (!is_upcast and !is_downcast) {
            self.reportError(node.line, node.column, "TypeError: Incompatible types for type check: {s} is not in the inheritance hierarchy of {s}.", .{ base_val.Custom, base_target.Custom });
            return error.TypeError;
        }
    } else {
        if (!self.isCompatible(target_type, val_type)) {
            self.reportError(node.line, node.column, "TypeError: Cannot check if {} is {}.", .{ val_type.*, target_type.* });
            return error.TypeError;
        }
    }

    t.* = .Bool;
}

pub fn inferTernaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const ternary_node = node.data.ternary_expr;
    const cond_type = try self.inferNode(ternary_node.condition, scope);
    
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: Ternary condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    
    const then_type = try self.inferNode(ternary_node.then_branch, scope);
    
    if (ternary_node.else_branch) |else_b| {
        const else_type = try self.inferNode(else_b, scope);
        
        if (self.isCompatible(then_type, else_type)) {
            t.* = then_type.*;
        } else if (self.isCompatible(else_type, then_type)) {
            t.* = else_type.*;
        } else {
            self.reportError(node.line, node.column, "TypeError: Ternary branches have incompatible types: {} and {}.", .{ then_type.*, else_type.* });
            return error.TypeError;
        }
    } else {
        // Short ternary
        if (then_type.* == .Void) {
            self.reportError(node.line, node.column, "TypeError: Short ternary positive branch cannot be Void.", .{});
            return error.TypeError;
        }
        
        if (core.isNullable(then_type)) {
            t.* = then_type.*;
        } else {
            const left_t = try self.allocator.create(AetherType);
            left_t.* = then_type.*;
            const right_t = try self.allocator.create(AetherType);
            right_t.* = .Null;
            t.* = .{ .Union = .{
                .left = left_t,
                .right = right_t,
            } };
        }
    }
}

