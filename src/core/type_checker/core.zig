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
const infer_when_mod = @import("infer_when.zig");
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
    objects_ast: std.StringHashMap(*ASTNode),
    functions_ast: std.StringHashMap(*ASTNode),
    monomorphized_nodes: std.ArrayList(*ASTNode),
    current_class_name: ?[]const u8 = null,

    pub const inferNode = core_inferNode;
    pub const reportError = core_reportError;
    pub const resolveTypeRef = core_resolveTypeRef;
    pub const cloneTypeRef = @import("clone.zig").cloneTypeRef;
    pub const resolveTypeName = core_resolveTypeName;
    pub const monomorphizeClass = @import("monomorphize.zig").monomorphizeClass;
    pub const cloneNode = @import("clone.zig").cloneNode;
    pub const validate = core_validate;
    pub const checkBlock = infer_stmt_mod.checkBlock;
    pub const isCompatible = core_isCompatible;
    pub const isSubclassOf = core_isSubclassOf;
    pub const injectImplicitImports = core_injectImplicitImports;

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
            .objects_ast = std.StringHashMap(*ASTNode).init(allocator),
            .functions_ast = std.StringHashMap(*ASTNode).init(allocator),
            .monomorphized_nodes = std.ArrayList(*ASTNode).init(allocator),
            .current_class_name = null,
        };

        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.global_scope.deinit();
        self.alias_map.deinit();
        self.classes_ast.deinit();
        self.objects_ast.deinit();
        self.functions_ast.deinit();
        self.monomorphized_nodes.deinit();
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

fn core_resolveTypeRef(self: *TypeChecker, ref: *const ast.ASTTypeRef) anyerror!*AetherType {
    var base_type: AetherType = .Void;
    var actual_is_nullable = ref.is_nullable;

    if (ref.is_function) {
        var params = std.ArrayList(*const AetherType).init(self.allocator);
        for (ref.generic_args) |arg| {
            try params.append(try self.resolveTypeRef(arg));
        }
        const ret_t = try self.resolveTypeRef(ref.return_type.?);
        const rec_t = if (ref.receiver_type) |rec| try self.resolveTypeRef(rec) else null;

        base_type = .{ .Function = .{
            .params = try params.toOwnedSlice(),
            .return_type = ret_t,
            .receiver = rec_t,
            .c_name = "",
        } };
    } else if (ref.is_array) {
        if (ref.generic_args.len != 1) return error.TypeError;
        const inner_type = try self.resolveTypeRef(ref.generic_args[0]);

        const list_base = "List";
        const type_args = try self.allocator.alloc(*const AetherType, 1);
        type_args[0] = inner_type;

        var mangled = std.ArrayList(u8).init(self.allocator);
        const resolved_base = self.alias_map.get(list_base) orelse list_base;
        try mangled.appendSlice(resolved_base);
        try mangled.appendSlice("_");
        try inner_type.formatSafe(mangled.writer());
        const mangled_name = try mangled.toOwnedSlice();

        try self.monomorphizeClass(resolved_base, type_args, mangled_name);

        const actual_mangled = self.alias_map.get(mangled_name) orelse mangled_name;
        base_type = .{ .Custom = actual_mangled };
    } else {
        var alias = self.alias_map.get(ref.name) orelse ref.name;
        if (!self.classes_ast.contains(alias)) {
            if (std.mem.endsWith(u8, alias, "?")) {
                actual_is_nullable = true;
                alias = alias[0 .. alias.len - 1];
            } else if (std.mem.endsWith(u8, alias, "Opt")) {
                actual_is_nullable = true;
                alias = alias[0 .. alias.len - 3];
            }
        }

        // Check primitives first
        if (std.mem.eql(u8, alias, "Int")) {
            base_type = .Int;
        } else if (std.mem.eql(u8, alias, "Bool")) {
            base_type = .Bool;
        } else if (std.mem.eql(u8, alias, "Void")) {
            base_type = .Void;
        } else if (std.mem.eql(u8, alias, "OpaquePointer")) {
            base_type = .{ .Pointer = try self.allocator.create(AetherType) };
            @constCast(base_type.Pointer).* = .Void;
        } else if (std.mem.eql(u8, alias, "Null")) {
            base_type = .Null;
        } else if (ref.generic_args.len > 0) {
            var args_list = std.ArrayList(*const AetherType).init(self.allocator);
            for (ref.generic_args) |arg| {
                const arg_type = try self.resolveTypeRef(arg);
                try args_list.append(arg_type);
            }
            const type_args = try args_list.toOwnedSlice();

            if (std.mem.eql(u8, alias, "NativeArray")) {
                if (type_args.len != 1) return error.TypeError;
                base_type = .{ .Array = type_args[0] };
            } else if (std.mem.eql(u8, alias, "Pointer")) {
                if (type_args.len != 1) return error.TypeError;
                base_type = .{ .Pointer = type_args[0] };
            } else {
                base_type = .{ .GenericInstance = .{ .base_name = alias, .type_args = type_args } };

                var mangled = std.ArrayList(u8).init(self.allocator);
                try mangled.appendSlice(alias);
                try mangled.appendSlice("_");
                for (type_args, 0..) |t_arg, i| {
                    if (i > 0) try mangled.appendSlice("_");
                    try t_arg.formatSafe(mangled.writer());
                }
                const mangled_name = try mangled.toOwnedSlice();

                try self.monomorphizeClass(alias, type_args, mangled_name);

                const actual_mangled = self.alias_map.get(mangled_name) orelse mangled_name;
                base_type = .{ .Custom = actual_mangled };
            }
        } else {
            base_type = .{ .Custom = alias };
        }
    }

    const t = try self.allocator.create(AetherType);
    if (actual_is_nullable) {
        t.* = .{ .Union = .{
            .left = try self.allocator.create(AetherType),
            .right = try self.allocator.create(AetherType),
        } };
        @constCast(t.Union.left).* = base_type;
        @constCast(t.Union.right).* = .Null;
    } else {
        t.* = base_type;
    }
    @constCast(ref).resolved_type = t;
    return t;
}

fn core_resolveTypeName(self: *TypeChecker, name: []const u8, is_nullable: bool) anyerror!*AetherType {
    var p = parser_mod.Parser.init(self.allocator, name);
    const ref = try p.parseType();
    if (is_nullable) {
        @constCast(ref).is_nullable = true;
    }
    return try self.resolveTypeRef(ref);
}

fn core_injectImplicitImports(self: *TypeChecker, node: *ASTNode) anyerror!void {
    const basename = std.fs.path.basename(self.filename);
    
    // std.core itself has absolutely no implicit imports
    if (std.mem.eql(u8, basename, "core.ae")) return;
    
    const is_std_lib = std.mem.startsWith(u8, self.filename, "std/") or std.mem.indexOf(u8, self.filename, "std/") != null;
    
    const implicit_imports = if (is_std_lib)
        &[_][]const u8{ "std.core" }
    else
        &[_][]const u8{ "std.core", "std.env", "std.collections", "std.time" };
    
    const import_count = implicit_imports.len;
    var new_stmts = try self.allocator.alloc(*ASTNode, node.data.program.statements.len + import_count);
    
    for (implicit_imports, 0..) |imp_path, i| {
        const import_node = try self.allocator.create(ASTNode);
        import_node.* = .{
            .line = 0,
            .column = 0,
            .resolved_type = null,
            .data = .{
                .import_stmt = .{
                    .module_path = imp_path,
                    .destructured = &[_][]const u8{},
                    .module_ast = null,
                },
            },
        };
        new_stmts[i] = import_node;
    }
    
    for (node.data.program.statements, 0..) |stmt, i| {
        new_stmts[i + import_count] = stmt;
    }
    node.data.program.statements = new_stmts;
}

fn core_validate(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (node.data == .program) {
        try self.injectImplicitImports(node);
    }
    if (node.data == .program) {
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .class_decl) {
                var c = &stmt.data.class_decl;
                if (c.resolved_c_name == null) {
                    if (self.module_prefix) |prefix| {
                        c.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, c.name });
                        if (!std.mem.eql(u8, c.name, "Int") and !std.mem.eql(u8, c.name, "Bool") and !std.mem.eql(u8, c.name, "Pointer") and !std.mem.eql(u8, c.name, "OpaquePointer")) {
                            try self.alias_map.put(c.name, c.resolved_c_name.?);
                        }
                    } else {
                        c.resolved_c_name = c.name;
                    }
                }
                const actual_c_name = c.resolved_c_name.?;
                const class_type = try self.allocator.create(AetherType);
                if (std.mem.eql(u8, c.name, "Int")) {
                    class_type.* = .Int;
                } else if (std.mem.eql(u8, c.name, "Bool")) {
                    class_type.* = .Bool;
                } else if (std.mem.eql(u8, c.name, "String")) {
                    class_type.* = .{ .Custom = actual_c_name };
                } else if (std.mem.eql(u8, c.name, "OpaquePointer") or std.mem.eql(u8, c.name, "Pointer")) {
                    class_type.* = .{ .Pointer = try self.allocator.create(AetherType) };
                    @constCast(class_type.Pointer).* = .Void;
                } else {
                    class_type.* = .{ .Custom = actual_c_name };
                }
                _ = self.global_scope.define(c.name, class_type, false, false) catch {};
                if (!std.mem.eql(u8, c.name, actual_c_name)) {
                    _ = self.global_scope.define(actual_c_name, class_type, false, false) catch {};
                }
                try self.classes_ast.put(actual_c_name, stmt);
            } else if (stmt.data == .object_decl) {
                var o = &stmt.data.object_decl;
                if (o.name) |o_name| {
                    if (o.resolved_c_name == null) {
                        if (self.module_prefix) |prefix| {
                            o.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, o_name });
                            try self.alias_map.put(o_name, o.resolved_c_name.?);
                        } else {
                            o.resolved_c_name = o_name;
                        }
                    }
                    const actual_c_name = o.resolved_c_name.?;
                    const obj_type = try self.allocator.create(AetherType);
                    obj_type.* = .{ .Custom = actual_c_name };
                    try self.objects_ast.put(actual_c_name, stmt);
                    if (self.global_scope.lookupVariable(o_name) == null) {
                        _ = self.global_scope.define(o_name, obj_type, false, false) catch {};
                        if (!std.mem.eql(u8, o_name, actual_c_name)) {
                            _ = self.global_scope.define(actual_c_name, obj_type, false, false) catch {};
                        }
                    }
                }
            }
        }
    }
    _ = try self.inferNode(node, &self.global_scope);

    // Append any dynamically monomorphized classes to the AST
    if (node.data == .program and self.monomorphized_nodes.items.len > 0) {
        var final_stmts = try self.allocator.alloc(*ASTNode, node.data.program.statements.len + self.monomorphized_nodes.items.len);
        for (node.data.program.statements, 0..) |stmt, i| {
            final_stmts[i] = stmt;
        }
        for (self.monomorphized_nodes.items, 0..) |stmt, i| {
            final_stmts[node.data.program.statements.len + i] = stmt;
        }
        node.data.program.statements = final_stmts;
    }
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
        .object_decl => try infer_decl_mod.inferObjectDecl(self, node, scope, t),
        .fun_decl => try infer_decl_mod.inferFunDecl(self, node, scope, t),
        .var_decl => try infer_decl_mod.inferVarDecl(self, node, scope, t),
        .assignment => try infer_expr_mod.inferAssignment(self, node, scope, t),
        .unary_expr => try infer_expr_mod.inferUnaryExpr(self, node, scope, t),
        .binary_expr => try infer_expr_mod.inferBinaryExpr(self, node, scope, t),
        .get_expr => try infer_expr_mod.inferGetExpr(self, node, scope, t),
        .set_expr => try infer_expr_mod.inferSetExpr(self, node, scope, t),
        .call_expr => try infer_expr_mod.inferCallExpr(self, node, scope, t),
        .as_expr => try infer_expr_mod.inferAsExpr(self, node, scope, t),
        .is_expr => try infer_expr_mod.inferIsExpr(self, node, scope, t),
        .ternary_expr => try infer_expr_mod.inferTernaryExpr(self, node, scope, t),
        .if_expr => try infer_stmt_mod.inferIfExpr(self, node, scope, t),
        .while_stmt => try infer_stmt_mod.inferWhileStmt(self, node, scope, t),
        .for_stmt => try infer_stmt_mod.inferForStmt(self, node, scope, t),
        .return_stmt => try infer_stmt_mod.inferReturnStmt(self, node, scope, t),
        .try_stmt => try infer_stmt_mod.inferTryStmt(self, node, scope, t),
        .throw_stmt => try infer_stmt_mod.inferThrowStmt(self, node, scope, t),
        .block => return try self.checkBlock(node.data.block.statements, scope),
        .is_type_cond => t.* = .Bool,
        .when_expr => try infer_when_mod.inferWhenExpr(self, node, scope, t),
        .lambda_expr => try infer_expr_mod.inferLambdaExpr(self, node, scope, t),
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
            ptr_type.* = .{ .Pointer = try self.allocator.create(AetherType) };
            @constCast(ptr_type.Pointer).* = .Void;
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
        .map_literal => try infer_expr_mod.inferMapLiteral(self, node, scope, t),
        .index_expr => try infer_expr_mod.inferIndexExpr(self, node, scope, t),
        .index_set_expr => try infer_expr_mod.inferIndexSetExpr(self, node, scope, t),
    }
    if (node.resolved_type == null) {
        node.resolved_type = t;
    }
    return t;
}

fn core_isSubclassOf(self: *TypeChecker, subclass_name: []const u8, superclass_name: []const u8) bool {
    if (std.mem.eql(u8, subclass_name, superclass_name)) return true;

    var current_name = subclass_name;
    while (true) {
        const class_node = self.classes_ast.get(current_name) orelse return false;
        const c = class_node.data.class_decl;
        if (c.superclass_name) |parent| {
            const parent_actual = self.alias_map.get(parent) orelse parent;
            if (std.mem.eql(u8, parent_actual, superclass_name)) return true;
            current_name = parent_actual;
        } else {
            break;
        }
    }
    return false;
}

fn core_isCompatible(self: *TypeChecker, expected: *const AetherType, actual: *const AetherType) bool {
    if (expected.* == .Unknown or actual.* == .Unknown) return true;
    if (isNullable(expected) and actual.* == .Null) return true;
    if (isNullable(actual) and !isNullable(expected)) return false;

    const exp_base = extractBaseType(expected);
    const act_base = extractBaseType(actual);

    if (exp_base.* == .Custom and act_base.* == .Custom) {
        return self.isSubclassOf(act_base.Custom, exp_base.Custom);
    }

    if (std.meta.activeTag(exp_base.*) == std.meta.activeTag(act_base.*)) {
        switch (exp_base.*) {
            .Array => |elem| {
                if (act_base.* == .Array) {
                    return self.isCompatible(elem, act_base.Array);
                }
                return false;
            },
            .Pointer => |elem| {
                if (act_base.* == .Pointer) {
                    if (elem.* == .Void or act_base.Pointer.* == .Void) return true;
                    return self.isCompatible(elem, act_base.Pointer);
                }
                return false;
            },
            .Function => |f_exp| {
                if (act_base.* != .Function) return false;
                const f_act = act_base.Function;
                if (f_exp.params.len != f_act.params.len) return false;
                if (f_exp.receiver) |rec_exp| {
                    if (f_act.receiver) |rec_act| {
                        if (!self.isCompatible(rec_exp, rec_act)) return false;
                    } else {
                        return false;
                    }
                } else {
                    if (f_act.receiver != null) return false;
                }
                for (f_exp.params, 0..) |p_exp, i| {
                    if (!self.isCompatible(p_exp, f_act.params[i])) return false;
                }
                return self.isCompatible(f_exp.return_type, f_act.return_type);
            },
            else => return true,
        }
    }
    return false;
}
