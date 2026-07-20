const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../../frontend/parser/core.zig");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const AetherType = core.AetherType;

pub const std_modules = std.StaticStringMap([]const u8).initComptime(.{
    .{ "core.ae", @embedFile("../../std/core.ae") },
    .{ "time.ae", @embedFile("../../std/time.ae") },
    .{ "math.ae", @embedFile("../../std/math.ae") },
    .{ "fs.ae", @embedFile("../../std/fs.ae") },
    .{ "collections.ae", @embedFile("../../std/collections.ae") },
    .{ "net.ae", @embedFile("../../std/net.ae") },
    .{ "http.ae", @embedFile("../../std/http.ae") },
    .{ "env.ae", @embedFile("../../std/env.ae") },
});

pub fn inferImportStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    _ = scope;
    if (self.pass == .validation) {
        t.* = .Void;
        return;
    }

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
        if (self.registry == null) {
            mod_source = std.fs.cwd().readFileAlloc(self.allocator, mod_path, 1024 * 1024) catch |err| {
                self.reportError(node.line, node.column, "ImportError: Failed to read module file '{s}': {}", .{ mod_path, err });
                return error.ImportError;
            };
        }
    }

    var mod_ast: *ASTNode = undefined;
    var prefix: []const u8 = undefined;
    var tc_opt: ?*TypeChecker = null;
    var fallback_tc: TypeChecker = undefined;
    var has_fallback = false;

    if (self.registry) |reg| {
        if (reg.modules.get(mod_path)) |m| {
            mod_ast = m.ast_root;
            prefix = m.module_prefix;
            tc_opt = m.checker;
        } else {
            self.reportError(node.line, node.column, "ImportError: Module '{s}' not found in registry.", .{mod_path});
            return error.ImportError;
        }
    } else {
        var p = parser_mod.Parser.init(self.allocator, mod_source);
        mod_ast = try p.parse();

        const basename = std.fs.path.basename(mod_path);
        const ext_idx = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
        prefix = basename[0..ext_idx];

        fallback_tc = TypeChecker.init(self.allocator, mod_source, mod_path);
        fallback_tc.module_prefix = prefix;
        fallback_tc.is_test_mode = self.is_test_mode;
        try fallback_tc.validate(mod_ast);
        tc_opt = &fallback_tc;
        has_fallback = true;
    }
    i.module_ast = mod_ast;
    const tc = tc_opt.?;

    if (i.destructured.len == 0) {
        // Non-destructured imports only re-export symbols declared in the module
        // itself (ADR 26) — transitively imported symbols do not leak.
        var it = tc.global_scope.symbols.iterator();
        while (it.next()) |entry| {
            if (!tc.local_symbols.contains(entry.key_ptr.*)) continue;
            try self.global_scope.symbols.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var alias_it = tc.alias_map.iterator();
        while (alias_it.next()) |entry| {
            if (!tc.local_symbols.contains(entry.key_ptr.*)) continue;
            try self.alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var class_ast_it = tc.classes_ast.iterator();
        while (class_ast_it.next()) |entry| {
            try self.classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var contract_ast_it = tc.contracts_ast.iterator();
        while (contract_ast_it.next()) |entry| {
            try self.contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var skill_ast_it = tc.skills_ast.iterator();
        while (skill_ast_it.next()) |entry| {
            try self.skills_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var object_ast_it = tc.objects_ast.iterator();
        while (object_ast_it.next()) |entry| {
            try self.objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    } else {
        for (i.destructured) |sym| {
            var found = false;

            if (tc.alias_map.get(sym)) |aliased_name| {
                try self.alias_map.put(sym, aliased_name);
            } else if (prefix.len > 0) {
                const aliased_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, sym });
                try self.alias_map.put(sym, aliased_name);
            }

            if (tc.global_scope.lookupFunctions(sym)) |overloads| {
                for (overloads) |overload| {
                    try self.global_scope.define(sym, overload, false, true);
                }
                found = true;
            } else if (tc.global_scope.lookupVariable(sym)) |variable| {
                try self.global_scope.define(sym, variable, false, false);
                found = true;
            }

            if (!found) {
                for (mod_ast.data.program.statements) |stmt| {
                    if (stmt.data == .type_decl) {
                        if (std.mem.eql(u8, stmt.data.type_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    } else if (stmt.data == .contract_decl) {
                        if (std.mem.eql(u8, stmt.data.contract_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    } else if (stmt.data == .skill_decl) {
                        if (std.mem.eql(u8, stmt.data.skill_decl.name, sym)) {
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
        var contract_ast_it2 = tc.contracts_ast.iterator();
        while (contract_ast_it2.next()) |entry| {
            try self.contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var skill_ast_it2 = tc.skills_ast.iterator();
        while (skill_ast_it2.next()) |entry| {
            try self.skills_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var object_ast_it = tc.objects_ast.iterator();
        while (object_ast_it.next()) |entry| {
            try self.objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
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

    var fun_ast_it = tc.functions_ast.iterator();
    while (fun_ast_it.next()) |entry| {
        try self.functions_ast.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    if (has_fallback) {
        fallback_tc.deinit();
    }

    t.* = .Void;
}

pub fn inferTypeDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var c = &node.data.type_decl;
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
    try scope.define(c.name, class_type, false, false);
    if (!std.mem.eql(u8, c.name, actual_c_name)) {
        try scope.define(actual_c_name, class_type, false, false);
    }

    try self.classes_ast.put(actual_c_name, node);

    // Generic Templates are not deeply inferred nor compiled directly.
    // They wait to be monomorphized when instantiated.
    if (c.generic_params.len > 0) {
        t.* = .Void;
        return;
    }

    // Compose skills exactly once (mutates c.methods)
    if (!c.skills_composed) {
        c.skills_composed = true;
        try composeSkills(self, node, c);
    }

    var class_scope = Scope.init(self.allocator, scope);
    defer class_scope.deinit();
    try class_scope.define("this", class_type, false, false);

    var class_props = std.StringHashMap(void).init(self.allocator);
    defer class_props.deinit();
    const old_props = self.current_class_props;
    self.current_class_props = &class_props;
    defer self.current_class_props = old_props;

    const old_type_c_name = self.current_type_c_name;
    self.current_type_c_name = actual_c_name;
    defer self.current_type_c_name = old_type_c_name;

    for (c.primary_constructor) |*prop| {
        const param_type = try self.resolveTypeRef(prop.type_ref);
        prop.resolved_type = param_type;

        if (prop.initializer) |init_node| {
            if (self.pass == .validation) {
                const cloned_init = try self.cloneNode(init_node);
                cloned_init.expected_type = param_type;
                const init_type = try self.inferNode(cloned_init, scope);
                if (!self.isCompatible(param_type, init_type)) {
                    self.reportError(node.line, node.column, "TypeError: Default value type {} is incompatible with property type {}.", .{ init_type.*, param_type.* });
                    return error.TypeError;
                }
            }
        }

        if (prop.is_property) {
            try class_props.put(prop.name, {});
            try class_scope.define(prop.name, param_type, prop.is_mut, false);
        }
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

    // Contract conformance is validated after method inference so expression-body
    // implementations have their return types resolved.
    try validateContracts(self, node, c);
    t.* = .Void;
}

fn composeSkills(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    if (c.skills.len == 0) return;

    var final_methods = std.ArrayList(*ASTNode).init(self.allocator);
    var provided = std.StringHashMap([]const u8).init(self.allocator);

    for (c.methods) |m| {
        try final_methods.append(m);
        if (m.data == .fun_decl) {
            try provided.put(m.data.fun_decl.name, "");
        }
    }

    for (c.skills) |skill_src_name| {
        const skill_actual = self.alias_map.get(skill_src_name) orelse skill_src_name;
        const skill_node = self.skills_ast.get(skill_actual) orelse {
            self.reportError(node.line, node.column, "TypeError: Skill '{s}' not found.", .{skill_src_name});
            return error.TypeError;
        };
        const s = skill_node.data.skill_decl;

        // A type may compose a skill only if it implements every required contract.
        for (s.required_contracts) |req| {
            const req_actual = self.alias_map.get(req) orelse req;
            var found = false;
            for (c.contracts) |tc| {
                const tc_actual = self.alias_map.get(tc) orelse tc;
                if (std.mem.eql(u8, tc_actual, req_actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.reportError(node.line, node.column, "Skill '{s}' requires contract '{s}'.\nType '{s}' does not implement it.", .{ s.name, req, c.name });
                return error.TypeError;
            }
        }

        for (s.methods) |m| {
            if (m.data != .fun_decl) continue;
            const fname = m.data.fun_decl.name;
            if (provided.get(fname)) |other_skill| {
                if (other_skill.len == 0) {
                    // Type implements it explicitly — skill version stays available qualified.
                    const renamed = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ s.name, fname });
                    const cloned = try self.cloneNode(m);
                    @constCast(&cloned.data.fun_decl).name = renamed;
                    try final_methods.append(cloned);
                } else {
                    // Two skills provide the same member without an explicit resolution.
                    self.reportError(m.line, m.column, "TypeError: Ambiguous member '{s}' from skills '{s}' and '{s}'. Resolve it explicitly in type '{s}' with 'implement fun {s}'.", .{ fname, other_skill, s.name, c.name, fname });
                    return error.TypeError;
                }
            } else {
                try provided.put(fname, s.name);
                const cloned = try self.cloneNode(m);
                try final_methods.append(cloned);
            }
        }
    }

    c.methods = try final_methods.toOwnedSlice();
}

fn validateContracts(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    for (c.contracts) |contract_src_name| {
        const contract_actual = self.alias_map.get(contract_src_name) orelse contract_src_name;
        const contract_node = self.contracts_ast.get(contract_actual) orelse {
            self.reportError(node.line, node.column, "TypeError: Contract '{s}' not found.", .{contract_src_name});
            return error.TypeError;
        };
        const cd = contract_node.data.contract_decl;

        for (cd.methods) |cm| {
            if (cm.data != .fun_decl) continue;
            const cm_name = cm.data.fun_decl.name;

            var found: ?*ASTNode = null;
            var from_skill = false;
            for (c.methods) |m| {
                if (m.data != .fun_decl) continue;
                if (std.mem.eql(u8, m.data.fun_decl.name, cm_name)) {
                    found = m;
                    // Methods cloned from skills carry no 'implement' requirement.
                    for (c.skills) |skill_src| {
                        const skill_actual = self.alias_map.get(skill_src) orelse skill_src;
                        if (self.skills_ast.get(skill_actual)) |sn| {
                            for (sn.data.skill_decl.methods) |sm| {
                                if (sm.data == .fun_decl and std.mem.eql(u8, sm.data.fun_decl.name, cm_name)) {
                                    from_skill = true;
                                    break;
                                }
                            }
                        }
                    }
                    break;
                }
            }

            if (found == null) {
                self.reportError(node.line, node.column, "TypeError: Type '{s}' does not implement method '{s}' required by contract '{s}'.", .{ c.name, cm_name, cd.name });
                return error.TypeError;
            }

            const m = found.?;
            if (!from_skill) {
                var has_implement = false;
                for (m.data.fun_decl.modifiers) |mod| {
                    if (mod == .kw_implement) {
                        has_implement = true;
                        break;
                    }
                }
                if (!has_implement) {
                    self.reportError(m.line, m.column, "TypeError: Method '{s}' implements contract '{s}' and must be marked with 'implement'.", .{ cm_name, cd.name });
                    return error.TypeError;
                }
            }

            if (m.data.fun_decl.params.len != cm.data.fun_decl.params.len) {
                self.reportError(m.line, m.column, "TypeError: Method '{s}' does not match the signature of contract '{s}'.", .{ cm_name, cd.name });
                return error.TypeError;
            }

            // Return type compatibility (Void if omitted on either side)
            const contract_ret = if (cm.data.fun_decl.type_ref) |tr| try self.resolveTypeRef(tr) else blk: {
                const v = try self.allocator.create(AetherType);
                v.* = .Void;
                break :blk v;
            };
            const impl_ret = if (m.data.fun_decl.type_ref) |tr| try self.resolveTypeRef(tr) else blk: {
                if (m.data.fun_decl.is_expr_body) {
                    if (m.data.fun_decl.body.resolved_type) |bt| {
                        break :blk bt;
                    }
                    // Body not inferred yet — skip the check for now.
                    break :blk contract_ret;
                }
                const v = try self.allocator.create(AetherType);
                v.* = .Void;
                break :blk v;
            };
            if (!self.isCompatible(contract_ret, impl_ret)) {
                self.reportError(m.line, m.column, "TypeError: Method '{s}' returns {} but contract '{s}' requires {}.", .{ cm_name, impl_ret.*, cd.name, contract_ret.* });
                return error.TypeError;
            }
        }
    }
}

pub fn inferContractDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var cd = &node.data.contract_decl;
    if (cd.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            cd.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, cd.name });
            try self.alias_map.put(cd.name, cd.resolved_c_name.?);
        } else {
            cd.resolved_c_name = cd.name;
        }
    }
    const actual_c_name = cd.resolved_c_name.?;
    const contract_type = try self.allocator.create(AetherType);
    contract_type.* = .{ .Custom = actual_c_name };
    try scope.define(cd.name, contract_type, false, false);
    if (!std.mem.eql(u8, cd.name, actual_c_name)) {
        try scope.define(actual_c_name, contract_type, false, false);
    }
    try self.contracts_ast.put(actual_c_name, node);

    // Register method signatures only (contracts have no bodies to check).
    for (cd.methods) |method| {
        if (method.data != .fun_decl) continue;
        const m = &method.data.fun_decl;
        var param_types = std.ArrayList(*const AetherType).init(self.allocator);
        for (m.params) |p| {
            const p_t = if (p.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
            try param_types.append(p_t);
        }
        const ret_t = if (m.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
        m.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ actual_c_name, m.name });
        const fn_type = try self.allocator.create(AetherType);
        fn_type.* = .{ .Function = .{
            .params = try param_types.toOwnedSlice(),
            .return_type = ret_t,
            .c_name = m.resolved_c_name.?,
            .receiver = contract_type,
        } };
        method.resolved_type = fn_type;
    }
    t.* = .Void;
}

pub fn inferSkillDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    _ = scope;
    var sd = &node.data.skill_decl;
    if (sd.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            sd.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, sd.name });
            try self.alias_map.put(sd.name, sd.resolved_c_name.?);
        } else {
            sd.resolved_c_name = sd.name;
        }
    }
    try self.skills_ast.put(sd.resolved_c_name.?, node);
    // Skill bodies are type-checked at the composition site (per consuming type),
    // never standalone.
    t.* = .Void;
}

pub fn inferFunDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var f = &node.data.fun_decl;
    var param_types = std.ArrayList(*const AetherType).init(self.allocator);
    var mangled_name = std.ArrayList(u8).init(self.allocator);
    const is_method = scope.lookupVariable("this") != null;
    if (is_method) {
        const this_t = scope.lookupVariable("this").?;
        const base_t = core.extractBaseType(this_t);
        const class_name = if (base_t.* == .Custom) base_t.Custom else (if (base_t.* == .Pointer and base_t.Pointer.* == .Custom) base_t.Pointer.Custom else f.name);
        try mangled_name.writer().print("{s}_{s}", .{ class_name, f.name });
    } else if (self.current_class_name) |class_name| {
        const actual_class = self.alias_map.get(class_name) orelse class_name;
        try mangled_name.writer().print("{s}_{s}", .{ actual_class, f.name });
    } else if (self.module_prefix) |prefix| {
        try mangled_name.writer().print("{s}_{s}", .{ prefix, f.name });
    } else {
        try mangled_name.appendSlice(f.name);
    }

    var fun_scope = Scope.init(self.allocator, scope);
    fun_scope.is_function_boundary = true;
    defer fun_scope.deinit();

    for (f.params) |*p| {
        var param_type: *AetherType = undefined;
        if (p.type_ref) |tr| {
            param_type = try self.resolveTypeRef(tr);

            if (!is_method) {
                try mangled_name.appendSlice("_");
                try param_type.formatSafe(mangled_name.writer());
            }
        } else {
            param_type = try self.allocator.create(AetherType);
            param_type.* = .Void;
            if (!is_method) {
                try mangled_name.appendSlice("_Void");
            }
        }

        if (p.initializer) |init_node| {
            if (self.pass == .validation) {
                const cloned_init = try self.cloneNode(init_node);
                cloned_init.expected_type = param_type;
                const init_type = try self.inferNode(cloned_init, scope);
                if (!self.isCompatible(param_type, init_type)) {
                    self.reportError(node.line, node.column, "TypeError: Default value type {} is incompatible with parameter type {}.", .{ init_type.*, param_type.* });
                    return error.TypeError;
                }
            }
        }

        try fun_scope.define(p.name, param_type, false, false);
        try param_types.append(param_type);
    }

    if (std.mem.eql(u8, f.name, "main")) {
        f.resolved_c_name = "main";
    } else {
        f.resolved_c_name = try mangled_name.toOwnedSlice();
    }

    try self.functions_ast.put(f.resolved_c_name.?, node);
    if (!is_method and self.current_class_name == null) {
        try self.local_symbols.put(f.name, {});
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
        .receiver = if (is_method) scope.lookupVariable("this") else null,
    } };

    try scope.define(f.name, fn_type, false, true);

    if (self.pass == .declaration) {
        t.* = fn_type.*;
        return;
    }

    if (!body_inferred) {
        _ = try self.inferNode(f.body, &fun_scope);
    }

    if (f.is_expr_body) {
        if (!self.isCompatible(return_type, f.body.resolved_type.?)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} in expression body.", .{ return_type.*, f.body.resolved_type.?.* });
            return error.TypeError;
        }
    }
    t.* = fn_type.*;
}

pub fn inferVarDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const v = &node.data.var_decl;
    if (self.current_class_name) |class_name| {
        const actual_class = self.alias_map.get(class_name) orelse class_name;
        @constCast(v).resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ actual_class, v.name });
    }
    var declared: ?*const AetherType = null;
    if (v.type_ref) |tr| {
        declared = try self.resolveTypeRef(tr);
    }

    var inferred: ?*const AetherType = null;
    if (v.initializer) |init_node| {
        if (declared) |d| {
            init_node.expected_type = d;
        }
        inferred = try self.inferNode(init_node, scope);
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
    try scope.define(v.name, final_type, v.is_mut, false);
    if (scope.symbols.get(v.name)) |sym| {
        if (sym.* == .Variable) {
            sym.Variable.decl_node = node;
        }
    }
    node.resolved_type = final_type;
    t.* = .Void;
}

pub fn inferLibDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    const l = node.data.lib_decl;
    const lib_type = try self.allocator.create(AetherType);
    lib_type.* = .{ .Custom = l.name };
    try scope.define(l.name, lib_type, false, false);
    try self.local_symbols.put(l.name, {});

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
        try scope.define(full_name, ret_type, false, true);
        try self.alias_map.put(full_name, c_name);
        try self.local_symbols.put(full_name, {});
    }
    t.* = .Void;
}

pub fn inferObjectDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *AetherType) anyerror!void {
    var o = &node.data.object_decl;
    const name = o.name orelse {
        self.reportError(node.line, node.column, "TypeError: Companion object must have a resolved bound name.", .{});
        return error.TypeError;
    };

    if (o.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            o.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, name });
            try self.alias_map.put(name, o.resolved_c_name.?);
        } else {
            o.resolved_c_name = name;
        }
    }
    const actual_c_name = o.resolved_c_name.?;
    const obj_type = try self.allocator.create(AetherType);
    obj_type.* = .{ .Custom = actual_c_name };
    try scope.define(name, obj_type, false, false);
    if (!std.mem.eql(u8, name, actual_c_name)) {
        try scope.define(actual_c_name, obj_type, false, false);
    }

    try self.objects_ast.put(actual_c_name, node);

    // Set static block context
    const old_class_name = self.current_class_name;
    self.current_class_name = name;
    defer self.current_class_name = old_class_name;

    var obj_scope = Scope.init(self.allocator, scope);
    defer obj_scope.deinit();

    for (o.members) |member| {
        _ = try self.inferNode(member, &obj_scope);
    }
    t.* = .Void;
}
