const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../../frontend/parser/core.zig");
const type_system = @import("../type_system.zig");

pub const ASTNode = ast.ASTNode;
pub const AetherType = type_system.AetherType;
pub const Scope = type_system.Scope;

const infer_expr_mod = @import("infer_expr.zig");
const infer_stmt_mod = @import("infer_stmt.zig");
const infer_decl_mod = @import("infer_decl.zig");
pub const isCompatible = type_system.isCompatible;
pub const isNullable = type_system.isNullable;
pub const extractBaseType = type_system.extractBaseType;
pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    global_scope: Scope,
    source: []const u8,
    filename: []const u8,
    alias_map: std.StringHashMap([]const u8),
    module_prefix: ?[]const u8 = null,
    is_test_mode: bool = false,
    current_class_props: ?*std.StringHashMap(void) = null,


    pub const inferNode = core_inferNode;
    pub const reportError = core_reportError;
    pub const resolveTypeName = core_resolveTypeName;
    pub const validate = core_validate;
    pub const checkBlock = infer_stmt_mod.checkBlock;

    pub fn init(allocator: std.mem.Allocator, source: []const u8, filename: []const u8) TypeChecker {
        var checker = TypeChecker{
            .allocator = allocator,
            .global_scope = Scope.init(allocator, null),
            .source = source,
            .filename = filename,
            .alias_map = std.StringHashMap([]const u8).init(allocator),
            .module_prefix = null,
            .is_test_mode = false,
            .current_class_props = null,
        };

        const string_t = allocator.create(AetherType) catch unreachable;
        string_t.* = .String;
        checker.global_scope.define("String", string_t) catch unreachable;

        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.global_scope.deinit();
        self.alias_map.deinit();
    }
};

fn core_reportError(self: *TypeChecker, line: usize, column: usize, comptime message: []const u8, args: anytype) void {
    std.debug.print("\n\x1b[31mError\x1b[0m in {s}:{}:{}:\n", .{ self.filename, line, column });

    var current_line: usize = 1;
    var start_idx: usize = 0;
    var end_idx: usize = 0;

    while (end_idx < self.source.len) : (end_idx += 1) {
        if (self.source[end_idx] == '\n') {
            if (current_line == line) break;
            current_line += 1;
            start_idx = end_idx + 1;
        }
    }
    if (end_idx > self.source.len) end_idx = self.source.len;

    const line_str = self.source[start_idx..end_idx];
    std.debug.print("    {s}\n", .{line_str});

    std.debug.print("    ", .{});
    var i: usize = 1;
    while (i < column) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("\x1b[31m^-- ", .{});
    std.debug.print(message, args);
    std.debug.print("\x1b[0m\n\n", .{});
}

fn core_resolveTypeName(self: *TypeChecker, name: []const u8, is_nullable: bool) !*AetherType {
    var base_type: AetherType = .Void;
    if (std.mem.eql(u8, name, "Int")) {
        base_type = .Int;
    } else if (std.mem.eql(u8, name, "String")) {
        base_type = .String;
    } else if (std.mem.eql(u8, name, "Bool")) {
        base_type = .Bool;
    } else {
        base_type = .{ .Custom = name };
    }

    const t = try self.allocator.create(AetherType);
    if (is_nullable) {
        t.* = .{ .Union = .{
            .left = try self.allocator.create(AetherType),
            .right = try self.allocator.create(AetherType),
        } };
        @constCast(t.Union.left).* = base_type;
        @constCast(t.Union.right).* = .Null;
    } else {
        t.* = base_type;
    }
    return t;
}

fn core_validate(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (node.data == .program) {
        const basename = std.fs.path.basename(self.filename);
        if (!std.mem.eql(u8, basename, "system.ae")) {
            const dir_path = std.fs.path.dirname(self.filename) orelse ".";
            var mod_path = try std.fs.path.join(self.allocator, &.{ dir_path, "system.ae" });
            
            var final_module_path: []const u8 = "system";
            
            if (std.fs.cwd().access(mod_path, .{}) == error.FileNotFound) {
                // Try parent dir
                const parent = std.fs.path.dirname(dir_path) orelse ".";
                mod_path = try std.fs.path.join(self.allocator, &.{ parent, "system.ae" });
                final_module_path = "../system";
            }
            
            if (std.fs.cwd().access(mod_path, .{})) |_| {
                var new_stmts = try self.allocator.alloc(*ASTNode, node.data.program.statements.len + 1);
                
                const import_node = try self.allocator.create(ASTNode);
                import_node.* = .{
                    .line = 0,
                    .column = 0,
                    .resolved_type = null,
                    .data = .{ .import_stmt = .{
                        .module_path = final_module_path,
                        .destructured = &[_][]const u8{}, // Empty means import ALL
                        .module_ast = null,
                    }}
                };
                
                new_stmts[0] = import_node;
                for (node.data.program.statements, 0..) |stmt, i| {
                    new_stmts[i + 1] = stmt;
                }
                node.data.program.statements = new_stmts;
            } else |_| {}
        }
    }
    _ = try self.inferNode(node, &self.global_scope);
}

fn core_inferNode(self: *TypeChecker, node: *ASTNode, scope: *Scope) anyerror!*const AetherType {
    const t = try self.allocator.create(AetherType);
    switch (node.data) {
        .program => |p| {
            for (p.statements) |stmt| {
                if (stmt.data == .test_decl and !self.is_test_mode) continue;
                _ = try self.inferNode(stmt, scope);
            }
            t.* = .Void;
        },
        .test_decl => |td| {
            _ = try self.inferNode(td.body, scope);
            t.* = .Void;
        },
        .import_stmt => try infer_decl_mod.inferImportStmt(self, node, scope, t),
        .lib_decl => try infer_decl_mod.inferLibDecl(self, node, scope, t),
        .class_decl => try infer_decl_mod.inferClassDecl(self, node, scope, t),
        .fun_decl => try infer_decl_mod.inferFunDecl(self, node, scope, t),
        .var_decl => try infer_decl_mod.inferVarDecl(self, node, scope, t),
        .assignment => try infer_expr_mod.inferAssignment(self, node, scope, t),
        .unary_expr => try infer_expr_mod.inferUnaryExpr(self, node, scope, t),
        .binary_expr => try infer_expr_mod.inferBinaryExpr(self, node, scope, t),
        .get_expr => try infer_expr_mod.inferGetExpr(self, node, scope, t),
        .set_expr => try infer_expr_mod.inferSetExpr(self, node, scope, t),
        .call_expr => try infer_expr_mod.inferCallExpr(self, node, scope, t),
        .if_expr => try infer_stmt_mod.inferIfExpr(self, node, scope, t),
        .while_stmt => try infer_stmt_mod.inferWhileStmt(self, node, scope, t),
        .return_stmt => try infer_stmt_mod.inferReturnStmt(self, node, scope, t),
        .block => return try self.checkBlock(node.data.block.statements, scope),
        .identifier => try infer_expr_mod.inferIdentifier(self, node, scope, t),
        .int_literal => t.* = .Int,
        .string_literal => t.* = .String,
        .bool_literal => t.* = .Bool,
        .null_literal => t.* = .Null,
    }
    node.resolved_type = t;
    return t;
}
