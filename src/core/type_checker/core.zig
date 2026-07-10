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
pub const isBool = type_system.isBool;
pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    global_scope: Scope,
    source: []const u8,
    filename: []const u8,
    alias_map: std.StringHashMap([]const u8),
    module_prefix: ?[]const u8 = null,
    is_test_mode: bool = false,
    current_class_props: ?*std.StringHashMap(void) = null,
    classes_ast: std.StringHashMap(*ASTNode),


    pub const inferNode = core_inferNode;
    pub const reportError = core_reportError;
    pub const resolveTypeName = core_resolveTypeName;
    pub const validate = core_validate;
    pub const checkBlock = infer_stmt_mod.checkBlock;

    pub fn init(allocator: std.mem.Allocator, source: []const u8, filename: []const u8) TypeChecker {
        const checker = TypeChecker{
            .allocator = allocator,
            .global_scope = Scope.init(allocator, null),
            .source = source,
            .filename = filename,
            .alias_map = std.StringHashMap([]const u8).init(allocator),
            .module_prefix = null,
            .is_test_mode = false,
            .current_class_props = null,
            .classes_ast = std.StringHashMap(*ASTNode).init(allocator),
        };

        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.global_scope.deinit();
        self.alias_map.deinit();
        self.classes_ast.deinit();
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
    
    // Check primitives first
    if (std.mem.eql(u8, name, "Int")) {
        base_type = .Int;
    } else if (std.mem.eql(u8, name, "Bool")) {
        base_type = .Bool;
    } else if (std.mem.eql(u8, name, "Void")) {
        base_type = .Void;
    } else if (std.mem.eql(u8, name, "Pointer")) {
        base_type = .Pointer;
    } else {
        const actual_name = self.alias_map.get(name) orelse name;
        if (std.mem.startsWith(u8, actual_name, "[") and std.mem.endsWith(u8, actual_name, "]")) {
            const inner_name = actual_name[1 .. actual_name.len - 1];
            const inner_type = try self.resolveTypeName(inner_name, false);
            base_type = .{ .Array = inner_type };
        } else {
            base_type = .{ .Custom = actual_name };
        }
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
        if (!std.mem.eql(u8, basename, "core.ae")) {
            var new_stmts = try self.allocator.alloc(*ASTNode, node.data.program.statements.len + 1);
                
                const import_node = try self.allocator.create(ASTNode);
                import_node.* = .{
                    .line = 0,
                    .column = 0,
                    .resolved_type = null,
                    .data = .{ .import_stmt = .{
                        .module_path = "std.core",
                        .destructured = &[_][]const u8{}, // Empty means import ALL
                        .module_ast = null,
                    }}
                };
                
                new_stmts[0] = import_node;
                for (node.data.program.statements, 0..) |stmt, i| {
                    new_stmts[i + 1] = stmt;
                }
                node.data.program.statements = new_stmts;
        }
    }
    _ = try self.inferNode(node, &self.global_scope);
}

fn core_inferNode(self: *TypeChecker, node: *ASTNode, scope: *Scope) anyerror!*const AetherType {
    if (node.resolved_type) |rt| {
        return rt;
    }
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
        .for_stmt => try infer_stmt_mod.inferForStmt(self, node, scope, t),
        .return_stmt => try infer_stmt_mod.inferReturnStmt(self, node, scope, t),
        .block => return try self.checkBlock(node.data.block.statements, scope),
        .identifier => try infer_expr_mod.inferIdentifier(self, node, scope, t),
        .int_literal => t.* = .Int,
        .string_literal => {
            const literal_str = node.data.string_literal;
            const len = literal_str.len;
            
            const ptr_node = try self.allocator.create(ASTNode);
            ptr_node.* = .{
                .line = node.line,
                .column = node.column,
                .resolved_type = null,
                .data = .{ .string_literal = literal_str },
            };
            const ptr_type = try self.allocator.create(AetherType);
            ptr_type.* = .Pointer;
            ptr_node.resolved_type = ptr_type;
            
            const len_node = try self.allocator.create(ASTNode);
            len_node.* = .{
                .line = node.line,
                .column = node.column,
                .resolved_type = null,
                .data = .{ .int_literal = @as(i64, @intCast(len)) },
            };
            const int_type = try self.allocator.create(AetherType);
            int_type.* = .Int;
            len_node.resolved_type = int_type;
            
            const callee_node = try self.allocator.create(ASTNode);
            const resolved_c_name = self.alias_map.get("String");
            const actual_c_name = resolved_c_name orelse "String";
            
            callee_node.* = .{
                .line = node.line,
                .column = node.column,
                .resolved_type = null,
                .data = .{ .identifier = .{ .name = "String", .resolved_c_name = actual_c_name, .is_class_property = false } },
            };
            const callee_type = try self.allocator.create(AetherType);
            callee_type.* = .{ .Custom = actual_c_name };
            callee_node.resolved_type = callee_type;
            
            var args = try self.allocator.alloc(*ASTNode, 2);
            args[0] = ptr_node;
            args[1] = len_node;
            
            node.data = .{ .call_expr = .{ .callee = callee_node, .arguments = args } };
            t.* = .{ .Custom = actual_c_name };
        },
        .bool_literal => t.* = .Bool,
        .null_literal => t.* = .Null,
        .array_literal => try infer_expr_mod.inferArrayLiteral(self, node, scope, t),
        .index_expr => try infer_expr_mod.inferIndexExpr(self, node, scope, t),
    }
    if (node.resolved_type == null) {
        node.resolved_type = t;
    }
    return t;
}
