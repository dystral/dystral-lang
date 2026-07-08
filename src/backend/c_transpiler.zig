const std = @import("std");
const ast = @import("../core/ast.zig");
const types = @import("../core/types.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;

const std_lib_c = 
    \\#include <stdio.h>
    \\#include <gc.h>
    \\#include <string.h>
    \\#include <stdbool.h>
    \\
    \\typedef struct {
    \\    char* buffer;
    \\    int length;
    \\} AetherString;
    \\
    \\AetherString* AetherString_new(const char* literal) {
    \\    AetherString* s = (AetherString*)GC_MALLOC(sizeof(AetherString));
    \\    s->length = strlen(literal);
    \\    s->buffer = (char*)GC_MALLOC(s->length + 1);
    \\    strcpy(s->buffer, literal);
    \\    return s;
    \\}
    \\
    \\AetherString* AetherString_plus(AetherString* a, AetherString* b) {
    \\    AetherString* s = (AetherString*)GC_MALLOC(sizeof(AetherString));
    \\    s->length = a->length + b->length;
    \\    s->buffer = (char*)GC_MALLOC(s->length + 1);
    \\    strcpy(s->buffer, a->buffer);
    \\    strcat(s->buffer, b->buffer);
    \\    return s;
    \\}
    \\
    \\void AetherString_print(void* ptr) {
    \\    AetherString* s = (AetherString*)ptr;
    \\    if (s == NULL) printf("null\n");
    \\    else printf("%s\n", s->buffer);
    \\}
    \\
    \\#define print(x) _Generic((x), \
    \\    int: printf("%d\n", (int)(size_t)(x)), \
    \\    AetherString*: AetherString_print((void*)(size_t)(x)), \
    \\    bool: printf("%s\n", (x) ? "true" : "false"), \
    \\    default: printf("unknown\n") \
    \\)
    \\
;

/// Generates Intermediate C Code from an Aether AST.
pub const CTranspiler = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8),
    classes: std.StringHashMap(void), // Set of known class names

    pub fn init(allocator: std.mem.Allocator) CTranspiler {
        return CTranspiler{
            .allocator = allocator,
            .writer = std.ArrayList(u8).init(allocator),
            .classes = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *CTranspiler) void {
        self.writer.deinit();
        self.classes.deinit();
    }

    pub fn transpile(self: *CTranspiler, node: *ASTNode) ![]const u8 {
        try self.writer.appendSlice(std_lib_c);
        try self.writer.appendSlice("\n");
        try self.transpileNode(node, true);
        return try self.writer.toOwnedSlice();
    }

    fn transpileNode(self: *CTranspiler, node: *ASTNode, is_root: bool) !void {

        switch (node.data) {
            .program => |p| {
                var has_main = false;
                
                // Pass 1: Types (Classes) and Imports
                for (p.statements) |stmt| {
                    if (stmt.data == .import_stmt) {
                        if (stmt.data.import_stmt.module_ast) |mod_ast| {
                            try self.transpileNode(mod_ast, false); // Recursively transpile imported module
                        }
                    } else if (stmt.data == .class_decl) {
                        try self.emitClassDecl(stmt);
                    }
                }
                
                // Pass 2: Function Declarations
                for (p.statements) |stmt| {
                    if (stmt.data == .fun_decl) {
                        if (std.mem.eql(u8, stmt.data.fun_decl.name, "main")) has_main = true;
                        try self.emitFunDecl(stmt);
                    }
                }
                
                // Pass 3: Main body
                for (p.statements) |stmt| {
                    if (stmt.data != .fun_decl and stmt.data != .class_decl and stmt.data != .import_stmt) {
                        try self.emitStatement(stmt);
                    }
                }

                if (is_root and !has_main) {
                    try self.writer.appendSlice("int main() {\n    return 0;\n}\n");
                }
            },
            else => return error.InvalidProgramNode,
        }
    }

    fn emitClassDecl(self: *CTranspiler, node: *ASTNode) !void {
        const class_decl = node.data.class_decl;
        const actual_name = class_decl.resolved_c_name orelse class_decl.name;
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

    fn emitMethodDecl(self: *CTranspiler, class_name: []const u8, node: *ASTNode) !void {
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
            try self.writer.appendSlice("void ");
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

    fn emitFunDecl(self: *CTranspiler, node: *ASTNode) !void {
        const decl = node.data.fun_decl;
        const actual_name = decl.resolved_c_name orelse decl.name;
        const is_main = std.mem.eql(u8, decl.name, "main");
        const func_name = if (is_main) "aether_main" else actual_name;
        
        if (is_main) {
            try self.writer.appendSlice("int ");
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

    fn emitStatement(self: *CTranspiler, node: *ASTNode) !void {
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
            else => {
                try self.writer.appendSlice("    ");
                try self.emitExpression(node);
                try self.writer.appendSlice(";\n");
            },
        }
    }

    fn emitExpression(self: *CTranspiler, node: *ASTNode) !void {
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
                try self.writer.writer().print("AetherString_new(\"{s}\")", .{val});
            },
            .identifier => |i| {
                if (i.resolved_c_name) |cname| {
                    try self.writer.appendSlice(cname);
                } else {
                    try self.writer.appendSlice(i.name);
                }
            },
            .unary_expr => |u| {
                if (u.operator == .bang_bang) {
                    try self.emitExpression(u.operand);
                }
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
                    var class_name: []const u8 = "unknown";
                    if (rt.* == .String) {
                        class_name = "AetherString";
                    } else if (rt.* == .Custom) {
                        class_name = rt.Custom;
                    } else if (rt.* == .Union) {
                        if (rt.Union.left.* == .String) {
                            class_name = "AetherString";
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
};

test "CTranspiler base cases" {
    const parser_mod = @import("../frontend/parser.zig");
    
    const source = 
        \\val nome = "Leo"
        \\fun somar(a, b) = a + b
    ;
    
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    
    var parser = parser_mod.Parser.init(arena.allocator(), source);
    const ast_root = try parser.parse();
    
    // Set mock resolved_type to bypass TypeChecker in this isolated test
    ast_root.data.program.statements[0].data.var_decl.initializer.?.resolved_type = &types.AetherType{ .String = {} };
    
    var transpiler = CTranspiler.init(std.testing.allocator);
    defer transpiler.deinit();
    
    const c_code = try transpiler.transpile(ast_root);
    defer std.testing.allocator.free(c_code);
    
    try std.testing.expect(std.mem.indexOf(u8, c_code, "int somar(int a, int b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_code, "return a + b;") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_code, "int main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_code, "AetherString* nome = AetherString_new(\"Leo\");") != null);
}
