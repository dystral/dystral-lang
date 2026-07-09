const std = @import("std");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

pub fn emitClassDecl(self: *CTranspiler, node: *ASTNode) !void {
    const class_decl = node.data.class_decl;
    const actual_name = class_decl.resolved_c_name orelse class_decl.name;
    if (self.classes.contains(actual_name)) return;
    try self.classes.put(actual_name, {});

    // Emit Struct
    try self.writer.writer().print("typedef struct {{\n", .{});
    for (class_decl.primary_constructor) |prop| {
        const t_str = if (std.mem.eql(u8, prop.type_name, "Int")) "int" else if (std.mem.eql(u8, prop.type_name, "String")) "AetherString*" else "int";
        try self.writer.writer().print("    {s} {s};\n", .{t_str, prop.name});
    }
    try self.writer.writer().print("}} {s};\n\n", .{actual_name});

    // Emit Allocator/Constructor
    try self.writer.writer().print("{s}* {s}_new(", .{actual_name, actual_name});
    for (class_decl.primary_constructor, 0..) |prop, i| {
        if (i > 0) try self.writer.appendSlice(", ");
        const t_str = if (std.mem.eql(u8, prop.type_name, "Int")) "int" else if (std.mem.eql(u8, prop.type_name, "String")) "AetherString*" else "int";
        try self.writer.writer().print("{s} {s}", .{t_str, prop.name});
    }
    try self.writer.writer().print(") {{\n", .{});
    try self.writer.writer().print("    {s}* instance = ({s}*)GC_MALLOC(sizeof({s}));\n", .{actual_name, actual_name, actual_name});
    for (class_decl.primary_constructor) |prop| {
        try self.writer.writer().print("    instance->{s} = {s};\n", .{prop.name, prop.name});
    }
    try self.writer.appendSlice("    return instance;\n}\n\n");
    
    for (class_decl.methods) |method| {
        try self.emitMethodDecl(actual_name, method);
    }
}

pub fn emitMethodDecl(self: *CTranspiler, class_name: []const u8, node: *ASTNode) !void {
    const decl = node.data.fun_decl;
    
    if (decl.is_expr_body) {
        if (decl.body.resolved_type) |rt| {
            if (rt.* == .String) {
                try self.writer.appendSlice("AetherString* ");
            } else if (rt.* == .Custom) {
                try self.writer.writer().print("{s}* ", .{rt.Custom});
            } else {
                try self.writer.appendSlice("int ");
            }
        } else {
            try self.writer.appendSlice("int ");
        }
    } else {
        if (decl.type_name) |tn| {
            if (std.mem.eql(u8, tn, "String")) {
                try self.writer.appendSlice("AetherString* ");
            } else if (std.mem.eql(u8, tn, "Int")) {
                try self.writer.appendSlice("int ");
            } else if (std.mem.eql(u8, tn, "Bool")) {
                try self.writer.appendSlice("bool ");
            } else {
                try self.writer.writer().print("{s}* ", .{tn});
            }
        } else {
            try self.writer.appendSlice("void ");
        }
    }
    
    try self.writer.writer().print("{s}_{s}({s}* self", .{class_name, decl.name, class_name});
    
    for (decl.params) |p| {
        try self.writer.appendSlice(", ");
        var is_ptr = false;
        var t_str: []const u8 = "int";
        if (p.type_name) |tn| {
            if (std.mem.eql(u8, tn, "String")) {
                t_str = "AetherString";
                is_ptr = true;
            } else if (self.classes.contains(tn)) {
                t_str = tn;
                is_ptr = true;
            }
        }
        if (is_ptr) {
            try self.writer.writer().print("{s}* {s}", .{t_str, p.name});
        } else {
            try self.writer.writer().print("{s} {s}", .{t_str, p.name});
        }
    }
    try self.writer.appendSlice(") {\n");

    if (decl.is_expr_body) {
        try self.writer.appendSlice("    return ");
        try self.emitExpression(decl.body);
        try self.writer.appendSlice(";\n");
    } else {
        switch (decl.body.data) {
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.emitStatement(stmt);
                }
            },
            else => unreachable,
        }
    }
    try self.writer.appendSlice("}\n\n");
}

pub fn emitFunDecl(self: *CTranspiler, node: *ASTNode) !void {
    const decl = node.data.fun_decl;
    const is_main = std.mem.eql(u8, decl.name, "main");
    
    if (is_main and self.is_test_mode) {
        return; // Skip user-defined main in test mode
    }
    
    const actual_name = decl.resolved_c_name orelse decl.name;
    const func_name = if (is_main) "aether_main" else actual_name;
    
    if (self.emitted_functions.contains(func_name)) return;
    try self.emitted_functions.put(func_name, {});

    if (is_main) {
        try self.writer.appendSlice("int ");
    } else if (decl.type_name) |tn| {
        if (std.mem.eql(u8, tn, "String")) {
            try self.writer.appendSlice("AetherString* ");
        } else if (self.classes.contains(tn)) {
            try self.writer.writer().print("{s}* ", .{tn});
        } else {
            try self.writer.appendSlice("int ");
        }
    } else if (decl.is_expr_body) {
        if (decl.body.resolved_type) |rt| {
            if (rt.* == .String) {
                try self.writer.appendSlice("AetherString* ");
            } else if (rt.* == .Custom) {
                try self.writer.writer().print("{s}* ", .{rt.Custom});
            } else {
                try self.writer.appendSlice("int ");
            }
        } else {
            try self.writer.appendSlice("int ");
        }
    } else {
        try self.writer.appendSlice("void ");
    }
    
    try self.writer.writer().print("{s}(", .{func_name});
    for (decl.params, 0..) |p, i| {
        if (i > 0) try self.writer.appendSlice(", ");
        var is_ptr = false;
        var t_str: []const u8 = "int";
        if (p.type_name) |tn| {
            if (std.mem.eql(u8, tn, "String")) {
                t_str = "AetherString";
                is_ptr = true;
            } else if (self.classes.contains(tn)) {
                t_str = tn;
                is_ptr = true;
            }
        }
        if (is_ptr) {
            try self.writer.writer().print("{s}* {s}", .{t_str, p.name});
        } else {
            try self.writer.writer().print("{s} {s}", .{t_str, p.name});
        }
    }
    try self.writer.appendSlice(") {\n");

    if (decl.is_expr_body) {
        try self.writer.appendSlice("    return ");
        try self.emitExpression(decl.body);
        try self.writer.appendSlice(";\n");
    } else {
        switch (decl.body.data) {
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.emitStatement(stmt);
                }
            },
            else => unreachable,
        }
    }
    try self.writer.appendSlice("}\n\n");
    
    if (is_main) {
        try self.writer.appendSlice("int main() {\n    return aether_main();\n}\n\n");
    }
}

pub fn emitTestDecl(self: *CTranspiler, node: *ASTNode) !void {
    const decl = node.data.test_decl;
    
    try self.test_names.append(decl.name);
    const test_id = self.test_count;
    self.test_count += 1;
    
    try self.writer.writer().print("void aether_test_{d}() {{\n", .{test_id});
    switch (decl.body.data) {
        .block => |b| {
            for (b.statements) |stmt| {
                try self.emitStatement(stmt);
            }
        },
        else => unreachable,
    }
    try self.writer.appendSlice("}\n\n");
}

pub fn emitLibDecl(self: *CTranspiler, node: *ASTNode) !void {
    const l = node.data.lib_decl;
    if (self.libs.contains(l.name)) return;
    try self.libs.put(l.name, {});

    for (l.annotations) |ann| {
        if (std.mem.eql(u8, ann.name, "Header")) {
            for (ann.arguments) |arg| {
                if (arg.len > 0 and arg[0] == '<' and arg[arg.len - 1] == '>') {
                    try self.writer.writer().print("#include {s}\n", .{arg});
                } else {
                    try self.writer.writer().print("#include \"{s}\"\n", .{arg});
                }
            }
        }
    }
    try self.writer.appendSlice("\n");
}
