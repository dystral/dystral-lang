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
    monomorphized_nodes: std.ArrayList(*ASTNode),


    pub const inferNode = core_inferNode;
    pub const reportError = core_reportError;
    pub const resolveTypeRef = core_resolveTypeRef;
    pub const cloneTypeRef = core_cloneTypeRef;
    pub const resolveTypeName = core_resolveTypeName;
    pub const monomorphizeClass = core_monomorphizeClass;
    pub const cloneNode = core_cloneNode;
    pub const validate = core_validate;
    pub const checkBlock = infer_stmt_mod.checkBlock;
    pub const isCompatible = core_isCompatible;
    pub const isSubclassOf = core_isSubclassOf;

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
            .monomorphized_nodes = std.ArrayList(*ASTNode).init(allocator),
        };

        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.global_scope.deinit();
        self.alias_map.deinit();
        self.classes_ast.deinit();
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

    if (ref.is_array) {
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

fn core_cloneTypeRef(self: *TypeChecker, ref: *const ast.ASTTypeRef) anyerror!*ast.ASTTypeRef {
    const new_ref = try self.allocator.create(ast.ASTTypeRef);
    var name = ref.name;
    if (self.alias_map.get(ref.name)) |aliased| {
        name = aliased;
    }
    
    var generic_args = try self.allocator.alloc(*const ast.ASTTypeRef, ref.generic_args.len);
    for (ref.generic_args, 0..) |arg, i| {
        generic_args[i] = try self.cloneTypeRef(arg);
    }
    
    new_ref.* = .{
        .name = name,
        .generic_args = generic_args,
        .is_array = ref.is_array,
        .is_nullable = ref.is_nullable,
    };
    return new_ref;
}

fn core_resolveTypeName(self: *TypeChecker, name: []const u8, is_nullable: bool) anyerror!*AetherType {
    var p = parser_mod.Parser.init(self.allocator, name);
    const ref = try p.parseType();
    if (is_nullable) {
        @constCast(ref).is_nullable = true;
    }
    return try self.resolveTypeRef(ref);
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

fn core_monomorphizeClass(self: *TypeChecker, base_name: []const u8, type_args: []*const AetherType, mangled_name: []const u8) !void {
    if (self.classes_ast.get(mangled_name) != null) return;
    
    const actual_base_name = self.alias_map.get(base_name) orelse base_name;
    const base_node = self.classes_ast.get(actual_base_name);
    if (base_node == null) {
        self.reportError(0, 0, "TypeError: Generic class '{s}' not found.", .{base_name});
        return error.TypeError;
    }
    
    const new_node = try self.allocator.create(ASTNode);
    new_node.* = base_node.?.*;
    
    // Temporarily insert to avoid infinite recursion (e.g. Node<K, V> having next: Node<K, V>)
    try self.classes_ast.put(mangled_name, new_node);
    
    const class_decl = base_node.?.data.class_decl;
    if (class_decl.generic_params.len != type_args.len) {
        self.reportError(0, 0, "TypeError: Expected {} generic arguments for '{s}', got {}.", .{class_decl.generic_params.len, base_name, type_args.len});
        return error.TypeError;
    }
    
    // Create the generic map mapping (e.g. "T" -> .String)
    var generic_map = std.StringHashMap(*const AetherType).init(self.allocator);
    defer generic_map.deinit();
    for (class_decl.generic_params, 0..) |param_name, i| {
        try generic_map.put(param_name, type_args[i]);
    }
    
    // For now, we simulate Monomorphization by re-defining the class directly
    // and using `alias_map` to map the generic parameter to the concrete type!
    // Wait! A much smarter way: Re-run `inferClassDecl` dynamically with a hooked alias_map!
    // Since we need to typecheck its methods, we can just inject "T" -> "String" in alias_map
    // and run inferClassDecl on the same node again!
    // BUT we must avoid modifying the original node if it's shared. 
    // Actually, we can clone just the `class_decl` properties and methods.
    
    // Setup alias_map early so resolveTypeName can use it!
    var old_aliases = std.StringHashMap([]const u8).init(self.allocator);
    defer old_aliases.deinit();

    for (class_decl.generic_params, 0..) |param_name, i| {
        const conc_name = try std.fmt.allocPrint(self.allocator, "{}", .{type_args[i].*});
        if (self.alias_map.get(param_name)) |old_val| {
            try old_aliases.put(param_name, old_val);
        }
        try self.alias_map.put(param_name, conc_name);
    }

    var new_props = try self.allocator.alloc(ast.ClassProp, class_decl.primary_constructor.len);
    for (class_decl.primary_constructor, 0..) |prop, i| {
        new_props[i] = prop;
        new_props[i].type_ref = try self.cloneTypeRef(prop.type_ref);
    }
    
    var new_methods = try self.allocator.alloc(*ASTNode, class_decl.methods.len);
    for (class_decl.methods, 0..) |method, i| {
        const new_method = try self.allocator.create(ASTNode);
        new_method.* = method.*;
        if (method.data == .fun_decl) {
            var m_decl = method.data.fun_decl;
            if (m_decl.type_ref) |tr| {
                m_decl.type_ref = try self.cloneTypeRef(tr);
            }
            if (m_decl.params.len > 0) {
                var new_params = try self.allocator.alloc(ast.Param, m_decl.params.len);
                for (m_decl.params, 0..) |p, j| {
                    new_params[j] = p;
                    if (p.type_ref) |ptr| {
                        new_params[j].type_ref = try self.cloneTypeRef(ptr);
                    }
                }
                m_decl.params = new_params;
            }
            m_decl.body = try self.cloneNode(m_decl.body);
            new_method.data = .{ .fun_decl = m_decl };
        }
        new_methods[i] = new_method;
    }
    var new_class_decl = class_decl;
    new_class_decl.primary_constructor = new_props;
    new_class_decl.methods = new_methods;
    new_class_decl.name = mangled_name;
    new_class_decl.resolved_c_name = mangled_name;
    new_class_decl.generic_params = &.{};
    new_node.data = .{ .class_decl = new_class_decl };
    
    // Register and trigger deep inference on the monomorphized class!
    const class_type = try self.allocator.create(AetherType);
    try infer_decl_mod.inferClassDecl(self, new_node, &self.global_scope, class_type);
    
    for (class_decl.generic_params) |param_name| {
        if (old_aliases.get(param_name)) |old_val| {
            try self.alias_map.put(param_name, old_val);
        } else {
            _ = self.alias_map.remove(param_name);
        }
    }

    try self.monomorphized_nodes.append(new_node);
}

fn core_cloneNode(self: *TypeChecker, node: *ASTNode) anyerror!*ASTNode {
    const new_node = try self.allocator.create(ASTNode);
    new_node.* = node.*;
    new_node.resolved_type = null;
    
    switch (node.data) {
        .block => |b| {
            var new_stmts = try self.allocator.alloc(*ASTNode, b.statements.len);
            for (b.statements, 0..) |stmt, i| {
                new_stmts[i] = try self.cloneNode(stmt);
            }
            new_node.data = .{ .block = .{ .statements = new_stmts } };
        },
        .binary_expr => |b| {
            new_node.data = .{ .binary_expr = .{
                .left = try self.cloneNode(b.left),
                .op = b.op,
                .right = try self.cloneNode(b.right),
            }};
        },
        .call_expr => |c| {
            var new_args = try self.allocator.alloc(*ASTNode, c.arguments.len);
            for (c.arguments, 0..) |arg, i| {
                new_args[i] = try self.cloneNode(arg);
            }
            new_node.data = .{ .call_expr = .{
                .callee = try self.cloneNode(c.callee),
                .arguments = new_args,
            }};
        },
        .get_expr => |g| {
            new_node.data = .{ .get_expr = .{
                .object = try self.cloneNode(g.object),
                .name = g.name,
                .is_safe = g.is_safe,
            }};
        },
        .return_stmt => |r| {
            var val: ?*ASTNode = null;
            if (r.value) |v| val = try self.cloneNode(v);
            new_node.data = .{ .return_stmt = .{ .value = val } };
        },
        .var_decl => |v| {
            var val: ?*ASTNode = null;
            if (v.initializer) |init| val = try self.cloneNode(init);
            const ref = if (v.type_ref) |tr| try self.cloneTypeRef(tr) else null;
            new_node.data = .{ .var_decl = .{
                .is_mut = v.is_mut,
                .name = v.name,
                .type_ref = ref,
                .initializer = val,
            }};
        },
        .set_expr => |s| {
            new_node.data = .{ .set_expr = .{
                .object = try self.cloneNode(s.object),
                .name = s.name,
                .value = try self.cloneNode(s.value),
                .is_safe = s.is_safe,
            }};
        },
        .if_expr => |i| {
            var el: ?*ASTNode = null;
            if (i.else_branch) |e| el = try self.cloneNode(e);
            new_node.data = .{ .if_expr = .{
                .condition = try self.cloneNode(i.condition),
                .then_branch = try self.cloneNode(i.then_branch),
                .else_branch = el,
            }};
        },
        .while_stmt => |w| {
            new_node.data = .{ .while_stmt = .{
                .condition = try self.cloneNode(w.condition),
                .body = try self.cloneNode(w.body),
            }};
        },
        .array_literal => |a| {
            var new_elems = try self.allocator.alloc(*ASTNode, a.elements.len);
            for (a.elements, 0..) |el, i| {
                new_elems[i] = try self.cloneNode(el);
            }
            new_node.data = .{ .array_literal = .{ .elements = new_elems } };
        },

        .unary_expr => |u| {
            new_node.data = .{ .unary_expr = .{
                .operator = u.operator,
                .operand = try self.cloneNode(u.operand),
            }};
        },
        .assignment => |a| {
            new_node.data = .{ .assignment = .{
                .name = a.name,
                .value = try self.cloneNode(a.value),
            }};
        },
        .index_expr => |i| {
            new_node.data = .{ .index_expr = .{
                .object = try self.cloneNode(i.object),
                .index = try self.cloneNode(i.index),
            }};
        },
        .index_set_expr => |i| {
            new_node.data = .{ .index_set_expr = .{
                .object = try self.cloneNode(i.object),
                .index = try self.cloneNode(i.index),
                .value = try self.cloneNode(i.value),
            }};
        },
        .for_stmt => |f| {
            new_node.data = .{ .for_stmt = .{
                .item_name = f.item_name,
                .iterable = try self.cloneNode(f.iterable),
                .body = try self.cloneNode(f.body),
            }};
        },
        .ternary_expr => |t| {
            var el: ?*ASTNode = null;
            if (t.else_branch) |e| el = try self.cloneNode(e);
            new_node.data = .{ .ternary_expr = .{
                .condition = try self.cloneNode(t.condition),
                .then_branch = try self.cloneNode(t.then_branch),
                .else_branch = el,
            }};
        },
        .as_expr => |a| {
            new_node.data = .{ .as_expr = .{
                .value = try self.cloneNode(a.value),
                .type_ref = try self.cloneTypeRef(a.type_ref),
            }};
        },
        .is_expr => |i| {
            new_node.data = .{ .is_expr = .{
                .value = try self.cloneNode(i.value),
                .type_ref = try self.cloneTypeRef(i.type_ref),
                .is_not = i.is_not,
            }};
        },
        else => {}, // For identifiers and literals, shallow copy is fine as long as we cleared resolved_type
    }
    
    return new_node;
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
            else => return true,
        }
    }
    return false;
}

