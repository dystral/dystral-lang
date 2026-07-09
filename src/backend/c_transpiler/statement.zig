const std = @import("std");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

pub fn emitStatement(self: *CTranspiler, node: *ASTNode) !void {
    switch (node.data) {
        .var_decl => |v| {
            var type_str: []const u8 = "int";
            var is_class = false;

            if (v.type_name) |tn| {
                if (std.mem.eql(u8, tn, "String")) {
                    type_str = "AetherString*";
                } else if (self.classes.contains(tn)) {
                    type_str = tn;
                    is_class = true;
                }
            } else if (v.initializer) |init_node| {
                if (init_node.resolved_type) |rt| {
                    if (rt.* == .String) {
                        type_str = "AetherString*";
                    } else if (rt.* == .Custom) {
                        if (self.classes.contains(rt.Custom)) {
                            type_str = rt.Custom;
                            is_class = true;
                        } else {
                            type_str = "int";
                        }
                    }
                }
            }

            if (is_class) {
                try self.writer.writer().print("    {s}* {s}", .{type_str, v.name});
            } else {
                try self.writer.writer().print("    {s} {s}", .{type_str, v.name});
            }
            
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
