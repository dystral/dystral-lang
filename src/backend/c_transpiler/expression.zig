const std = @import("std");
const core = @import("core.zig");
const ts = @import("../../core/type_system.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

pub fn emitExpression(self: *CTranspiler, node: *ASTNode) !void {
    switch (node.data) {
        .int_literal => |val| {
            try self.writer.writer().print("{}", .{val});
        },
        .bool_literal => |b| {
            if (b) try self.writer.appendSlice("1")
            else try self.writer.appendSlice("0");
        },
        .null_literal => {
            try self.writer.appendSlice("0");
        },
        .string_literal => |val| {
            try self.writer.writer().print("\"{s}\"", .{val});
        },
        .identifier => |i| {
            if (i.resolved_c_name) |cname| {
                try self.writer.appendSlice(cname);
            } else if (i.is_class_property) {
                try self.writer.writer().print("this->{s}", .{i.name});
            } else {
                try self.writer.appendSlice(i.name);
            }
        },
        .unary_expr => |u| {
            if (u.operator == .bang_bang) {
                try self.emitExpression(u.operand);
            } else if (u.operator == .bang) {
                try self.writer.appendSlice("!(");
                try self.emitExpression(u.operand);
                try self.writer.appendSlice(")");
            } else if (u.operator == .minus) {
                try self.writer.appendSlice("-(");
                try self.emitExpression(u.operand);
                try self.writer.appendSlice(")");
            }
        },
        .array_literal => |a| {
            if (node.resolved_type) |rt| {
                if (ts.extractBaseType(rt).* == .Array) {
                    try self.emitArrayStruct(ts.extractBaseType(rt).Array);
                    
                    const inner_c_type = try core.getCTypeStr(self.allocator, ts.extractBaseType(rt).Array);
                    var safe_inner = std.ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |ch| {
                        if (ch == '*') continue;
                        if (ch == ' ') continue;
                        try safe_inner.append(ch);
                    }
                    const struct_name = try std.fmt.allocPrint(self.allocator, "AetherArray_{s}", .{safe_inner.items});
                    
                    try self.writer.appendSlice("({ ");
                    try self.writer.writer().print("{s}* _tmp_arr = {s}_new(); ", .{struct_name, struct_name});
                    for (a.elements) |elem| {
                        try self.writer.writer().print("{s}_push(_tmp_arr, ", .{struct_name});
                        try self.emitExpression(elem);
                        try self.writer.appendSlice("); ");
                    }
                    try self.writer.appendSlice("_tmp_arr; })");
                } else if (rt.* == .Custom) {
                    const struct_name = rt.Custom;
                    try self.writer.writer().print("{s}_new(({{ ", .{struct_name});
                    
                    var safe_inner_name = std.ArrayList(u8).init(self.allocator);
                    if (a.elements.len > 0) {
                        const inner_c_type = try core.getCTypeStr(self.allocator, a.elements[0].resolved_type.?);
                        for (inner_c_type) |ch| {
                            if (ch == '*') continue;
                            if (ch == ' ') continue;
                            try safe_inner_name.append(ch);
                        }
                    } else {
                        try safe_inner_name.appendSlice("Void");
                    }
                    const safe_inner = safe_inner_name.items;
                    
                    const array_struct_name = try std.fmt.allocPrint(self.allocator, "AetherArray_{s}", .{safe_inner});
                    try self.writer.writer().print("{s}* _tmp_arr = {s}_new(); ", .{array_struct_name, array_struct_name});
                    for (a.elements) |elem| {
                        try self.writer.writer().print("{s}_push(_tmp_arr, ", .{array_struct_name});
                        try self.emitExpression(elem);
                        try self.writer.appendSlice("); ");
                    }
                    try self.writer.appendSlice("_tmp_arr; }))");
                }
            }
        },
        .map_literal => |m| {
            if (node.resolved_type) |rt| {
                if (rt.* == .Custom) {
                    const custom_name = rt.Custom; // Map_core_String_core_String
                    
                    var safe_inner_name = std.ArrayList(u8).init(self.allocator);
                    if (m.elements.len > 0) {
                        const call = m.elements[0].data.call_expr;
                        const first_k_type = try core.getCTypeStr(self.allocator, call.arguments[0].resolved_type.?);
                        for (first_k_type) |ch| {
                            if (ch == '*' or ch == ' ') continue;
                            try safe_inner_name.append(ch);
                        }
                        try safe_inner_name.appendSlice("_");
                        const first_v_type = try core.getCTypeStr(self.allocator, call.arguments[1].resolved_type.?);
                        for (first_v_type) |ch| {
                            if (ch == '*' or ch == ' ') continue;
                            try safe_inner_name.append(ch);
                        }
                    } else {
                        try safe_inner_name.appendSlice("Void_Void");
                    }
                    const safe_inner = safe_inner_name.items;
                    
                    const node_name = try std.fmt.allocPrint(self.allocator, "collections_Node_{s}", .{ safe_inner });
                    const custom_t = try self.allocator.create(ts.AetherType);
                    custom_t.* = .{ .Custom = node_name };
                    const null_t = try self.allocator.create(ts.AetherType);
                    null_t.* = .Null;
                    const union_t = try self.allocator.create(ts.AetherType);
                    union_t.* = .{ .Union = .{ .left = custom_t, .right = null_t } };
                    
                    try self.emitArrayStruct(union_t);
                    
                    const array_name = try std.fmt.allocPrint(self.allocator, "AetherArray_{s}", .{node_name});
                    const list_name = try std.fmt.allocPrint(self.allocator, "collections_List_collections_Node_{s}Opt", .{safe_inner});
                    const mmap_name = try std.fmt.allocPrint(self.allocator, "collections_MutableMap_{s}", .{safe_inner});
                    
                    try self.writer.writer().print("{s}_new(({{ ", .{custom_name});
                    try self.writer.writer().print("{s}* _buckets = {s}_new(); ", .{array_name, array_name});
                    try self.writer.writer().print("for (int _i = 0; _i < 16; _i++) {{ {s}_push(_buckets, 0); }} ", .{array_name});
                    try self.writer.writer().print("{s}* _list = {s}_new(_buckets); ", .{list_name, list_name});
                    try self.writer.writer().print("{s}* _mmap = {s}_new(_list); ", .{mmap_name, mmap_name});
                    
                    for (m.elements) |elem| {
                        const call = elem.data.call_expr;
                        try self.writer.writer().print("{s}_put(_mmap, ", .{mmap_name});
                        try self.emitExpression(call.arguments[0]);
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(call.arguments[1]);
                        try self.writer.appendSlice("); ");
                    }
                    
                    try self.writer.appendSlice("_list; }))");
                }
            }
        },
        .index_expr => |idx| {
            try self.emitExpression(idx.object);
            try self.writer.appendSlice("->data[");
            try self.emitExpression(idx.index);
            try self.writer.appendSlice("]");
        },
        .index_set_expr => |s| {
            try self.emitExpression(s.object);
            try self.writer.appendSlice("->data[");
            try self.emitExpression(s.index);
            try self.writer.appendSlice("] = ");
            try self.emitExpression(s.value);
        },

        .assignment => |a| {
            try self.writer.writer().print("{s} = ", .{a.name});
            try self.emitExpression(a.value);
        },
        .get_expr => |g| {
            const rt = g.object.resolved_type.?;
            const base_type = ts.extractBaseType(rt);
            if (base_type.* == .Custom) {
                const class_name = base_type.Custom;
                
                var prop_path: []const u8 = "";
                if (self.classes_ast) |ca| {
                    if (ca.get(class_name)) |class_node| {
                        const cd = class_node.data.class_decl;
                        if (self.getPropertyOwner(cd, g.name)) |owner| {
                            const super_path = try self.getSuperclassPath(class_name, owner);
                            prop_path = try std.fmt.allocPrint(self.allocator, "{s}.", .{super_path});
                        }
                    }
                }
                
                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.writer().print(") == 0 ? 0 : ((({s}*)(", .{class_name});
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("))->{s}{s}))", .{prop_path, g.name});
                } else {
                    try self.writer.writer().print("((({s}*)(", .{class_name});
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("))->{s}{s})", .{prop_path, g.name});
                }
            } else {
                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice(") == 0 ? 0 : (");
                    try self.emitExpression(g.object);
                    try self.writer.writer().print(")->{s})", .{g.name});
                } else {
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("->{s}", .{g.name});
                }
            }
        },
        .set_expr => |s| {
            const rt = s.object.resolved_type.?;
            const base_type = ts.extractBaseType(rt);
            if (base_type.* == .Custom) {
                const class_name = base_type.Custom;
                
                var prop_path: []const u8 = "";
                if (self.classes_ast) |ca| {
                    if (ca.get(class_name)) |class_node| {
                        const cd = class_node.data.class_decl;
                        if (self.getPropertyOwner(cd, s.name)) |owner| {
                            const super_path = try self.getSuperclassPath(class_name, owner);
                            prop_path = try std.fmt.allocPrint(self.allocator, "{s}.", .{super_path});
                        }
                    }
                }
                
                try self.writer.writer().print("((({s}*)(", .{class_name});
                try self.emitExpression(s.object);
                try self.writer.writer().print("))->{s}{s} = ", .{prop_path, s.name});
                try self.emitExpression(s.value);
                try self.writer.appendSlice(")");
            } else {
                try self.emitExpression(s.object);
                try self.writer.writer().print("->{s} = ", .{s.name});
                try self.emitExpression(s.value);
            }
        },
        .call_expr => |c| {
            if (c.callee.data == .identifier) {
                const c_name = c.callee.data.identifier.resolved_c_name orelse c.callee.data.identifier.name;
                if (self.classes.contains(c_name) or self.known_constructors.contains(c_name)) {
                    try self.writer.writer().print("{s}_new", .{c_name});
                    try self.writer.appendSlice("(");
                    for (c.arguments, 0..) |arg, i| {
                        if (i > 0) try self.writer.appendSlice(", ");
                        try self.emitExpression(arg);
                    }
                    try self.writer.appendSlice(")");
                } else {
                    try self.writer.writer().print("{s}(", .{c_name});
                    for (c.arguments, 0..) |arg, i| {
                        if (i > 0) try self.writer.appendSlice(", ");
                        try self.emitExpression(arg);
                    }
                    try self.writer.appendSlice(")");
                }
            } else if (c.callee.data == .get_expr) {
                const g = c.callee.data.get_expr;
                const rt = g.object.resolved_type.?;
                
                if (rt.* == .Custom and self.libs.contains(rt.Custom)) {
                    // It's a C method call from a lib block!
                    try self.writer.writer().print("{s}(", .{g.name});
                    for (c.arguments, 0..) |arg, i| {
                        if (i > 0) try self.writer.appendSlice(", ");
                        const arg_t = ts.extractBaseType(arg.resolved_type.?);
                        const is_string = switch (arg_t.*) {
                            .String => true,
                            .Custom => |name| std.mem.eql(u8, name, "core_String") or std.mem.eql(u8, name, "String"),
                            else => false,
                        };
                        if (is_string) {
                            try self.writer.appendSlice("(");
                            try self.emitExpression(arg);
                            try self.writer.appendSlice(")->ptr");
                        } else {
                            try self.emitExpression(arg);
                        }
                    }
                    try self.writer.appendSlice(")");
                    return;
                }

                var class_name: []const u8 = "unknown";
                if (rt.* == .String) {
                    class_name = "core_String";
                } else if (rt.* == .Int) {
                    class_name = "core_Int";
                } else if (rt.* == .Bool) {
                    class_name = "core_Bool";
                } else if (rt.* == .Custom) {
                    class_name = rt.Custom;
                } else if (rt.* == .Array) {
                    const inner_c_type = try core.getCTypeStr(self.allocator, rt.Array);
                    var safe_inner = std.ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |ch| {
                        if (ch == '*') continue;
                        if (ch == ' ') continue;
                        try safe_inner.append(ch);
                    }
                    class_name = try std.fmt.allocPrint(self.allocator, "AetherArray_{s}", .{safe_inner.items});
                } else if (rt.* == .Union) {
                    if (rt.Union.left.* == .String) {
                        class_name = "core_String";
                    } else if (rt.Union.left.* == .Custom) {
                        class_name = rt.Union.left.Custom;
                    }
                }
                
                var is_virtual_call = false;
                var owner_class_c_name: []const u8 = "";
                if (self.classes_ast) |ca| {
                    if (ca.get(class_name)) |class_node| {
                        const cd = class_node.data.class_decl;
                        if (cd.is_open or cd.superclass_name != null) {
                            if (self.getMethodOwner(cd, g.name)) |owner| {
                                is_virtual_call = true;
                                owner_class_c_name = owner;
                            } else {
                                for (cd.methods) |m| {
                                    if (std.mem.eql(u8, m.data.fun_decl.name, g.name)) {
                                        is_virtual_call = true;
                                        owner_class_c_name = class_name;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice(") == 0 ? 0 : ");
                    if (is_virtual_call) {
                        try self.writer.writer().print("(({s}*)(", .{owner_class_c_name});
                        try self.emitExpression(g.object);
                        try self.writer.writer().print("))->{s}_ptr(({s}*)(", .{g.name, owner_class_c_name});
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                    } else {
                        try self.writer.writer().print("{s}_{s}(", .{class_name, g.name});
                        try self.emitExpression(g.object);
                    }
                    for (c.arguments) |arg| {
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(arg);
                    }
                    try self.writer.appendSlice("))");
                } else {
                    if (is_virtual_call) {
                        try self.writer.writer().print("(({s}*)(", .{owner_class_c_name});
                        try self.emitExpression(g.object);
                        try self.writer.writer().print("))->{s}_ptr(({s}*)(", .{g.name, owner_class_c_name});
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                    } else {
                        try self.writer.writer().print("{s}_{s}(", .{class_name, g.name});
                        try self.emitExpression(g.object);
                    }
                    for (c.arguments) |arg| {
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(arg);
                    }
                    try self.writer.appendSlice(")");
                }
            } else {
                try self.emitExpression(c.callee);
                try self.writer.appendSlice("(");
                for (c.arguments, 0..) |arg, i| {
                    if (i > 0) try self.writer.appendSlice(", ");
                    try self.emitExpression(arg);
                }
                try self.writer.appendSlice(")");
            }
        },
        .if_expr => |i| {
            try self.writer.appendSlice("((");
            try self.emitExpression(i.condition);
            try self.writer.appendSlice(") ? ");
            
            if (i.then_branch.data == .block) {
                try self.emitExpression(i.then_branch.data.block.statements[0]); // Hack for simple ifs
            } else {
                try self.emitExpression(i.then_branch);
            }
            
            try self.writer.appendSlice(" : ");
            
            if (i.else_branch) |eb| {
                if (eb.data == .block) {
                    try self.emitExpression(eb.data.block.statements[0]);
                } else {
                    try self.emitExpression(eb);
                }
            } else {
                try self.writer.appendSlice("0"); // fallback
            }
            try self.writer.appendSlice(")");
        },
        .ternary_expr => |t| {
            try self.writer.appendSlice("((");
            try self.emitExpression(t.condition);
            try self.writer.appendSlice(") ? (");
            try self.emitExpression(t.then_branch);
            try self.writer.appendSlice(") : ");
            if (t.else_branch) |eb| {
                try self.writer.appendSlice("(");
                try self.emitExpression(eb);
                try self.writer.appendSlice(")");
            } else {
                try self.writer.appendSlice("0");
            }
            try self.writer.appendSlice(")");
        },
        .binary_expr => |b| {
            if (b.op == .elvis) {
                try self.writer.appendSlice("((");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(") != 0 ? (");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(") : (");
                try self.emitExpression(b.right);
                try self.writer.appendSlice("))");
                return;
            }
            if (b.op == .eq_eq or b.op == .bang_eq) {
                const left_is_null = (b.left.data == .null_literal);
                const right_is_null = (b.right.data == .null_literal);

                if (left_is_null or right_is_null) {
                    const non_null_side = if (left_is_null) b.right else b.left;
                    if (non_null_side.resolved_type) |rt| {
                        if (!ts.isNullable(rt)) {
                            if (b.op == .eq_eq) {
                                try self.writer.appendSlice("0");
                            } else {
                                try self.writer.appendSlice("1");
                            }
                            return;
                        }
                    }
                }

                var string_or_custom_type: ?*const ts.AetherType = null;
                if (b.left.resolved_type) |rt| {
                    const base = ts.extractBaseType(rt);
                    if (base.* == .String or base.* == .Custom) {
                        string_or_custom_type = base;
                    }
                }
                if (string_or_custom_type == null) {
                    if (b.right.resolved_type) |rt| {
                        const base = ts.extractBaseType(rt);
                        if (base.* == .String or base.* == .Custom) {
                            string_or_custom_type = base;
                        }
                    }
                }

                var has_equals = false;
                var class_name: []const u8 = "";
                if (string_or_custom_type) |base| {
                    if (base.* == .String) {
                        has_equals = true;
                        class_name = "core_String";
                    } else if (base.* == .Custom) {
                        class_name = base.Custom;
                        if (self.classes_ast) |ca| {
                            if (ca.get(class_name)) |class_node| {
                                const cd = class_node.data.class_decl;
                                for (cd.methods) |method| {
                                    if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, "equals")) {
                                        has_equals = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (has_equals) {
                    if (b.op == .bang_eq) {
                        try self.writer.appendSlice("!(");
                    } else {
                        try self.writer.appendSlice("(");
                    }
                    
                    try self.writer.appendSlice("(");
                    try self.emitExpression(b.left);
                    try self.writer.appendSlice(") == (");
                    try self.emitExpression(b.right);
                    try self.writer.appendSlice(") || ((");
                    try self.emitExpression(b.left);
                    try self.writer.appendSlice(") != 0 && (");
                    try self.emitExpression(b.right);
                    try self.writer.appendSlice(") != 0 && ");
                    
                    try self.writer.writer().print("{s}_equals(", .{class_name});
                    try self.emitExpression(b.left);
                    try self.writer.appendSlice(", ");
                    try self.emitExpression(b.right);
                    try self.writer.appendSlice(")))");
                    return;
                }
            }
            if (b.op == .plus and std.meta.activeTag(b.left.resolved_type.?.*) == .Pointer) {
                const c_type = try core.getCTypeStr(self.allocator, b.left.resolved_type.?);
                try self.writer.writer().print("((({s})(", .{c_type});
                try self.emitExpression(b.left);
                try self.writer.appendSlice(")) + ");
                try self.emitExpression(b.right);
                try self.writer.appendSlice(")");
                return;
            }
            if (b.op == .minus and std.meta.activeTag(b.left.resolved_type.?.*) == .Pointer and std.meta.activeTag(b.right.resolved_type.?.*) == .Pointer) {
                const c_type = try core.getCTypeStr(self.allocator, b.left.resolved_type.?);
                try self.writer.writer().print("((({s})(", .{c_type});
                try self.emitExpression(b.left);
                try self.writer.writer().print(")) - (({s})(", .{c_type});
                try self.emitExpression(b.right);
                try self.writer.appendSlice(")))");
                return;
            }

            try self.writer.appendSlice("(");
            try self.emitExpression(b.left);
            const op_str = switch (b.op) {
                .plus => " + ",
                .minus => " - ",
                .star => " * ",
                .slash => " / ",
                .eq_eq => " == ",
                .bang_eq => " != ",
                .less => " < ",
                .greater => " > ",
                .less_eq => " <= ",
                .greater_eq => " >= ",
                .and_and => " && ",
                .or_or => " || ",
                else => return error.UnsupportedOperator,
            };
            try self.writer.appendSlice(op_str);
            try self.emitExpression(b.right);
            try self.writer.appendSlice(")");
        },
        .as_expr => |a| {
            const t_str = try core.getCTypeStr(self.allocator, a.type_ref.resolved_type.?);
            try self.writer.writer().print("(({s})", .{t_str});
            try self.emitExpression(a.value);
            try self.writer.appendSlice(")");
        },
        .is_expr => |i| {
            const target_t = i.type_ref.resolved_type.?;
            const target_c_name = target_t.Custom;
            if (i.is_not) {
                try self.writer.appendSlice("!(");
            }
            try self.writer.appendSlice("((");
            try self.emitExpression(i.value);
            try self.writer.writer().print(") != 0 && aether_is_instance(*(const AetherClassDescriptor**)(", .{});
            try self.emitExpression(i.value);
            try self.writer.writer().print("), &{s}_descriptor))", .{target_c_name});
            if (i.is_not) {
                try self.writer.appendSlice(")");
            }
        },
        .is_type_cond => {
            return error.UnsupportedExpression;
        },
        .when_expr => |w| {
            const res_t = node.resolved_type.?;
            const is_void = res_t.* == .Void;

            try self.writer.appendSlice("({ ");

            const res_var_name = try std.fmt.allocPrint(self.allocator, "_when_res_{}_{}", .{ node.line, node.column });
            if (!is_void) {
                const res_c_type = try core.getCTypeStr(self.allocator, res_t);
                try self.writer.writer().print("{s} {s}; ", .{ res_c_type, res_var_name });
            }

            const subj_var_name = try std.fmt.allocPrint(self.allocator, "_when_subj_{}_{}", .{ node.line, node.column });
            if (w.subject) |subj| {
                const subj_t = subj.resolved_type.?;
                const subj_c_type = try core.getCTypeStr(self.allocator, subj_t);
                try self.writer.writer().print("{s} {s} = ", .{ subj_c_type, subj_var_name });
                try self.emitExpression(subj);
                try self.writer.appendSlice("; ");
            }

            for (w.cases, 0..) |case, i| {
                if (i > 0) {
                    try self.writer.appendSlice("else ");
                }

                if (case.is_else) {
                    try self.writer.appendSlice("{ ");
                    try emitWhenCaseBody(self, case.body, is_void, res_var_name);
                    try self.writer.appendSlice("} ");
                } else {
                    try self.writer.appendSlice("if (");
                    for (case.conds, 0..) |cond, c_idx| {
                        if (c_idx > 0) {
                            try self.writer.appendSlice(" || ");
                        }

                        if (w.subject) |subj| {
                            const subj_t = subj.resolved_type.?;
                            if (cond.data == .is_type_cond) {
                                const type_cond = cond.data.is_type_cond;
                                const target_t = type_cond.type_ref.resolved_type.?;
                                const target_c_name = target_t.Custom;

                                if (type_cond.is_not) {
                                    try self.writer.appendSlice("!(");
                                }
                                try self.writer.writer().print("(({s}) != 0 && aether_is_instance(*(const AetherClassDescriptor**)(", .{ subj_var_name });
                                try self.writer.writer().print("{s}), &{s}_descriptor))", .{ subj_var_name, target_c_name });
                                if (type_cond.is_not) {
                                    try self.writer.appendSlice(")");
                                }
                            } else {
                                // Value check: subj == cond
                                const is_str = (subj_t.* == .String or (subj_t.* == .Custom and std.mem.eql(u8, subj_t.Custom, "core_String")));
                                if (is_str) {
                                    try self.writer.writer().print("core_String_equals({s}, ", .{ subj_var_name });
                                    try self.emitExpression(cond);
                                    try self.writer.appendSlice(")");
                                } else {
                                    try self.writer.writer().print("{s} == ", .{ subj_var_name });
                                    try self.emitExpression(cond);
                                }
                            }
                        } else {
                            // Subjectless when: cond is boolean expr
                            try self.emitExpression(cond);
                        }
                    }
                    try self.writer.appendSlice(") { ");
                    try emitWhenCaseBody(self, case.body, is_void, res_var_name);
                    try self.writer.appendSlice("} ");
                }
            }

            if (!is_void) {
                try self.writer.writer().print("{s}; ", .{ res_var_name });
            }
            try self.writer.appendSlice("})");
        },
        else => return error.UnsupportedExpression,
    }
}

fn emitWhenCaseBody(self: *CTranspiler, body: *ASTNode, is_void: bool, res_var_name: []const u8) anyerror!void {
    if (body.data == .block) {
        const stmts = body.data.block.statements;
        for (stmts, 0..) |stmt, idx| {
            if (idx == stmts.len - 1 and !is_void) {
                try self.writer.appendSlice("    ");
                try self.writer.writer().print("{s} = ", .{ res_var_name });
                try self.emitExpression(stmt);
                try self.writer.appendSlice(";\n");
            } else {
                try self.emitStatement(stmt);
            }
        }
    } else {
        if (!is_void) {
            try self.writer.appendSlice("    ");
            try self.writer.writer().print("{s} = ", .{ res_var_name });
            try self.emitExpression(body);
            try self.writer.appendSlice(";\n");
        } else {
            try self.emitStatement(body);
        }
    }
}
