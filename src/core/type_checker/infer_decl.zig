const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../../frontend/parser/core.zig");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;
const isCompatible = core.isCompatible;

pub fn inferImportStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    _ = scope;
    var i = &node.data.import_stmt;
    const dir_path = std.fs.path.dirname(self.filename) orelse ".";
    var actual_module_path: []const u8 = i.module_path;
    if (!std.mem.endsWith(u8, actual_module_path, ".ae")) {
        actual_module_path = try std.fmt.allocPrint(self.allocator, "{s}.ae", .{actual_module_path});
    }
    const mod_path = try std.fs.path.join(self.allocator, &.{ dir_path, actual_module_path });
    const mod_source = std.fs.cwd().readFileAlloc(self.allocator, mod_path, 1024 * 1024) catch |err| {
        self.reportError(node.line, node.column, "ImportError: Failed to read module file '{s}': {}", .{ mod_path, err });
        return error.ImportError;
    };

    var p = parser_mod.Parser.init(self.allocator, mod_source);
    const mod_ast = try p.parse();
    i.module_ast = mod_ast;

    const basename = std.fs.path.basename(mod_path);
    const ext_idx = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
    const prefix = basename[0..ext_idx];

    var tc = TypeChecker.init(self.allocator, mod_source, mod_path);
    tc.module_prefix = prefix;
    tc.is_test_mode = self.is_test_mode;
    try tc.validate(mod_ast);
    tc.deinit();

    for (i.destructured) |sym| {
        var found = false;
        for (mod_ast.data.program.statements) |stmt| {
            if (stmt.data == .fun_decl) {
                if (std.mem.eql(u8, stmt.data.fun_decl.name, sym)) {
                    try self.alias_map.put(sym, stmt.data.fun_decl.resolved_c_name.?);
                    found = true;
                    break;
                }
            } else if (stmt.data == .class_decl) {
                if (std.mem.eql(u8, stmt.data.class_decl.name, sym)) {
                    try self.alias_map.put(sym, stmt.data.class_decl.resolved_c_name.?);
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            self.reportError(node.line, node.column, "ImportError: Symbol '{s}' not found in module '{s}'.", .{ sym, mod_path });
            return error.ImportError;
        }
    }

    t.* = .Void;
}

pub fn inferClassDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var c = &node.data.class_decl;
    if (self.module_prefix) |prefix| {
        c.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, c.name });
        try self.alias_map.put(c.name, c.resolved_c_name.?);
    } else {
        c.resolved_c_name = c.name;
    }
    const actual_c_name = c.resolved_c_name.?;
    const class_type = try self.allocator.create(AetherType);
    class_type.* = .{ .Custom = actual_c_name };
    try scope.define(c.name, class_type);
    try scope.define(actual_c_name, class_type);

    var class_scope = Scope.init(self.allocator, scope);
    defer class_scope.deinit();
    try class_scope.define("self", class_type);

    var class_props = std.StringHashMap(void).init(self.allocator);
    defer class_props.deinit();
    const old_props = self.current_class_props;
    self.current_class_props = &class_props;
    defer self.current_class_props = old_props;

    for (c.primary_constructor) |*prop| {
        if (self.alias_map.get(prop.type_name)) |aliased| {
            prop.type_name = aliased;
        }
        try class_props.put(prop.name, {});
        
        const param_type = try self.resolveTypeName(prop.type_name, false);
        try class_scope.define(prop.name, param_type);
    }

    // Methods
    for (c.methods) |method| {
        if (method.data == .fun_decl) {
            const m_name = method.data.fun_decl.name;
            const is_operator = std.mem.eql(u8, m_name, "plus") or
                std.mem.eql(u8, m_name, "minus") or
                std.mem.eql(u8, m_name, "star") or
                std.mem.eql(u8, m_name, "slash");
            if (is_operator) {
                var has_operator_mod = false;
                for (method.data.fun_decl.modifiers) |mod| {
                    if (mod == .kw_operator) {
                        has_operator_mod = true;
                        break;
                    }
                }
                if (!has_operator_mod) {
                    self.reportError(method.line, method.column, "TypeError: Method '{s}' must be marked with the 'operator' modifier.", .{m_name});
                    return error.TypeError;
                }
            }
        }
        _ = try self.inferNode(method, &class_scope);
    }
    t.* = .Void;
}

pub fn inferFunDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var f = &node.data.fun_decl;
    if (self.module_prefix) |prefix| {
        if (std.mem.eql(u8, f.name, "main")) {
            f.resolved_c_name = "main";
        } else {
            f.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, f.name });
            try self.alias_map.put(f.name, f.resolved_c_name.?);
        }
    } else {
        f.resolved_c_name = f.name;
    }
    var fun_scope = Scope.init(self.allocator, scope);
    defer fun_scope.deinit();

    if (f.type_name) |tn| {
        if (self.alias_map.get(tn)) |aliased| {
            f.type_name = aliased;
        }
    }

    for (f.params) |*p| {
        var param_type: *AetherType = undefined;
        if (p.type_name) |tn| {
            if (self.alias_map.get(tn)) |aliased| {
                p.type_name = aliased;
            }
            param_type = try self.resolveTypeName(p.type_name.?, p.type_is_nullable);
        } else {
            param_type = try self.allocator.create(AetherType);
            param_type.* = .Void;
        }
        try fun_scope.define(p.name, param_type);
    }

    _ = try self.inferNode(f.body, &fun_scope);
    t.* = .Void;
}

pub fn inferVarDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var v = &node.data.var_decl;
    var inferred: ?*const AetherType = null;
    if (v.initializer) |init_node| {
        inferred = try self.inferNode(init_node, scope);
    }

    var declared: ?*const AetherType = null;
    if (v.type_name) |tn| {
        if (self.alias_map.get(tn)) |aliased| {
            v.type_name = aliased;
        }
        declared = try self.resolveTypeName(v.type_name.?, v.type_is_nullable);
    }

    if (declared != null and inferred != null) {
        if (!isCompatible(declared.?, inferred.?)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for variable '{s}'.", .{ declared.?.*, inferred.?.*, v.name });
            return error.TypeError;
        }
    }

    const final_type = declared orelse (inferred orelse blk: {
        const void_t = try self.allocator.create(AetherType);
        void_t.* = .Void;
        break :blk void_t;
    });
    try scope.define(v.name, final_type);
    t.* = .Void;
}
