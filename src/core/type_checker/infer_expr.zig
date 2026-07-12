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

fn isValidType(self: *TypeChecker, t: *const AetherType) bool {
    switch (t.*) {
        .Int, .Bool, .String, .Void, .Pointer, .Null => return true,
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
            } else if (left_type.* == .Pointer and right_type.* == .Int) {
                t.* = .Pointer;
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
            } else if (left_type.* == .Pointer and right_type.* == .Pointer) {
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
                // Print the argument types we provided to help debug
                var expected_types_str = std.ArrayList(u8).init(self.allocator);
                if (overloads.len > 0 and overloads[0].* == .Function) {
                    for (overloads[0].Function.params, 0..) |p, i| {
                        if (i > 0) try expected_types_str.appendSlice(", ");
                        const rt_str = try std.fmt.allocPrint(self.allocator, "{}", .{p.*});
                        try expected_types_str.appendSlice(rt_str);
                    }
                }
                
                var actual_types_str = std.ArrayList(u8).init(self.allocator);
                for (c.arguments, 0..) |arg, i| {
                    if (i > 0) try actual_types_str.appendSlice(", ");
                    if (arg.resolved_type) |rt| {
                        const rt_str = try std.fmt.allocPrint(self.allocator, "{}", .{rt.*});
                        try actual_types_str.appendSlice(rt_str);
                    } else {
                        try actual_types_str.appendSlice("unknown");
                    }
                }
                
                self.reportError(node.line, node.column, "TypeError: No matching overload found for function '{s}'. Expected: ({s}), Provided args: ({s})", .{ name, expected_types_str.items, actual_types_str.items });
                return error.TypeError;
            }
        }
        
        if (scope.lookupVariable(name)) |variable| {
            if (variable.* == .Custom) {
                const class_node = self.classes_ast.get(variable.Custom);
                if (class_node) |cn| {
                    const class_decl = cn.data.class_decl;
                    if (class_decl.generic_params.len > 0) {
                        if (c.arguments.len != class_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected {} arguments for generic constructor of '{s}'.", .{ class_decl.primary_constructor.len, name });
                            return error.TypeError;
                        }
                        var type_args = try self.allocator.alloc(*const AetherType, class_decl.generic_params.len);
                        for (class_decl.generic_params, 0..) |g_param, i| {
                            var found_type: ?*const AetherType = null;
                            for (class_decl.primary_constructor, 0..) |prop, prop_i| {
                                if (std.mem.eql(u8, prop.type_name, g_param)) {
                                    found_type = c.arguments[prop_i].resolved_type.?;
                                    break;
                                } else {
                                    var array_gparam = std.ArrayList(u8).init(self.allocator);
                                    try array_gparam.writer().print("NativeArray<{s}>", .{g_param});
                                    if (std.mem.eql(u8, prop.type_name, array_gparam.items)) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Array) {
                                            found_type = c.arguments[prop_i].resolved_type.?.Array;
                                            break;
                                        }
                                    }
                                    
                                    var list_gparam = std.ArrayList(u8).init(self.allocator);
                                    try list_gparam.writer().print("List<{s}>", .{g_param});
                                    if (std.mem.eql(u8, prop.type_name, list_gparam.items)) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            // Extract from collections_List_Int
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            if (std.mem.indexOf(u8, c_name, "List_") != null) {
                                                const arg_part = c_name[std.mem.indexOf(u8, c_name, "List_").? + 5 ..];
                                                found_type = try self.resolveTypeName(arg_part, false);
                                                break;
                                            }
                                        }
                                    }
                                    
                                    // Match List<Node<K, V>?>
                                    if (std.mem.startsWith(u8, prop.type_name, "List<Node<") and std.mem.indexOf(u8, prop.type_name, g_param) != null) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            if (std.mem.indexOf(u8, c_name, "List_") != null) {
                                                const list_part = c_name[std.mem.indexOf(u8, c_name, "List_").? + 5 ..];
                                                if (std.mem.indexOf(u8, list_part, "Node_") != null) {
                                                    var inner = list_part[std.mem.indexOf(u8, list_part, "Node_").? + 5 ..];
                                                    if (std.mem.endsWith(u8, inner, "Opt")) {
                                                        inner = inner[0 .. inner.len - 3];
                                                    }
                                                    var split_idx: usize = 0;
                                                    while (std.mem.indexOfPos(u8, inner, split_idx, "_")) |idx| {
                                                        const part1 = inner[0..idx];
                                                        const part2 = inner[idx + 1..];
                                                        const t1 = self.resolveTypeName(part1, false) catch null;
                                                        const t2 = self.resolveTypeName(part2, false) catch null;
                                                        if (t1 != null and t2 != null and isValidType(self, t1.?) and isValidType(self, t2.?)) {
                                                            if (std.mem.eql(u8, g_param, "K")) {
                                                                found_type = t1;
                                                            } else if (std.mem.eql(u8, g_param, "V")) {
                                                                found_type = t2;
                                                            }
                                                            break;
                                                        }
                                                        split_idx = idx + 1;
                                                    }
                                                    if (found_type != null) break;
                                                }
                                            }
                                        }
                                    }

                                    // Match MutableMap<T, Bool> or Map<T, Bool>
                                    if ((std.mem.startsWith(u8, prop.type_name, "MutableMap<") or std.mem.startsWith(u8, prop.type_name, "Map<")) and std.mem.indexOf(u8, prop.type_name, g_param) != null) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            var base_idx: ?usize = null;
                                            if (std.mem.indexOf(u8, c_name, "MutableMap_") != null) {
                                                base_idx = std.mem.indexOf(u8, c_name, "MutableMap_").? + "MutableMap_".len;
                                            } else if (std.mem.indexOf(u8, c_name, "Map_") != null) {
                                                base_idx = std.mem.indexOf(u8, c_name, "Map_").? + "Map_".len;
                                            }
                                            if (base_idx) |b_idx| {
                                                var inner = c_name[b_idx..];
                                                if (std.mem.endsWith(u8, inner, "Opt")) {
                                                    inner = inner[0 .. inner.len - 3];
                                                }
                                                var split_idx: usize = 0;
                                                while (std.mem.indexOfPos(u8, inner, split_idx, "_")) |idx| {
                                                    const part1 = inner[0..idx];
                                                    const part2 = inner[idx + 1..];
                                                    const t1 = self.resolveTypeName(part1, false) catch null;
                                                    const t2 = self.resolveTypeName(part2, false) catch null;
                                                    if (t1 != null and t2 != null and isValidType(self, t1.?) and isValidType(self, t2.?)) {
                                                        found_type = t1;
                                                        break;
                                                    }
                                                    split_idx = idx + 1;
                                                }
                                                if (found_type != null) break;
                                            }
                                        }
                                    }
                                }
                            }
                            if (found_type) |ft| {
                                type_args[i] = ft;
                            } else {
                                std.debug.print("Failed to infer '{s}' for '{s}'. Prop: {s}. Arg type: {}\n", .{g_param, name, class_decl.primary_constructor[0].type_name, c.arguments[0].resolved_type.?.*});
                                self.reportError(node.line, node.column, "TypeError: Could not infer generic parameter '{s}' for class '{s}'.", .{ g_param, name });
                                return error.TypeError;
                            }
                        }
                        
                        var mangled = std.ArrayList(u8).init(self.allocator);
                        try mangled.appendSlice(variable.Custom);
                        try mangled.appendSlice("_");
                        for (type_args, 0..) |t_arg, i| {
                            if (i > 0) try mangled.appendSlice("_");
                            try t_arg.formatSafe(mangled.writer());
                        }
                        const final_mangled = try mangled.toOwnedSlice();
                        
                        try self.monomorphizeClass(variable.Custom, type_args, final_mangled);
                        
                        const actual_mangled = self.alias_map.get(final_mangled) orelse final_mangled;
                        t.* = .{ .Custom = actual_mangled };
                        c.callee.data.identifier.resolved_c_name = actual_mangled;
                        return;
                    }
                }
                
                t.* = variable.*;
                c.callee.data.identifier.resolved_c_name = variable.Custom;
                return;
            }
        }
        
        if (self.alias_map.get(name)) |c_name| {
            if (scope.lookupVariable(c_name)) |variable| {
                if (variable.* == .Custom) {
                    t.* = variable.*;
                    c.callee.data.identifier.resolved_c_name = variable.Custom;
                    return;
                }
            }
        }
        self.reportError(node.line, node.column, "TypeError: Undeclared function '{s}'.", .{name});
        return error.TypeError;
    } else if (c.callee.data == .get_expr) {
        _ = try self.inferNode(c.callee, scope);
        
        t.* = .Void;
        if (c.callee.resolved_type) |rt| {
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

    var prop_type: ?*const AetherType = null;
    const base_type = core.extractBaseType(obj_type);
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
        if (self.classes_ast.get(name)) |class_node| {
            const c = class_node.data.class_decl;
            for (c.primary_constructor) |prop| {
                if (std.mem.eql(u8, prop.name, g.name)) {
                    const actual_type = self.alias_map.get(prop.type_name) orelse prop.type_name;
                    prop_type = try self.resolveTypeName(actual_type, false);
                    break;
                }
            }
            if (prop_type == null) {
                for (c.methods) |method| {
                    if (std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                        if (method.data.fun_decl.type_name) |tn| {
                            const actual_type = self.alias_map.get(tn) orelse tn;
                            prop_type = try self.resolveTypeName(actual_type, false);
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
    _ = try self.inferNode(s.object, scope);
    const assigned_type = try self.inferNode(s.value, scope);
    t.* = assigned_type.*;
}

pub fn inferArrayLiteral(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const a = node.data.array_literal;
    if (a.elements.len == 0) {
        self.reportError(node.line, node.column, "TypeError: Cannot infer type of empty array literal.", .{});
        return error.TypeError;
    }
    
    const first_type = try self.inferNode(a.elements[0], scope);
    for (a.elements[1..]) |elem| {
        const elem_type = try self.inferNode(elem, scope);
        if (!isCompatible(first_type, elem_type)) {
            self.reportError(node.line, node.column, "TypeError: Incompatible types in array literal. Expected {} but found {}.", .{ first_type.*, elem_type.* });
            return error.TypeError;
        }
    }
    const array_type = try self.allocator.create(AetherType);
    array_type.* = .{ .Array = first_type };
    
    // Simulate List<T> instantiation
    const list_c_name = self.alias_map.get("List") orelse "List";
    const class_node = self.classes_ast.get(list_c_name);
    if (class_node == null) {
        self.reportError(node.line, node.column, "TypeError: Class 'List' not found for array literal.", .{});
        return error.TypeError;
    }
    const class_decl = class_node.?.data.class_decl;
    var type_args = try self.allocator.alloc(*const AetherType, 1);
    type_args[0] = first_type;
    
    // O mangled name deve ser baseado no nome importado (list_c_name), nao string "List"
    var mangled = std.ArrayList(u8).init(self.allocator);
    try mangled.appendSlice(list_c_name);
    try mangled.appendSlice("_");
    try first_type.formatSafe(mangled.writer());
    const mangled_name = try mangled.toOwnedSlice();
    try self.monomorphizeClass(class_decl.name, type_args, mangled_name);
    
    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
}

pub fn inferMapLiteral(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const m = node.data.map_literal;
    if (m.elements.len == 0) {
        self.reportError(node.line, node.column, "TypeError: Cannot infer type of empty map literal.", .{});
        return error.TypeError;
    }
    
    // Evaluate the first pair
    var first_key_type: *const AetherType = undefined;
    var first_value_type: *const AetherType = undefined;
    
    for (m.elements, 0..) |elem, i| {
        // Element is a `.kw_of` binary expression. Let's infer it, which transforms it into a Node constructor.
        _ = try self.inferNode(elem, scope);
        
        // At this point elem is a call_expr to Node<K, V>
        if (elem.data != .call_expr) {
            self.reportError(elem.line, elem.column, "TypeError: Map literal elements must be 'of' pairs.", .{});
            return error.TypeError;
        }
        
        const k_type = elem.data.call_expr.arguments[0].resolved_type.?;
        const v_type = elem.data.call_expr.arguments[1].resolved_type.?;
        
        if (i == 0) {
            first_key_type = k_type;
            first_value_type = v_type;
        } else {
            if (!isCompatible(first_key_type, k_type) or !isCompatible(first_value_type, v_type)) {
                self.reportError(elem.line, elem.column, "TypeError: Incompatible types in map literal.", .{});
                return error.TypeError;
            }
        }
    }
    
    // Simulate Map instantiation
    const node_base = self.alias_map.get("Node") orelse "Node";
    const mmap_base = self.alias_map.get("MutableMap") orelse "MutableMap";
    const map_base = self.alias_map.get("Map") orelse "Map";

    var map_mangled_str = std.ArrayList(u8).init(self.allocator);
    try map_mangled_str.appendSlice(map_base);
    try map_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(map_mangled_str.writer());
    try map_mangled_str.appendSlice("_");
    try first_value_type.formatSafe(map_mangled_str.writer());
    const mangled_name = try map_mangled_str.toOwnedSlice();
    
    var node_mangled_str = std.ArrayList(u8).init(self.allocator);
    try node_mangled_str.appendSlice(node_base);
    try node_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(node_mangled_str.writer());
    try node_mangled_str.appendSlice("_");
    try first_value_type.formatSafe(node_mangled_str.writer());
    const node_mangled = try node_mangled_str.toOwnedSlice();
    
    var mmap_mangled_str = std.ArrayList(u8).init(self.allocator);
    try mmap_mangled_str.appendSlice(mmap_base);
    try mmap_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(mmap_mangled_str.writer());
    try mmap_mangled_str.appendSlice("_");
    try first_value_type.formatSafe(mmap_mangled_str.writer());
    const mmap_mangled = try mmap_mangled_str.toOwnedSlice();
    
    var type_args = try self.allocator.alloc(*const AetherType, 2);
    type_args[0] = first_key_type;
    type_args[1] = first_value_type;
    
    if (self.classes_ast.get(node_base) == null or self.classes_ast.get(mmap_base) == null or self.classes_ast.get(map_base) == null) {
        self.reportError(node.line, node.column, "TypeError: Required Map classes not found.", .{});
        return error.TypeError;
    }
    
    try self.monomorphizeClass(node_base, type_args, node_mangled);
    try self.monomorphizeClass(mmap_base, type_args, mmap_mangled);
    try self.monomorphizeClass(map_base, type_args, mangled_name);
    
    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
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
        
        try inferCallExpr(self, node, scope, t);
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
        
        try inferCallExpr(self, node, scope, t);
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
    if (!core.isCompatible(target_type.Array, value_type)) {
        std.debug.print("\n[DEBUG] inferIndexSetExpr FAIL: target_type={}, target_type.Array tag={s}, value_type={}, tag={s}\n", .{target_type, @tagName(target_type.Array.*), value_type.*, @tagName(value_type.*)});
        self.reportError(node.line, node.column, "TypeError: Cannot assign {} to array of {}.", .{value_type.*, target_type.Array.*});
        return error.TypeError;
    }
    
    t.* = .Void;
}
