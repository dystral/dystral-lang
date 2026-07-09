const std = @import("std");
const core = @import("core.zig");

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
            try self.writer.appendSlice("NULL");
        },
        .string_literal => |val| {
            try self.writer.writer().print("\"{s}\"", .{val});
        },
        .identifier => |i| {
            if (i.resolved_c_name) |cname| {
                try self.writer.appendSlice(cname);
            } else if (i.is_class_property) {
                try self.writer.writer().print("self->{s}", .{i.name});
            } else {
                try self.writer.appendSlice(i.name);
            }
        },
        .unary_expr => |u| {
            if (u.operator == .bang_bang) {
                try self.emitExpression(u.operand);
            }
        },
        .array_literal => |a| {
            if (node.resolved_type) |rt| {
                if (rt.* == .Array) {
                    try self.emitArrayStruct(rt.Array);
                    
                    const inner_c_type = try core.getCTypeStr(self.allocator, rt.Array);
                    var safe_inner = std.ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |c| {
                        if (c == '*') continue;
                        if (c == ' ') continue;
                        try safe_inner.append(c);
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
                }
            }
        },
        .index_expr => |idx| {
            try self.emitExpression(idx.object);
            try self.writer.appendSlice("->data[");
            try self.emitExpression(idx.index);
            try self.writer.appendSlice("]");
        },
        .assignment => |a| {
            try self.writer.writer().print("{s} = ", .{a.name});
            try self.emitExpression(a.value);
        },
        .get_expr => |g| {
            if (g.is_safe) {
                try self.writer.appendSlice("((");
                try self.emitExpression(g.object);
                try self.writer.appendSlice(") == NULL ? NULL : (");
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
                if (self.classes.contains(c_name)) {
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
                    class_name = "system_String";
                } else if (rt.* == .Custom) {
                    class_name = rt.Custom;
                } else if (rt.* == .Union) {
                    if (rt.Union.left.* == .String) {
                        class_name = "system_String";
                    } else if (rt.Union.left.* == .Custom) {
                        class_name = rt.Union.left.Custom;
                    }
                }
                
                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice(") == NULL ? NULL : ");
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
            try self.writer.appendSlice("(");
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
        },
        .binary_expr => |b| {
            if (b.op == .elvis) {
                try self.writer.appendSlice("((");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(") != NULL ? (");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(") : (");
                try self.emitExpression(b.right);
                try self.writer.appendSlice("))");
                return;
            }
            if (b.op == .eq_eq or b.op == .bang_eq) {
                if (b.left.resolved_type) |rt| {
                    if (rt.* == .String or rt.* == .Custom) {
                        if (b.op == .bang_eq) {
                            try self.writer.appendSlice("!");
                        }
                        const class_name = if (rt.* == .String) "system_String" else rt.Custom;
                        try self.writer.writer().print("{s}_equals(", .{class_name});
                        try self.emitExpression(b.left);
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(b.right);
                        try self.writer.appendSlice(")");
                        return;
                    }
                }
            }

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
        },
        else => return error.UnsupportedExpression,
    }
}
