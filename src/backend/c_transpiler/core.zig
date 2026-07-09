const std = @import("std");
const ast = @import("../../core/ast.zig");
const tc_mod = @import("../../core/type_checker/core.zig");
const type_system = @import("../../core/type_system.zig");
pub const ASTNode = ast.ASTNode;
pub const TokenType = ast.TokenType;

pub const std_lib_c = @import("std_lib.zig").std_lib_c;
pub const expr_mod = @import("expression.zig");
pub const stmt_mod = @import("statement.zig");
pub const decl_mod = @import("declaration.zig");

pub fn getCTypeStr(allocator: std.mem.Allocator, t: *const type_system.AetherType) ![]const u8 {
    switch (t.*) {
        .Int => return "int",
        .Bool => return "bool",
        .Pointer => return "char*",
        .String => return "system_String*",
        .Void => return "void",
        .Custom => |name| {
            if (std.mem.eql(u8, name, "Int")) return "int";
            if (std.mem.eql(u8, name, "Bool")) return "bool";
            return try std.fmt.allocPrint(allocator, "{s}*", .{name});
        },
        .Array => |elem| {
            const inner = try getCTypeStr(allocator, elem);
            var safe_inner = std.ArrayList(u8).init(allocator);
            for (inner) |c| {
                if (c == '*') continue;
                if (c == ' ') continue;
                try safe_inner.append(c);
            }
            return try std.fmt.allocPrint(allocator, "AetherArray_{s}*", .{safe_inner.items});
        },
        .Union => |u| {
            if (u.left.* != .Null) {
                return try getCTypeStr(allocator, u.left);
            } else {
                return try getCTypeStr(allocator, u.right);
            }
        },
        else => return "void*",
    }
}

pub const CTranspiler = struct {
    allocator: std.mem.Allocator,
    header_writer: std.ArrayList(u8),
    writer: std.ArrayList(u8),
    classes: std.StringHashMap(void),
    libs: std.StringHashMap(void),
    emitted_functions: std.StringHashMap(void),
    is_test_mode: bool = false,
    test_names: std.ArrayList([]const u8),
    test_count: usize = 0,

    pub const emitClassDecl = decl_mod.emitClassDecl;
    pub const emitMethodDecl = decl_mod.emitMethodDecl;
    pub const emitFunDecl = decl_mod.emitFunDecl;
    pub const emitTestDecl = decl_mod.emitTestDecl;
    pub const emitLibDecl = decl_mod.emitLibDecl;

    pub const emitStatement = stmt_mod.emitStatement;
    pub const emitExpression = expr_mod.emitExpression;

    pub fn init(allocator: std.mem.Allocator) CTranspiler {
        return CTranspiler{
            .allocator = allocator,
            .header_writer = std.ArrayList(u8).init(allocator),
            .writer = std.ArrayList(u8).init(allocator),
            .classes = std.StringHashMap(void).init(allocator),
            .libs = std.StringHashMap(void).init(allocator),
            .emitted_functions = std.StringHashMap(void).init(allocator),
            .is_test_mode = false,
            .test_names = std.ArrayList([]const u8).init(allocator),
            .test_count = 0,
        };
    }

    pub fn deinit(self: *CTranspiler) void {
        self.header_writer.deinit();
        self.writer.deinit();
        self.classes.deinit();
        self.libs.deinit();
        self.emitted_functions.deinit();
        self.test_names.deinit();
    }

    pub fn transpile(self: *CTranspiler, node: *ASTNode) ![]const u8 {
        try self.transpileNode(node, true);
        
        var final = std.ArrayList(u8).init(self.allocator);
        try final.appendSlice(std_lib_c);
        try final.appendSlice("\n");
        try final.appendSlice(self.header_writer.items);
        try final.appendSlice(self.writer.items);
        
        return try final.toOwnedSlice();
    }

    pub fn emitArrayStruct(self: *CTranspiler, elem: *const type_system.AetherType) !void {
        const inner_c_type = try getCTypeStr(self.allocator, elem);
        
        var safe_inner = std.ArrayList(u8).init(self.allocator);
        for (inner_c_type) |c| {
            if (c == '*') continue;
            if (c == ' ') continue;
            try safe_inner.append(c);
        }
        const struct_name = try std.fmt.allocPrint(self.allocator, "AetherArray_{s}", .{safe_inner.items});
        
        if (self.classes.contains(struct_name)) return;
        try self.classes.put(struct_name, {});
        
        var w = self.header_writer.writer();
        try w.print("typedef struct {{\n", .{});
        try w.print("    {s}* data;\n", .{inner_c_type});
        try w.print("    size_t length;\n", .{});
        try w.print("    size_t capacity;\n", .{});
        try w.print("}} {s};\n\n", .{struct_name});
        
        try w.print("{s}* {s}_new() {{\n", .{struct_name, struct_name});
        try w.print("    {s}* arr = GC_MALLOC(sizeof({s}));\n", .{struct_name, struct_name});
        try w.print("    arr->data = GC_MALLOC(4 * sizeof({s}));\n", .{inner_c_type});
        try w.print("    arr->length = 0;\n", .{});
        try w.print("    arr->capacity = 4;\n", .{});
        try w.print("    return arr;\n", .{});
        try w.print("}}\n\n", .{});
        
        try w.print("void {s}_push({s}* arr, {s} val) {{\n", .{struct_name, struct_name, inner_c_type});
        try w.print("    if (arr->length == arr->capacity) {{\n", .{});
        try w.print("        arr->capacity *= 2;\n", .{});
        try w.print("        arr->data = GC_REALLOC(arr->data, arr->capacity * sizeof({s}));\n", .{inner_c_type});
        try w.print("    }}\n", .{});
        try w.print("    arr->data[arr->length++] = val;\n", .{});
        try w.print("}}\n\n", .{});
    }

    pub fn transpileNode(self: *CTranspiler, node: *ASTNode, is_root: bool) !void {
        switch (node.data) {
            .program => |p| {
                var has_main = false;
                
                // Pass 1: Types (Classes) and Imports
                for (p.statements) |stmt| {
                    if (stmt.data == .import_stmt) {
                        if (stmt.data.import_stmt.module_ast) |mod_ast| {
                            try self.transpileNode(mod_ast, false);
                        }
                    } else if (stmt.data == .class_decl) {
                        try self.emitClassDecl(stmt);
                    } else if (stmt.data == .lib_decl) {
                        try self.emitLibDecl(stmt);
                    }
                }
                
                // Pass 2: Function Declarations
                for (p.statements) |stmt| {
                    if (stmt.data == .fun_decl) {
                        if (std.mem.eql(u8, stmt.data.fun_decl.name, "main")) has_main = true;
                        try self.emitFunDecl(stmt);
                    } else if (stmt.data == .test_decl and self.is_test_mode) {
                        try self.emitTestDecl(stmt);
                    }
                }
                
                // Pass 3: Top-Level Statements Collection
                var top_level_stmts = std.ArrayList(*ASTNode).init(self.allocator);
                defer top_level_stmts.deinit();
                for (p.statements) |stmt| {
                    if (stmt.data != .fun_decl and stmt.data != .class_decl and stmt.data != .import_stmt and stmt.data != .test_decl and stmt.data != .lib_decl) {
                        try top_level_stmts.append(stmt);
                    }
                }

                if (is_root) {
                    if (top_level_stmts.items.len > 0 and has_main) {
                        std.debug.print("Error: Cannot mix top-level statements with fun main()\n", .{});
                        return error.HybridMainConflict;
                    }

                    if (self.is_test_mode) {
                        try self.writer.appendSlice("int main() {\n");
                        for (self.test_names.items, 0..) |tname, i| {
                            try self.writer.writer().print("    aether_test_{d}();\n", .{i});
                            try self.writer.writer().print("    printf(\"[PASS] %s\\n\", \"{s}\");\n", .{tname});
                        }
                        try self.writer.appendSlice("    return 0;\n}\n");
                    } else if (!has_main) {
                        try self.writer.appendSlice("int main(int argc, char** argv) {\n");
                        try self.writer.appendSlice("    (void)argc;\n");
                        try self.writer.appendSlice("    (void)argv;\n");
                        
                        for (top_level_stmts.items) |stmt| {
                            try self.emitStatement(stmt);
                        }
                        try self.writer.appendSlice("    return 0;\n}\n");
                    }
                } else {
                    if (top_level_stmts.items.len > 0) {
                        std.debug.print("Error: Imported files cannot contain top-level statements (side-effects).\n", .{});
                        return error.ImportSideEffectsNotAllowed;
                    }
                }
            },
            else => return error.InvalidProgramNode,
        }
    }
};
