const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");
const infer_call_mod = @import("infer_call.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;
const isNullable = core.isNullable;
const extractBaseType = core.extractBaseType;

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
        } else if (scope.lookupFunctions(full_name)) |overloads| {
            if (overloads.len > 0) {
                const found_type = overloads[0];
                t.* = found_type.*;
                node.resolved_type = found_type;
                
                const obj_t = try self.allocator.create(AetherType);
                obj_t.* = .{ .Custom = g.object.data.identifier.name };
                g.object.resolved_type = obj_t;
                
                return;
            }
        }
    }

    const obj_type = try self.inferNode(g.object, scope);
    if (isNullable(obj_type) and !g.is_safe) {
        self.reportError(node.line, node.column, "TypeError: Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type {}.", .{obj_type.*});
        return error.TypeError;
    }

    var prop_type: ?*const AetherType = null;
    const base_type = extractBaseType(obj_type);
    var lookup_name: ?[]const u8 = null;
    var base_name: ?[]const u8 = null;
    switch (base_type.*) {
        .Custom => |n| base_name = n,
        .Int => base_name = "core_Int",
        .String => base_name = "core_String",
        .Bool => base_name = "core_Bool",
        else => {},
    }
    
    if (base_name) |bn| {
        lookup_name = self.alias_map.get(bn) orelse bn;
    }
    
    if (lookup_name) |name| {
        var current_class_name: ?[]const u8 = name;
        while (current_class_name) |curr_name| {
            const actual_class_name = self.alias_map.get(curr_name) orelse curr_name;
            if (self.classes_ast.get(actual_class_name)) |class_node| {
                const c = class_node.data.class_decl;
                for (c.primary_constructor) |prop| {
                    if (std.mem.eql(u8, prop.name, g.name)) {
                        prop_type = try self.resolveTypeRef(prop.type_ref);
                        break;
                    }
                }
                if (prop_type == null) {
                    for (c.methods) |method| {
                        if (std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                            if (method.data.fun_decl.type_ref) |tr| {
                                prop_type = try self.resolveTypeRef(tr);
                            } else if (method.data.fun_decl.is_expr_body) {
                                if (method.data.fun_decl.body.resolved_type) |rt| {
                                    prop_type = rt;
                                } else {
                                    const void_type = try self.allocator.create(AetherType);
                                    void_type.* = .Void;
                                    prop_type = void_type;
                                }
                            } else {
                                const void_type = try self.allocator.create(AetherType);
                                void_type.* = .Void;
                                prop_type = void_type;
                            }
                            break;
                        }
                    }
                }
                if (prop_type != null) break;
                current_class_name = c.superclass_name;
            } else {
                break;
            }
        }
    } else if (base_type.* == .Array) {
        if (std.mem.eql(u8, g.name, "length")) {
            const int_t = try self.allocator.create(AetherType);
            int_t.* = .Int;
            prop_type = int_t;
        } else if (std.mem.eql(u8, g.name, "push")) {
            // Returns a function type that takes T and returns Void
            const fun_t = try self.allocator.create(AetherType);
            var params = try self.allocator.alloc(*const AetherType, 1);
            params[0] = base_type.Array;
            
            const void_t = try self.allocator.create(AetherType);
            void_t.* = .Void;
            
            fun_t.* = .{ .Function = .{
                .params = params,
                .return_type = void_t,
                .c_name = "", // Will be resolved in the C Transpiler
            }};
            prop_type = fun_t;
        } else if (std.mem.eql(u8, g.name, "set")) {
            // set(index: Int, val: T): Void
            const fun_t = try self.allocator.create(AetherType);
            var params = try self.allocator.alloc(*const AetherType, 2);
            
            const int_t = try self.allocator.create(AetherType);
            int_t.* = .Int;
            
            params[0] = int_t;
            params[1] = base_type.Array;
            
            const void_t = try self.allocator.create(AetherType);
            void_t.* = .Void;
            
            fun_t.* = .{ .Function = .{
                .params = params,
                .return_type = void_t,
                .c_name = "",
            }};
            prop_type = fun_t;
        }
    }

    if (prop_type == null) {
        self.reportError(node.line, node.column, "TypeError: Unresolved property '{s}' on type {}.", .{ g.name, obj_type.* });
        return error.TypeError;
    }

    if (isNullable(obj_type) and g.is_safe) {
        t.* = .{ .Union = .{
            .left = prop_type.?,
            .right = try self.allocator.create(AetherType),
        } };
        @constCast(t.Union.right).* = .Null;
    } else {
        t.* = prop_type.?.*;
    }
}

pub fn inferSetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const s = node.data.set_expr;
    const obj_type = try self.inferNode(s.object, scope);
    const assigned_type = try self.inferNode(s.value, scope);

    const base_type = extractBaseType(obj_type);
    var lookup_name: ?[]const u8 = null;
    switch (base_type.*) {
        .Custom => |n| lookup_name = self.alias_map.get(n) orelse n,
        else => {},
    }

    if (lookup_name) |name| {
        var current_class_name: ?[]const u8 = name;
        var found_prop = false;
        while (current_class_name) |curr_name| {
            const actual_class_name = self.alias_map.get(curr_name) orelse curr_name;
            if (self.classes_ast.get(actual_class_name)) |class_node| {
                const c = class_node.data.class_decl;
                for (c.primary_constructor) |prop| {
                    if (std.mem.eql(u8, prop.name, s.name)) {
                        found_prop = true;
                        if (!prop.is_mut) {
                            self.reportError(node.line, node.column, "TypeError: Cannot assign to constant property '{s}' of type {}.", .{ s.name, base_type.* });
                            return error.TypeError;
                        }
                        const prop_type = try self.resolveTypeRef(prop.type_ref);
                        if (!self.isCompatible(prop_type, assigned_type)) {
                            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} when setting property '{s}'.", .{ prop_type.*, assigned_type.*, s.name });
                            return error.TypeError;
                        }
                        break;
                    }
                }
                if (found_prop) break;
                current_class_name = c.superclass_name;
            } else {
                break;
            }
        }
        if (!found_prop) {
            self.reportError(node.line, node.column, "TypeError: Unresolved property '{s}' on type {}.", .{ s.name, base_type.* });
            return error.TypeError;
        }
    }

    t.* = assigned_type.*;
}

pub fn inferIndexExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const i = node.data.index_expr;
    const obj_type = try self.inferNode(i.object, scope);
    
    if (obj_type.* == .Custom or obj_type.* == .GenericInstance) {
        // Redireciona para object.get(index)
        const get_ident = try self.allocator.create(ASTNode);
        get_ident.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .identifier = .{ .name = "get", .resolved_c_name = null } } };
        
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = i.object, .name = "get", .is_safe = false } } };
        
        var args = try self.allocator.alloc(*ASTNode, 1);
        args[0] = i.index;
        
        node.data = .{ .call_expr = .{ .callee = get_expr, .arguments = args } };
        
        try infer_call_mod.inferCallExpr(self, node, scope, t);
        return;
    }
    
    if (obj_type.* != .Array) {
        self.reportError(node.line, node.column, "TypeError: Index operator '[]' can only be used on arrays or objects with .get(). Found {}.", .{obj_type.*});
        return error.TypeError;
    }
    
    const index_type = try self.inferNode(i.index, scope);
    if (index_type.* != .Int) {
        self.reportError(node.line, node.column, "TypeError: Array index must be Int. Found {}.", .{index_type.*});
        return error.TypeError;
    }
    
    t.* = obj_type.Array.*;
}

pub fn inferIndexSetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const i = node.data.index_set_expr;
    const obj_type = try self.inferNode(i.object, scope);
    
    if (obj_type.* == .Custom or obj_type.* == .GenericInstance) {
        // Redireciona para object.put(index, value) ou object.set(index, value)
        const get_ident = try self.allocator.create(ASTNode);
        get_ident.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .identifier = .{ .name = "put", .resolved_c_name = null } } };
        
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = i.object, .name = "put", .is_safe = false } } };
        
        var args = try self.allocator.alloc(*ASTNode, 2);
        args[0] = i.index;
        args[1] = i.value;
        
        node.data = .{ .call_expr = .{ .callee = get_expr, .arguments = args } };
        
        try infer_call_mod.inferCallExpr(self, node, scope, t);
        return;
    }
    
    if (obj_type.* != .Array) {
        self.reportError(node.line, node.column, "TypeError: Index assignment operator '[]=' can only be used on arrays or objects with .put(). Found {}.", .{obj_type.*});
        return error.TypeError;
    }
    
    const target_type = obj_type.*;
    const index_type = try self.inferNode(i.index, scope);
    if (index_type.* != .Int) {
        self.reportError(node.line, node.column, "TypeError: Array index must be Int. Found {}.", .{index_type.*});
        return error.TypeError;
    }
    
    const value_type = try self.inferNode(i.value, scope);
    if (!self.isCompatible(target_type.Array, value_type)) {
        std.debug.print("\n[DEBUG] inferIndexSetExpr FAIL: target_type={}, target_type.Array tag={s}, value_type={}, tag={s}\n", .{target_type, @tagName(target_type.Array.*), value_type.*, @tagName(value_type.*)});
        self.reportError(node.line, node.column, "TypeError: Cannot assign {} to array of {}.", .{value_type.*, target_type.Array.*});
        return error.TypeError;
    }
    
    t.* = .Void;
}
