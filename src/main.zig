const std = @import("std");
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser/core.zig");
const c_transpiler = @import("backend/c_transpiler/core.zig");

/// Main entry point for the Aether CLI.
/// Orchestrates the pipeline: Source -> Lexer -> Parser -> AST -> C Transpiler -> Binary.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    
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

    var p = parser.Parser.init(arena.allocator(), source);
    const ast_root = p.parse() catch |err| {
        std.debug.print("Failed to parse source file. Error: {}\n", .{err});
        return;
    };
    
    if (p.had_error) {
        return;
    }

    // Semantic Type Checking (Enforcement)
    var type_checker = @import("core/type_checker/core.zig").TypeChecker.init(arena.allocator(), source, filename);
    type_checker.is_test_mode = is_test;
    defer type_checker.deinit();
    type_checker.validate(ast_root) catch {
        std.debug.print("Compilation aborted due to semantic errors.\n", .{});
        return;
    };

    var transpiler = c_transpiler.CTranspiler.init(allocator);
    transpiler.is_test_mode = is_test;
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

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ actual_zig, "cc", "-O0", out_c_filename, "-lgc", "-o", final_bin },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("C compilation error:\n{s}\n", .{result.stderr});
        if (!is_build) {
            std.fs.cwd().deleteFile(final_bin) catch {};
        }
        return;
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
        std.fs.cwd().deleteFile(final_bin) catch {};

        if (term == .Exited and term.Exited != 0) {
            std.process.exit(term.Exited);
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
