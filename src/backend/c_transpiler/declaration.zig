const std = @import("std");
const core = @import("core.zig");
const ts = @import("../../core/type_system.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

pub fn emitClassDecl(self: *CTranspiler, node: *ASTNode) !void {
    const class_decl = node.data.class_decl;
    const actual_name = class_decl.resolved_c_name orelse class_decl.name;
    if (self.classes.contains(actual_name)) return;
    try self.classes.put(actual_name, {});

    var primitive_type: ?[]const u8 = null;
    for (class_decl.annotations) |ann| {
        if (std.mem.eql(u8, ann.name, "Primitive") and ann.arguments.len > 0) {
            primitive_type = ann.arguments[0];
            break;
        }
    }

    if (primitive_type == null) {
        // Pre-emit any array structs needed for properties
        for (class_decl.primary_constructor) |prop| {
            if (prop.resolved_type) |rt| {
                if (ts.extractBaseType(rt).* == .Array) try self.emitArrayStruct(ts.extractBaseType(rt).Array);
            }
        }

        // Pre-emit any Custom struct dependencies (e.g. MutableList depends on List)
        if (self.classes_ast) |ca| {
            for (class_decl.primary_constructor) |prop| {
                if (prop.resolved_type) |rt| {
                    const base = ts.extractBaseType(rt);
                    if (base.* == .Custom) {
                        if (ca.get(base.Custom)) |dep_node| {
                            if (dep_node.data == .class_decl and dep_node.data.class_decl.generic_params.len == 0) {
                                try self.emitClassDecl(dep_node);
                            }
                        }
                    }
                }
            }
        }

        // Emit Struct
        try self.header_writer.writer().print("typedef struct {s} {s};\n", .{actual_name, actual_name});
        try self.header_writer.writer().print("struct {s} {{\n", .{actual_name});
        for (class_decl.primary_constructor) |prop| {
            var t_str: []const u8 = "void*";
            if (prop.resolved_type) |rt| {
                t_str = try core.getCTypeStr(self.allocator, rt);
            }
            try self.header_writer.writer().print("    {s} {s};\n", .{t_str, prop.name});
        }
        try self.header_writer.writer().print("}};\n\n", .{});

        // Emit Allocator/Constructor Declaration
        try self.header_writer.writer().print("{s}* {s}_new(", .{actual_name, actual_name});
        for (class_decl.primary_constructor, 0..) |prop, i| {
            if (i > 0) try self.header_writer.appendSlice(", ");
            var t_str: []const u8 = "void*";
            if (prop.resolved_type) |rt| {
                t_str = try core.getCTypeStr(self.allocator, rt);
            }
            try self.header_writer.writer().print("{s} {s}", .{t_str, prop.name});
        }
        try self.header_writer.appendSlice(");\n");
        if (primitive_type) |pt| {
            try self.header_writer.writer().print("{s} {s}_constructor({s} this);\n", .{actual_name, actual_name, pt});
        } else {
            try self.header_writer.writer().print("{s}* {s}_constructor({s}* this);\n", .{actual_name, actual_name, actual_name});
        }

        // Emit Allocator/Constructor Implementation
        try self.writer.writer().print("{s}* {s}_new(", .{actual_name, actual_name});
        for (class_decl.primary_constructor, 0..) |prop, i| {
            if (i > 0) try self.writer.appendSlice(", ");
            var t_str: []const u8 = "void*";
            if (prop.resolved_type) |rt| {
                t_str = try core.getCTypeStr(self.allocator, rt);
                if (ts.extractBaseType(rt).* == .Array) try self.emitArrayStruct(ts.extractBaseType(rt).Array);
            }
            try self.writer.writer().print("{s} {s}", .{t_str, prop.name});
        }
        try self.writer.writer().print(") {{\n", .{});
        try self.writer.writer().print("    {s}* instance = ({s}*)GC_MALLOC(sizeof({s}));\n", .{actual_name, actual_name, actual_name});
        for (class_decl.primary_constructor) |prop| {
            try self.writer.writer().print("    instance->{s} = {s};\n", .{prop.name, prop.name});
        }
        try self.writer.appendSlice("    return instance;\n}\n\n");
    }
    
    for (class_decl.methods) |method| {
        try self.emitMethodDecl(actual_name, method, primitive_type);
    }
}

pub fn emitMethodDecl(self: *CTranspiler, class_name: []const u8, node: *ASTNode, primitive_type: ?[]const u8) !void {
    const decl = node.data.fun_decl;
    
    // 1. Emit the signature to header_writer
    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        const ret_base = ts.extractBaseType(fun_type.return_type);
        // Forward-declare Custom return types that may not be defined yet
        if (ret_base.* == .Custom and !self.classes.contains(ret_base.Custom)) {
            try self.forward_writer.writer().print("typedef struct {s} {s};\n", .{ret_base.Custom, ret_base.Custom});
        }
        const ret_str = try core.getCTypeStr(self.allocator, fun_type.return_type);
        try self.header_writer.writer().print("{s} ", .{ret_str});
    } else {
        try self.header_writer.appendSlice("void ");
    }
    
    if (primitive_type) |pt| {
        try self.header_writer.writer().print("{s}_{s}({s} this", .{class_name, decl.name, pt});
    } else {
        try self.header_writer.writer().print("{s}_{s}({s}* this", .{class_name, decl.name, class_name});
    }
    
    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        for (decl.params, 0..) |p, i| {
            try self.header_writer.appendSlice(", ");
            const param_t_str = try core.getCTypeStr(self.allocator, fun_type.params[i]);
            try self.header_writer.writer().print("{s} {s}", .{param_t_str, p.name});
        }
    }
    try self.header_writer.appendSlice(");\n");

    // 2. Emit the implementation to writer
    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        const ret_str = try core.getCTypeStr(self.allocator, fun_type.return_type);
        if (ts.extractBaseType(fun_type.return_type).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.return_type).Array);
        try self.writer.writer().print("{s} ", .{ret_str});
    } else {
        try self.writer.appendSlice("void ");
    }
    
    if (primitive_type) |pt| {
        try self.writer.writer().print("{s}_{s}({s} this", .{class_name, decl.name, pt});
    } else {
        try self.writer.writer().print("{s}_{s}({s}* this", .{class_name, decl.name, class_name});
    }
    
    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        for (decl.params, 0..) |p, i| {
            try self.writer.appendSlice(", ");
            const param_t_str = try core.getCTypeStr(self.allocator, fun_type.params[i]);
            if (ts.extractBaseType(fun_type.params[i]).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.params[i]).Array);
            try self.writer.writer().print("{s} {s}", .{param_t_str, p.name});
        }
    }
    try self.writer.appendSlice(") {\n");

    // Emit #line directive so clang reports errors with the original .ae source location
    try self.writer.writer().print("#line {d} \"{s}\"\n", .{node.line, self.source_file});

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

    var sig = std.ArrayList(u8).init(self.allocator);
    if (is_main) {
        try sig.writer().print("int ", .{});
    } else if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        const ret_str = try core.getCTypeStr(self.allocator, fun_type.return_type);
        if (ts.extractBaseType(fun_type.return_type).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.return_type).Array);
        try sig.writer().print("{s} ", .{ret_str});
    } else {
        try sig.writer().print("void ", .{});
    }
    
    try sig.writer().print("{s}(", .{func_name});
    if (is_main) {
        // main has no params or argc/argv if needed later
    } else if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        for (decl.params, 0..) |p, i| {
            if (i > 0) try sig.writer().print(", ", .{});
            const param_t_str = try core.getCTypeStr(self.allocator, fun_type.params[i]);
            if (ts.extractBaseType(fun_type.params[i]).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.params[i]).Array);
            try sig.writer().print("{s} {s}", .{param_t_str, p.name});
        }
    }
    try sig.writer().print(")", .{});

    try self.header_writer.writer().print("{s};\n", .{sig.items});
    try self.writer.writer().print("{s} {{\n", .{sig.items});

    // Emit #line directive so clang reports errors with the original .ae source location
    try self.writer.writer().print("#line {d} \"{s}\"\n", .{node.line, self.source_file});

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
