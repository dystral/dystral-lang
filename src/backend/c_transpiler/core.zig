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

pub const CTranspiler = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8),
    classes: std.StringHashMap(void),
    emitted_functions: std.StringHashMap(void),
    is_test_mode: bool = false,
    test_names: std.ArrayList([]const u8),
    test_count: usize = 0,

    pub const emitClassDecl = decl_mod.emitClassDecl;
    pub const emitMethodDecl = decl_mod.emitMethodDecl;
    pub const emitFunDecl = decl_mod.emitFunDecl;
    pub const emitTestDecl = decl_mod.emitTestDecl;

    pub const emitStatement = stmt_mod.emitStatement;
    pub const emitExpression = expr_mod.emitExpression;

    pub fn init(allocator: std.mem.Allocator) CTranspiler {
        return CTranspiler{
            .allocator = allocator,
            .writer = std.ArrayList(u8).init(allocator),
            .classes = std.StringHashMap(void).init(allocator),
            .emitted_functions = std.StringHashMap(void).init(allocator),
            .is_test_mode = false,
            .test_names = std.ArrayList([]const u8).init(allocator),
            .test_count = 0,
        };
    }

    pub fn deinit(self: *CTranspiler) void {
        self.writer.deinit();
        self.classes.deinit();
        self.emitted_functions.deinit();
        self.test_names.deinit();
    }

    pub fn transpile(self: *CTranspiler, node: *ASTNode) ![]const u8 {
        try self.writer.appendSlice(std_lib_c);
        try self.writer.appendSlice("\n");
        try self.transpileNode(node, true);
        return try self.writer.toOwnedSlice();
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
                    if (stmt.data != .fun_decl and stmt.data != .class_decl and stmt.data != .import_stmt and stmt.data != .test_decl) {
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
