const std = @import("std");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

pub fn emitStatement(self: *CTranspiler, node: *ASTNode) !void {
    switch (node.data) {
        .var_decl => |v| {
            var type_str: []const u8 = "int";
            if (node.resolved_type) |rt| {
                type_str = try core.getCTypeStr(self.allocator, rt);
            }
            try self.writer.writer().print("    {s} {s}", .{type_str, v.name});
            
            if (v.initializer) |init_node| {
                try self.writer.appendSlice(" = ");
                try self.emitExpression(init_node);
            }
            try self.writer.appendSlice(";\n");
        },
        .while_stmt => |w| {
            try self.writer.appendSlice("    while (");
            try self.emitExpression(w.condition);
            try self.writer.appendSlice(") {\n");
            
            switch (w.body.data) {
                .block => |b| {
                    for (b.statements) |stmt| {
                        try self.emitStatement(stmt);
                    }
                },
                else => {
                    try self.emitStatement(w.body);
                }
            }
            try self.writer.appendSlice("    }\n");
        },
        .for_stmt => |f| {
            if (f.iterable.resolved_type) |rt| {
                if (rt.* == .Array) {
                    const inner_c_type = try core.getCTypeStr(self.allocator, rt.Array);
                    var safe_inner = std.ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |c| {
                        if (c == '*') continue;
                        if (c == ' ') continue;
                        try safe_inner.append(c);
                    }
                    const struct_name = try std.fmt.allocPrint(self.allocator, "AetherArray_{s}", .{safe_inner.items});
                    
                    try self.writer.appendSlice("    {\n");
                    try self.writer.writer().print("        {s}* _arr = ", .{struct_name});
                    try self.emitExpression(f.iterable);
                    try self.writer.appendSlice(";\n");
                    try self.writer.appendSlice("        for (size_t _i = 0; _i < _arr->length; _i++) {\n");
                    try self.writer.writer().print("            {s} {s} = _arr->data[_i];\n", .{inner_c_type, f.item_name});
                    
                    switch (f.body.data) {
                        .block => |b| {
                            for (b.statements) |stmt| {
                                try self.emitStatement(stmt);
                            }
                        },
                        else => {
                            try self.emitStatement(f.body);
                        }
                    }
                    try self.writer.appendSlice("        }\n");
                    try self.writer.appendSlice("    }\n");
                }
            }
        },
        .return_stmt => |r| {
            try self.writer.appendSlice("    return ");
            if (r.value) |v| {
                try self.emitExpression(v);
            }
            try self.writer.appendSlice(";\n");
        },
        .block => |b| {
            try self.writer.appendSlice("    {\n");
            for (b.statements) |stmt| {
                try self.emitStatement(stmt);
            }
            try self.writer.appendSlice("    }\n");
        },
        else => {
            try self.writer.appendSlice("    ");
            try self.emitExpression(node);
            try self.writer.appendSlice(";\n");
        },
    }
}
