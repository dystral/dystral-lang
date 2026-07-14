const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../../frontend/parser/core.zig");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;

const std_modules = std.StaticStringMap([]const u8).initComptime(.{
    .{ "core.ae", @embedFile("../../std/core.ae") },
    .{ "time.ae", @embedFile("../../std/time.ae") },
    .{ "math.ae", @embedFile("../../std/math.ae") },
    .{ "fs.ae", @embedFile("../../std/fs.ae") },
    .{ "collections.ae", @embedFile("../../std/collections.ae") },
    .{ "net.ae", @embedFile("../../std/net.ae") },
    .{ "http.ae", @embedFile("../../std/http.ae") },
});

pub fn inferImportStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    _ = scope;
    var i = &node.data.import_stmt;
    const dir_path = std.fs.path.dirname(self.filename) orelse ".";
    var actual_module_path: []const u8 = i.module_path;
    if (!std.mem.endsWith(u8, actual_module_path, ".ae")) {
        actual_module_path = try std.fmt.allocPrint(self.allocator, "{s}.ae", .{actual_module_path});
    }
    var mod_path: []const u8 = undefined;
    var mod_source: []const u8 = undefined;
    
    if (std.mem.startsWith(u8, actual_module_path, "std.")) {
        const pkg_name = actual_module_path[4..];
        mod_path = try std.fmt.allocPrint(self.allocator, "std/{s}", .{pkg_name});
        
        if (std_modules.get(pkg_name)) |source| {
            mod_source = source;
        } else {
            self.reportError(node.line, node.column, "ImportError: Unknown standard library package 'std.{s}'", .{pkg_name});
            return error.ImportError;
        }
    } else {
        mod_path = try std.fs.path.join(self.allocator, &.{ dir_path, actual_module_path });
        mod_source = std.fs.cwd().readFileAlloc(self.allocator, mod_path, 1024 * 1024) catch |err| {
            self.reportError(node.line, node.column, "ImportError: Failed to read module file '{s}': {}", .{ mod_path, err });
            return error.ImportError;
        };
    }

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
    
    if (i.destructured.len == 0) {
        var it = tc.global_scope.symbols.iterator();
        while (it.next()) |entry| {
            try self.global_scope.symbols.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var alias_it = tc.alias_map.iterator();
        while (alias_it.next()) |entry| {
            try self.alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var class_ast_it = tc.classes_ast.iterator();
        while (class_ast_it.next()) |entry| {
            try self.classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    } else {
        for (i.destructured) |sym| {
            var found = false;
            
            if (tc.alias_map.get(sym)) |aliased_name| {
                try self.alias_map.put(sym, aliased_name);
            } else {
                const aliased_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, sym });
                try self.alias_map.put(sym, aliased_name);
            }
            
            if (tc.global_scope.lookupFunctions(sym)) |overloads| {
                for (overloads) |overload| {
                    try self.global_scope.define(sym, overload, false);
                }
                found = true;
            } else if (tc.global_scope.lookupVariable(sym)) |variable| {
                try self.global_scope.define(sym, variable, false);
                found = true;
            }
            
            if (!found) {
                for (mod_ast.data.program.statements) |stmt| {
                    if (stmt.data == .class_decl) {
                        if (std.mem.eql(u8, stmt.data.class_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    } else if (stmt.data == .lib_decl) {
                        if (std.mem.eql(u8, stmt.data.lib_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    }
                }
            }
            
            if (!found) {
                self.reportError(node.line, node.column, "ImportError: Symbol '{s}' not found in module '{s}'.", .{ sym, mod_path });
                return error.ImportError;
            }
        }
        
        var class_ast_it = tc.classes_ast.iterator();
        while (class_ast_it.next()) |entry| {
            try self.classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        // Also register generic template symbols so that method bodies referencing
        // sibling classes (e.g. List.mut() returns MutableList) can resolve them.
        var alias_it2 = tc.alias_map.iterator();
        while (alias_it2.next()) |entry| {
            if (!self.alias_map.contains(entry.key_ptr.*)) {
                try self.alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        var sym_it = tc.global_scope.symbols.iterator();
        while (sym_it.next()) |entry| {
            if (!self.global_scope.symbols.contains(entry.key_ptr.*)) {
                try self.global_scope.symbols.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }
    
    tc.deinit();

    t.* = .Void;
}

pub fn inferClassDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var c = &node.data.class_decl;
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
    try scope.define(c.name, class_type, false);
    if (!std.mem.eql(u8, c.name, actual_c_name)) {
        try scope.define(actual_c_name, class_type, false);
    }
    
    try self.classes_ast.put(actual_c_name, node);
    
    // Generic Templates are not deeply inferred nor compiled directly.
    // They wait to be monomorphized when instantiated.
    if (c.generic_params.len > 0) {
        t.* = .Void;
        return;
    }

    var class_scope = Scope.init(self.allocator, scope);
    defer class_scope.deinit();
    try class_scope.define("this", class_type, false);

    var class_props = std.StringHashMap(void).init(self.allocator);
    defer class_props.deinit();
    const old_props = self.current_class_props;
    self.current_class_props = &class_props;
    defer self.current_class_props = old_props;

    if (c.superclass_name) |super_name| {
        const parent_c_name = self.alias_map.get(super_name) orelse super_name;
        c.superclass_name = parent_c_name; // Store fully resolved mangled C name to avoid transpiler collision
        const parent_node = self.classes_ast.get(parent_c_name);
        if (parent_node == null) {
            self.reportError(node.line, node.column, "TypeError: Superclass '{s}' not found.", .{super_name});
            return error.TypeError;
        }
        const p_decl = parent_node.?.data.class_decl;
        if (!p_decl.is_open) {
            self.reportError(node.line, node.column, "TypeError: Class '{s}' is final and cannot be inherited.", .{super_name});
            return error.TypeError;
        }
        
        // Validate superclass constructor arguments
        if (c.superclass_args.len != p_decl.primary_constructor.len) {
            self.reportError(node.line, node.column, "TypeError: Expected {} arguments for superclass constructor of '{s}', got {}.", .{ p_decl.primary_constructor.len, super_name, c.superclass_args.len });
            return error.TypeError;
        }
        
        var constr_scope = Scope.init(self.allocator, scope);
        defer constr_scope.deinit();
        for (c.primary_constructor) |prop| {
            const p_t = try self.resolveTypeRef(prop.type_ref);
            try constr_scope.define(prop.name, p_t, prop.is_mut);
        }
        
        for (c.superclass_args, 0..) |arg, i| {
            const arg_type = try self.inferNode(arg, &constr_scope);
            const expected_type = try self.resolveTypeRef(p_decl.primary_constructor[i].type_ref);
            if (!self.isCompatible(expected_type, arg_type)) {
                self.reportError(arg.line, arg.column, "TypeError: Expected {} for argument {} of superclass constructor, got {}.", .{ expected_type.*, i + 1, arg_type.* });
                return error.TypeError;
            }
        }
        
        // Populate inherited properties and methods into class_scope & class_props
        var curr_super: ?[]const u8 = parent_c_name;
        while (curr_super) |s_name| {
            const actual_s_name = self.alias_map.get(s_name) orelse s_name;
            const s_node = self.classes_ast.get(actual_s_name) orelse break;
            const s_decl = s_node.data.class_decl;
            
            for (s_decl.primary_constructor) |prop| {
                if (!class_props.contains(prop.name)) {
                    try class_props.put(prop.name, {});
                    const p_type = try self.resolveTypeRef(prop.type_ref);
                    try class_scope.define(prop.name, p_type, prop.is_mut);
                }
            }
            
            for (s_decl.methods) |method| {
                if (method.data == .fun_decl) {
                    const m_decl = method.data.fun_decl;
                    var param_types = std.ArrayList(*const AetherType).init(self.allocator);
                    for (m_decl.params) |p| {
                        const p_t = if (p.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
                        try param_types.append(p_t);
                    }
                    const ret_t = if (m_decl.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
                    const fn_type = try self.allocator.create(AetherType);
                    fn_type.* = .{ .Function = .{
                        .params = try param_types.toOwnedSlice(),
                        .return_type = ret_t,
                        .c_name = m_decl.resolved_c_name orelse m_decl.name,
                    }};
                    
                    if (class_scope.symbols.get(m_decl.name) == null) {
                        try class_scope.define(m_decl.name, fn_type, false);
                    }
                }
            }
            
            curr_super = s_decl.superclass_name;
        }
    }

    for (c.primary_constructor) |*prop| {
        const param_type = try self.resolveTypeRef(prop.type_ref);
        prop.resolved_type = param_type;
        if (prop.is_property) {
            try class_props.put(prop.name, {});
            try class_scope.define(prop.name, param_type, prop.is_mut);
        }
    }

    // Methods
    if (c.generic_params.len == 0) {
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
    }
    t.* = .Void;
}

pub fn inferFunDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var f = &node.data.fun_decl;
    var param_types = std.ArrayList(*const AetherType).init(self.allocator);
    var mangled_name = std.ArrayList(u8).init(self.allocator);
    if (self.module_prefix) |prefix| {
        try mangled_name.writer().print("{s}_{s}", .{prefix, f.name});
    } else {
        try mangled_name.appendSlice(f.name);
    }

    var fun_scope = Scope.init(self.allocator, scope);
    defer fun_scope.deinit();

    for (f.params) |*p| {
        var param_type: *AetherType = undefined;
        if (p.type_ref) |tr| {
            param_type = try self.resolveTypeRef(tr);
            
            try mangled_name.appendSlice("_");
            try param_type.formatSafe(mangled_name.writer());
        } else {
            param_type = try self.allocator.create(AetherType);
            param_type.* = .Void;
            try mangled_name.appendSlice("_Void");
        }
        try fun_scope.define(p.name, param_type, false);
        try param_types.append(param_type);
    }
    
    if (std.mem.eql(u8, f.name, "main")) {
        f.resolved_c_name = "main";
    } else {
        f.resolved_c_name = try mangled_name.toOwnedSlice();
    }
    
    var return_type: *const AetherType = undefined;
    var body_inferred = false;
    
    if (f.type_ref) |tr| {
        return_type = try self.resolveTypeRef(tr);
    } else if (f.is_expr_body) {
        _ = try self.inferNode(f.body, &fun_scope);
        body_inferred = true;
        return_type = f.body.resolved_type.?;
    } else {
        const void_t = try self.allocator.create(AetherType);
        void_t.* = .Void;
        return_type = void_t;
    }
    
    const fn_type = try self.allocator.create(AetherType);
    fn_type.* = .{ .Function = .{
        .params = try param_types.toOwnedSlice(),
        .return_type = return_type,
        .c_name = f.resolved_c_name.?,
    } };
    
    try scope.define(f.name, fn_type, false);

    if (!body_inferred) {
        _ = try self.inferNode(f.body, &fun_scope);
    }
    
    if (f.is_expr_body) {
        if (!self.isCompatible(return_type, f.body.resolved_type.?)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} in expression body.", .{return_type.*, f.body.resolved_type.?.*});
            return error.TypeError;
        }
    }
    t.* = fn_type.*;
}

pub fn inferVarDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const v = &node.data.var_decl;
    var inferred: ?*const AetherType = null;
    if (v.initializer) |init_node| {
        inferred = try self.inferNode(init_node, scope);
    }

    var declared: ?*const AetherType = null;
    if (v.type_ref) |tr| {
        declared = try self.resolveTypeRef(tr);
    }

    if (declared != null and inferred != null) {
        if (!self.isCompatible(declared.?, inferred.?)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for variable '{s}'.", .{ declared.?.*, inferred.?.*, v.name });
            return error.TypeError;
        }
    }

    const final_type = declared orelse (inferred orelse blk: {
        const void_t = try self.allocator.create(AetherType);
        void_t.* = .Void;
        break :blk void_t;
    });
    try scope.define(v.name, final_type, v.is_mut);
    node.resolved_type = final_type;
    t.* = .Void;
}

pub fn inferLibDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const l = &node.data.lib_decl;
    const lib_type = try self.allocator.create(AetherType);
    lib_type.* = .{ .Custom = l.name };
    try scope.define(l.name, lib_type, false);

    for (l.functions) |func| {
        const f = &func.data.fun_decl;
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ l.name, f.name });
        
        var ret_type: *AetherType = undefined;
        if (f.type_ref) |tr| {
            ret_type = try self.resolveTypeRef(tr);
        } else {
            ret_type = try self.allocator.create(AetherType);
            ret_type.* = .Void;
        }
        var c_name = f.name;
        for (f.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "Alias")) {
                if (ann.arguments.len > 0) {
                    c_name = ann.arguments[0];
                }
            }
        }
        try scope.define(full_name, ret_type, false);
        try self.alias_map.put(full_name, c_name);
    }
    t.* = .Void;
}
