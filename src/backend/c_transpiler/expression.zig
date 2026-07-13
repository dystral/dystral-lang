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
        },
        .set_expr => |s| {
            try self.emitExpression(s.object);
            try self.writer.writer().print("->{s} = ", .{s.name});
            try self.emitExpression(s.value);
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
                        try self.emitExpression(arg);
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
                
                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice(") == 0 ? 0 : ");
                    try self.writer.writer().print("{s}_{s}(", .{class_name, g.name});
                    try self.emitExpression(g.object);
                    for (c.arguments) |arg| {
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(arg);
                    }
                    try self.writer.appendSlice("))");
                } else {
                    try self.writer.writer().print("{s}_{s}(", .{class_name, g.name});
                    try self.emitExpression(g.object);
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
            if (b.op == .plus and b.left.resolved_type.?.* == .Pointer) {
                try self.writer.appendSlice("(((char*)(");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(")) + ");
                try self.emitExpression(b.right);
                try self.writer.appendSlice(")");
                return;
            }
            if (b.op == .minus and b.left.resolved_type.?.* == .Pointer and b.right.resolved_type.?.* == .Pointer) {
                try self.writer.appendSlice("(((char*)(");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(")) - ((char*)(");
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
        else => return error.UnsupportedExpression,
    }
}
