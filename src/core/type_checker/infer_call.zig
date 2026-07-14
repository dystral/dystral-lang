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
                if (c.arguments.len > f.params.len) continue;
                
                const func_node = self.functions_ast.get(f.c_name) orelse continue;
                const fun_decl = func_node.data.fun_decl;
                
                var has_defaults = true;
                var i = c.arguments.len;
                while (i < f.params.len) : (i += 1) {
                    if (fun_decl.params[i].initializer == null) {
                        has_defaults = false;
                        break;
                    }
                }
                if (!has_defaults) continue;
                
                var all_match = true;
                for (c.arguments, 0..) |arg, arg_i| {
                    if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
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
                const f = matched.Function;
                const func_node = self.functions_ast.get(f.c_name).?;
                const fun_decl = func_node.data.fun_decl;
                
                if (c.arguments.len < f.params.len) {
                    var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                    for (c.arguments, 0..) |arg, arg_i| {
                        new_args[arg_i] = arg;
                    }
                    var i = c.arguments.len;
                    while (i < f.params.len) : (i += 1) {
                        const cloned = try self.cloneNode(fun_decl.params[i].initializer.?);
                        new_args[i] = cloned;
                        _ = try self.inferNode(cloned, scope);
                    }
                    c.arguments = new_args;
                }
                
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
                        if (c.arguments.len < class_decl.primary_constructor.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, class_decl.primary_constructor.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < class_decl.primary_constructor.len) : (i += 1) {
                                const prop = class_decl.primary_constructor[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for generic constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > class_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for generic constructor of '{s}', got {}.", .{ class_decl.primary_constructor.len, name, c.arguments.len });
                            return error.TypeError;
                        }
                        var type_args = try self.allocator.alloc(*const AetherType, class_decl.generic_params.len);
                        for (class_decl.generic_params, 0..) |g_param, i| {
                            var found_type: ?*const AetherType = null;
                            for (class_decl.primary_constructor, 0..) |prop, prop_i| {
                                if (std.mem.eql(u8, prop.type_ref.name, g_param) and prop.type_ref.generic_args.len == 0 and !prop.type_ref.is_array) {
                                    found_type = c.arguments[prop_i].resolved_type.?;
                                    break;
                                } else {
                                    if (std.mem.eql(u8, prop.type_ref.name, "NativeArray") and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param)) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Array) {
                                            found_type = c.arguments[prop_i].resolved_type.?.Array;
                                            break;
                                        }
                                    }
                                    
                                    const is_list_gparam = (std.mem.eql(u8, prop.type_ref.name, "List") and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param)) or (prop.type_ref.is_array and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param));
                                    if (is_list_gparam) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            if (std.mem.indexOf(u8, c_name, "List_") != null) {
                                                const arg_part = c_name[std.mem.indexOf(u8, c_name, "List_").? + 5 ..];
                                                found_type = try self.resolveTypeName(arg_part, false);
                                                break;
                                            }
                                        }
                                    }
                                    
                                    var is_list_node = false;
                                    if (std.mem.eql(u8, prop.type_ref.name, "List") and prop.type_ref.generic_args.len == 1) {
                                        const inner = prop.type_ref.generic_args[0];
                                        if (std.mem.eql(u8, inner.name, "Node") and inner.generic_args.len == 2) {
                                            if (std.mem.eql(u8, inner.generic_args[0].name, g_param) or std.mem.eql(u8, inner.generic_args[1].name, g_param)) {
                                                is_list_node = true;
                                            }
                                        }
                                    }
                                    if (is_list_node) {
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

                                    var is_map_gparam = false;
                                    if ((std.mem.eql(u8, prop.type_ref.name, "MutableMap") or std.mem.eql(u8, prop.type_ref.name, "Map")) and prop.type_ref.generic_args.len >= 1) {
                                        for (prop.type_ref.generic_args) |arg| {
                                            if (std.mem.eql(u8, arg.name, g_param)) {
                                                is_map_gparam = true;
                                                break;
                                            }
                                        }
                                    }
                                    if (is_map_gparam) {
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
                                std.debug.print("Failed to infer '{s}' for '{s}'. Prop: {s}. Arg type: {}\n", .{g_param, name, class_decl.primary_constructor[0].name, c.arguments[0].resolved_type.?.*});
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
                    } else {
                        if (c.arguments.len < class_decl.primary_constructor.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, class_decl.primary_constructor.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < class_decl.primary_constructor.len) : (i += 1) {
                                const prop = class_decl.primary_constructor[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > class_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for constructor of '{s}', got {}.", .{ class_decl.primary_constructor.len, name, c.arguments.len });
                            return error.TypeError;
                        }
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
                    const class_node = self.classes_ast.get(variable.Custom);
                    if (class_node) |cn| {
                        const class_decl = cn.data.class_decl;
                        if (c.arguments.len < class_decl.primary_constructor.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, class_decl.primary_constructor.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < class_decl.primary_constructor.len) : (i += 1) {
                                const prop = class_decl.primary_constructor[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > class_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for constructor of '{s}', got {}.", .{ class_decl.primary_constructor.len, name, c.arguments.len });
                            return error.TypeError;
                        }
                    }
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
        
        // Fill in method default parameters!
        const g = c.callee.data.get_expr;
        if (g.object.resolved_type) |obj_type| {
            const base_type = extractBaseType(obj_type);
            if (base_type.* == .Custom) {
                const class_name = base_type.Custom;
                if (self.classes_ast.get(class_name)) |class_node| {
                    const class_decl = class_node.data.class_decl;
                    
                    // Search for the method declaration
                    var found_method: ?*ASTNode = null;
                    var current_class_name: ?[]const u8 = class_name;
                    while (current_class_name) |curr_name| {
                        const actual_class_name = self.alias_map.get(curr_name) orelse curr_name;
                        if (self.classes_ast.get(actual_class_name)) |curr_node| {
                            for (curr_node.data.class_decl.methods) |method| {
                                if (std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                                    found_method = method;
                                    break;
                                }
                            }
                            if (found_method != null) break;
                            current_class_name = curr_node.data.class_decl.superclass_name;
                        } else {
                            break;
                        }
                    }
                    
                    if (found_method) |m| {
                        const f = &m.data.fun_decl;
                        if (c.arguments.len < f.params.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < f.params.len) : (i += 1) {
                                const prop = f.params[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for method parameter '{s}' of '{s}.{s}' which has no default value.", .{ prop.name, class_decl.name, g.name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > f.params.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for method '{s}.{s}', got {}.", .{ f.params.len, class_decl.name, g.name, c.arguments.len });
                            return error.TypeError;
                        }
                    }
                }
            }
        }
        
        t.* = .Void;
        if (c.callee.resolved_type) |rt| {
            t.* = rt.*;
        }
    } else {
        t.* = .Void;
    }
}
