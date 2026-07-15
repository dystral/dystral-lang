const std = @import("std");
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser/core.zig");
const c_transpiler = @import("backend/c_transpiler/core.zig");
const ast = @import("core/ast.zig");


/// Main entry point for the Aether CLI.
/// Orchestrates the pipeline: Source -> Lexer -> Parser -> AST -> C Transpiler -> Binary.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("Memory leak detected in compiler general purpose allocator!\n", .{});
        }
    }
    
    var global_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer global_arena.deinit();
    const allocator = global_arena.allocator();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 2 or (!std.mem.eql(u8, args[1], "run") and !std.mem.eql(u8, args[1], "build") and !std.mem.eql(u8, args[1], "test"))) {
        std.debug.print("Usage: aether <run|build|test> [file.ae]\n", .{});
        return;
    }
    const is_build = std.mem.eql(u8, args[1], "build");
    const is_test = std.mem.eql(u8, args[1], "test");

    var source_alloc = std.ArrayList(u8).init(allocator);
    defer source_alloc.deinit();

    var filename: []const u8 = "synthetic_test.ae";

    if (is_test) {
        var search_path: []const u8 = ".";
        if (args.len > 2) {
            search_path = args[2];
        }
        var dir = try std.fs.cwd().openDir(search_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.basename, "_test.ae")) {
                    const full_import_path = try std.fs.path.join(allocator, &.{ search_path, entry.path });
                    defer allocator.free(full_import_path);
                    try source_alloc.writer().print("import {{}} from \"{s}\"\n", .{full_import_path});
                }
            }
        }
        if (source_alloc.items.len == 0) {
            std.debug.print("No tests found.\n", .{});
            return;
        }
    } else {
        if (args.len < 3) {
            std.debug.print("Error: Missing file argument.\n", .{});
            return;
        }
        filename = args[2];
        if (!std.mem.endsWith(u8, filename, ".ae")) {
            std.debug.print("Error: Unsupported file extension. Please use .ae files.\n", .{});
            return;
        }
        const file_content = try std.fs.cwd().readFileAlloc(allocator, filename, 1024 * 1024);
        defer allocator.free(file_content);
        try source_alloc.appendSlice(file_content);
    }
    const source = source_alloc.items;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var registry = @import("core/type_checker/core.zig").ModuleRegistry.init(arena.allocator());
    defer registry.deinit();

    var queue = std.ArrayList([]const u8).init(arena.allocator());
    defer queue.deinit();

    const std_modules = @import("core/type_checker/infer_decl.zig").std_modules;

    const resolved_entry_path = try std.fs.path.relative(arena.allocator(), ".", filename);
    try queue.append(resolved_entry_path);

    var queue_idx: usize = 0;
    var ast_root: *ast.ASTNode = undefined;
    while (queue_idx < queue.items.len) : (queue_idx += 1) {
        const cur_path = queue.items[queue_idx];
        if (registry.modules.contains(cur_path)) continue;

        var source_content: []const u8 = undefined;
        var is_std = false;

        if (std.mem.startsWith(u8, cur_path, "std/")) {
            const pkg_name = cur_path[4..];
            if (std_modules.get(pkg_name)) |src| {
                source_content = src;
                is_std = true;
            } else {
                std.debug.print("Error: Unknown standard library package 'std.{s}'\n", .{pkg_name});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, cur_path, "synthetic_test.ae")) {
            source_content = source;
        } else {
            source_content = std.fs.cwd().readFileAlloc(arena.allocator(), cur_path, 1024 * 1024) catch |err| {
                std.debug.print("Error: Failed to read module file '{s}': {}\n", .{ cur_path, err });
                std.process.exit(1);
            };
        }

        var p = parser.Parser.init(arena.allocator(), source_content);
        const ast_root_mod = p.parse() catch |err| {
            std.debug.print("Failed to parse module '{s}'. Error: {}\n", .{ cur_path, err });
            std.process.exit(1);
        };
        if (p.had_error) {
            std.process.exit(1);
        }

        if (queue_idx == 0) {
            ast_root = ast_root_mod;
        }

        const basename = std.fs.path.basename(cur_path);
        const ext_idx = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
        const prefix = basename[0..ext_idx];

        var checker = try arena.allocator().create(@import("core/type_checker/core.zig").TypeChecker);
        checker.* = @import("core/type_checker/core.zig").TypeChecker.init(arena.allocator(), source_content, cur_path);
        checker.module_prefix = if (queue_idx == 0) null else prefix;
        checker.is_test_mode = is_test;
        checker.registry = &registry;

        try checker.injectImplicitImports(ast_root_mod);

        try registry.modules.put(try arena.allocator().dupe(u8, cur_path), .{
            .filename = try arena.allocator().dupe(u8, cur_path),
            .source = source_content,
            .ast_root = ast_root_mod,
            .checker = checker,
            .module_prefix = if (queue_idx == 0) "" else prefix,
        });
        try registry.ordered_modules.append(try arena.allocator().dupe(u8, cur_path));

        // Scan for imports
        if (ast_root_mod.data == .program) {
            const dir_path = std.fs.path.dirname(cur_path) orelse ".";
            for (ast_root_mod.data.program.statements) |stmt| {
                if (stmt.data == .import_stmt) {
                    const i = &stmt.data.import_stmt;
                    var actual_module_path = i.module_path;
                    if (!std.mem.endsWith(u8, actual_module_path, ".ae")) {
                        actual_module_path = try std.fmt.allocPrint(arena.allocator(), "{s}.ae", .{actual_module_path});
                    }
                    var import_resolved_path: []const u8 = undefined;
                    if (std.mem.startsWith(u8, actual_module_path, "std.")) {
                        const pkg_name = actual_module_path[4..];
                        import_resolved_path = try std.fmt.allocPrint(arena.allocator(), "std/{s}", .{pkg_name});
                    } else {
                        import_resolved_path = try std.fs.path.join(arena.allocator(), &.{ dir_path, actual_module_path });
                    }
                    try queue.append(import_resolved_path);
                }
            }
        }
    }

    // Pass 2a: Declare Class and Object Types
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        try mod.checker.declareTypes(mod.ast_root);
    }

    // Pass 2b: Declare Signatures (constructors, methods, functions, libraries)
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        try mod.checker.declareSignatures(mod.ast_root);
    }

    // Pass 2c: Resolve Imports (link/copy symbols between modules)
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        try mod.checker.resolveImports(mod.ast_root);
    }

    // Pass 3: Validate Bodies
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        mod.checker.validate(mod.ast_root) catch {
            std.process.exit(1);
        };
    }

    // Consolidate classes, objects, and aliases for the CTranspiler
    var global_classes_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    var global_objects_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    var global_alias_map = std.StringHashMap([]const u8).init(arena.allocator());

    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        var class_it = mod.checker.classes_ast.iterator();
        while (class_it.next()) |entry| {
            try global_classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var object_it = mod.checker.objects_ast.iterator();
        while (object_it.next()) |entry| {
            try global_objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var alias_it = mod.checker.alias_map.iterator();
        while (alias_it.next()) |entry| {
            try global_alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    var transpiler = c_transpiler.CTranspiler.init(allocator);
    transpiler.is_test_mode = is_test;
    transpiler.classes_ast = &global_classes_ast;
    transpiler.objects_ast = &global_objects_ast;
    transpiler.alias_map = &global_alias_map;
    transpiler.source_file = filename; // used for #line directives in C output
    defer transpiler.deinit();

    const c_code = try transpiler.transpile(ast_root);
    defer allocator.free(c_code);

    const out_c_filename = "temp_out.c";
    try std.fs.cwd().writeFile(.{ .sub_path = out_c_filename, .data = c_code });
    // defer std.fs.cwd().deleteFile(out_c_filename) catch {};

    // Invoke zig cc
    const basename = std.fs.path.basename(filename);
    const ext = std.fs.path.extension(basename);
    const out_bin_name = basename[0 .. basename.len - ext.len];
    const final_bin = if (is_test) "test_runner" else if (out_bin_name.len > 0) out_bin_name else "a.out";

    const actual_zig = "zig";

    var cc_argv = std.ArrayList([]const u8).init(allocator);
    try cc_argv.appendSlice(&[_][]const u8{ actual_zig, "cc", "-O0", "-fwrapv", "-fno-sanitize=undefined", out_c_filename, "-lgc" });

    var lib_it = transpiler.link_libraries.keyIterator();
    while (lib_it.next()) |lib_name| {
        const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib_name.*});
        try cc_argv.append(flag);
        
        const macro = try std.fmt.allocPrint(allocator, "-DAETHER_USE_{s}", .{lib_name.*});
        for (macro) |*c| {
            c.* = std.ascii.toUpper(c.*);
        }
        try cc_argv.append(macro);
    }

    try cc_argv.appendSlice(&[_][]const u8{ "-o", final_bin });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = cc_argv.items,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term != .Exited or result.term.Exited != 0) {
        // Filter C stderr: show only semantic errors, hide internal C details.
        // With #line directives in the generated C, clang now reports errors as:
        //   person.ae:2:172: error: ...
        // instead of temp_out.c:NNN:COL: error: ...
        var found_error = false;
        var lines = std.mem.splitScalar(u8, result.stderr, '\n');
        while (lines.next()) |line| {
            // Only process lines that contain 'error:'
            if (std.mem.indexOf(u8, line, "error:") == null) continue;
            if (std.mem.indexOf(u8, line, "too many errors") != null) continue;

            if (std.mem.indexOf(u8, line, "temp_out.c:")) |_| {
                // Fallback: error on a C-internal line (outside #line'd regions)
                if (std.mem.indexOf(u8, line, "error: ")) |err_pos| {
                    const raw_msg = line[err_pos + 7..];
                    const msg = translateCError(raw_msg);
                    if (!found_error) {
                        std.debug.print("\nCompilation error:\n", .{});
                        found_error = true;
                    }
                    std.debug.print("  → {s}\n", .{msg});
                }
            } else if (std.mem.indexOf(u8, line, ".ae:")) |ae_pos| {
                // Error mapped back to an Aether source file via #line directive
                // Format: path/to/file.ae:LINE:COL: error: MESSAGE
                const location_part = line[0..ae_pos + 3]; // e.g. "../../samples/person.ae"
                // Extract just the basename for cleaner output
                const ae_basename = std.fs.path.basename(location_part);
                // Find line number after the .ae:
                const after_ae = line[ae_pos + 4..];
                var col_it = std.mem.splitScalar(u8, after_ae, ':');
                const line_num = col_it.next() orelse "?";
                // Find the error message
                if (std.mem.indexOf(u8, line, "error: ")) |err_pos| {
                    const raw_msg = line[err_pos + 7..];
                    const msg = translateCError(raw_msg);
                    if (!found_error) {
                        std.debug.print("\nCompilation error:\n", .{});
                        found_error = true;
                    }
                    std.debug.print("  → {s}:{s}: {s}\n", .{ae_basename, line_num, msg});
                }
            } else {
                // Non-file error (e.g. linker errors)
                if (!found_error) {
                    std.debug.print("\nCompilation error:\n", .{});
                    found_error = true;
                }
                std.debug.print("  → {s}\n", .{line});
            }
        }
        if (!found_error) {
            std.debug.print("\nCompilation error (internal):\n{s}\n", .{result.stderr});
        }
        std.process.exit(1);
    }

    if (!is_build) {
        // Execute final binary
        var exe_path_buf: [1024]u8 = undefined;
        const exe_path = try std.fmt.bufPrint(&exe_path_buf, "./{s}", .{final_bin});
        
        var child = std.process.Child.init(&[_][]const u8{ exe_path }, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        
        try child.spawn();
        const term = try child.wait();
        
        // Clean up binary after running
        // std.fs.cwd().deleteFile(final_bin) catch {};

        if (term == .Exited and term.Exited != 0) {
            std.process.exit(term.Exited);
        } else if (term == .Signal) {
            std.debug.print("Error: Test runner crashed with signal {d}\n", .{term.Signal});
            std.process.exit(1);
        }
    } else {
        std.debug.print("Successfully built {s}\n", .{final_bin});
    }
}

test "imports" {
    _ = @import("core/ast.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser/core.zig");
    _ = @import("backend/c_transpiler/core.zig");
}

/// Translate low-level C compiler error messages into user-friendly Aether errors.
/// Hides internal details like mangled names and C-specific type nomenclature.
fn translateCError(msg: []const u8) []const u8 {
    // Int passed where String is expected (e.g. string concatenation without .toString())
    if (std.mem.indexOf(u8, msg, "incompatible integer to pointer") != null and
        std.mem.indexOf(u8, msg, "core_String") != null)
    {
        return "Type error: cannot use an Int value where a String is expected. Did you forget .toString()?";
    }
    // Null dereference / incomplete type
    if (std.mem.indexOf(u8, msg, "incomplete definition of type") != null) {
        return "Type error: attempted to use an undefined type. Check your imports.";
    }
    // Undeclared identifier
    if (std.mem.indexOf(u8, msg, "use of undeclared identifier") != null) {
        return "Name error: reference to an undeclared symbol. Check your imports and variable names.";
    }
    // Generic incompatible pointer (type mismatch between structs)
    if (std.mem.indexOf(u8, msg, "incompatible pointer types") != null) {
        return "Type error: incompatible types in assignment or function call.";
    }
    // Linker errors
    if (std.mem.indexOf(u8, msg, "undefined reference") != null or
        std.mem.indexOf(u8, msg, "undefined symbol") != null)
    {
        return "Linker error: symbol not found. Ensure all required modules are imported.";
    }
    // Fallback: return the raw message (still better than the full C trace)
    return msg;
}
