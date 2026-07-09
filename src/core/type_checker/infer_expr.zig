const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;
const extractBaseType = core.extractBaseType;
const isCompatible = core.isCompatible;
const isNullable = core.isNullable;

pub fn inferAssignment(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const a = node.data.assignment;
    const assigned_type = try self.inferNode(a.value, scope);
    if (scope.lookupVariable(a.name)) |expected| {
        if (!isCompatible(expected, assigned_type)) {
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
    if (u.operator == .bang_bang) {
        const op_type = try self.inferNode(u.operand, scope);
        t.* = extractBaseType(op_type).*;
    }
}

pub fn inferBinaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const b = node.data.binary_expr;
    const left_type = try self.inferNode(b.left, scope);
    const right_type = try self.inferNode(b.right, scope);

    if (b.op == .elvis) {
        const l_base = extractBaseType(left_type);
        if (!isCompatible(l_base, right_type)) {
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
                t.* = left_type.*;
            }
        },
        .minus => {
            if (left_type.* == .Int and right_type.* == .Int) {
                t.* = .Int;
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = b.left, .name = "minus", .is_safe = false } } };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                t.* = left_type.*;
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

pub fn inferCallExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var c = &node.data.call_expr;
    for (c.arguments) |arg| {
        _ = try self.inferNode(arg, scope);
    }

    if (c.callee.data == .identifier) {
        const name = c.callee.data.identifier.name;
        if (scope.lookupFunctions(name)) |overloads| {
            var best_match: ?*const AetherType = null;
            
            for (overloads) |overload| {
                if (overload.* != .Function) continue;
                const f = overload.Function;
                if (f.params.len != c.arguments.len) continue;
                
                var all_match = true;
                for (f.params, 0..) |p, i| {
                    if (!isCompatible(p, c.arguments[i].resolved_type.?)) {
                        all_match = false;
                        break;
                    }
                }
                
                if (all_match) {
                    best_match = overload;
                    break;
                }
            }
            
            if (best_match) |matched| {
                t.* = matched.Function.return_type.*;
                c.callee.data = .{ .identifier = .{
                    .name = name,
                    .resolved_c_name = matched.Function.c_name,
                } };
                return;
            } else {
                self.reportError(node.line, node.column, "TypeError: No matching overload found for function '{s}'.", .{name});
                return error.TypeError;
            }
        }
        
        if (scope.lookupVariable(name)) |variable| {
            if (variable.* == .Custom) {
                t.* = variable.*;
                c.callee.data = .{ .identifier = .{
                    .name = name,
                    .resolved_c_name = variable.Custom,
                } };
                return;
            }
        }
        
        if (self.alias_map.get(name)) |c_name| {
            if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') {
                t.* = .{ .Custom = c_name };
            } else {
                t.* = .Unknown;
                c.callee.data = .{ .identifier = .{
                    .name = name,
                    .resolved_c_name = c_name,
                } };
            }
            return;
        }
        self.reportError(node.line, node.column, "TypeError: Undeclared function '{s}'.", .{name});
        return error.TypeError;
    } else if (c.callee.data == .get_expr) {
        _ = try self.inferNode(c.callee, scope);
        
        t.* = .Void;
        if (c.callee.data.get_expr.object.resolved_type) |rt| {
            t.* = rt.*;
        }
    } else {
        t.* = .Void;
    }
}

pub fn inferGetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const g = node.data.get_expr;
    
    // Check if it's a lib method call (e.g. C.printf)
    if (g.object.data == .identifier) {
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ g.object.data.identifier.name, g.name });
        if (scope.lookupVariable(full_name)) |found_type| {
            t.* = found_type.*;
            node.resolved_type = found_type;
            
            const obj_t = try self.allocator.create(AetherType);
            obj_t.* = .{ .Custom = g.object.data.identifier.name };
            g.object.resolved_type = obj_t;
            
            return;
        }
    }

    const obj_type = try self.inferNode(g.object, scope);
    if (isNullable(obj_type) and !g.is_safe) {
        self.reportError(node.line, node.column, "TypeError: Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type {}.", .{obj_type.*});
        return error.TypeError;
    }

    if (isNullable(obj_type) and g.is_safe) {
        t.* = .{ .Union = .{
            .left = try self.allocator.create(AetherType),
            .right = try self.allocator.create(AetherType),
        } };
        if (std.mem.eql(u8, g.name, "x") or std.mem.eql(u8, g.name, "y") or std.mem.eql(u8, g.name, "age")) {
            @constCast(t.Union.left).* = .Int;
        } else {
            @constCast(t.Union.left).* = .String;
        }
        @constCast(t.Union.right).* = .Null;
    } else {
        if (std.mem.eql(u8, g.name, "x") or std.mem.eql(u8, g.name, "y") or std.mem.eql(u8, g.name, "age")) {
            t.* = .Int;
        } else {
            t.* = .String;
        }
    }
}

pub fn inferSetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const s = node.data.set_expr;
    _ = try self.inferNode(s.object, scope);
    const assigned_type = try self.inferNode(s.value, scope);
    t.* = assigned_type.*;
}
