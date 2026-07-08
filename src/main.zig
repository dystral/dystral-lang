const std = @import("std");
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser.zig");
const c_transpiler = @import("backend/c_transpiler.zig");

/// Main entry point for the Aether CLI.
/// Orchestrates the pipeline: Source -> Lexer -> Parser -> AST -> C Transpiler -> Binary.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "run")) {
        std.debug.print("Usage: aether run <file.ae | file.kt>\n", .{});
        return;
    }

    const filename = args[2];
    if (!std.mem.endsWith(u8, filename, ".ae") and !std.mem.endsWith(u8, filename, ".kt")) {
        std.debug.print("Error: Unsupported file extension. Please use .ae or .kt files.\n", .{});
        return;
    }
    
    const source = try std.fs.cwd().readFileAlloc(allocator, filename, 1024 * 1024);
    defer allocator.free(source);

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
    var type_checker = @import("core/types.zig").TypeChecker.init(arena.allocator(), source, filename);
    defer type_checker.deinit();
    type_checker.validate(ast_root) catch {
        std.debug.print("Compilation aborted due to semantic errors.\n", .{});
        return;
    };

    var transpiler = c_transpiler.CTranspiler.init(allocator);
    defer transpiler.deinit();

    const c_code = try transpiler.transpile(ast_root);
    defer allocator.free(c_code);

    const out_c_filename = "temp_out.c";
    try std.fs.cwd().writeFile(.{ .sub_path = out_c_filename, .data = c_code });
    defer std.fs.cwd().deleteFile(out_c_filename) catch {};

    // Invoke zig cc
    const out_bin_name = "a.out";
    defer std.fs.cwd().deleteFile(out_bin_name) catch {};

    // Try to use zig from path, or local zig if available (for local testing).
    // const zig_bin = "./zig-linux-x86_64-0.13.0/zig"; // hardcoded fallback just for local env 
    
    // Fallback to "zig" if local doesn't exist? Just trying to make it run.
    const actual_zig = "zig";

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ actual_zig, "cc", "-O0", out_c_filename, "-o", out_bin_name },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("C compilation error:\n{s}\n", .{result.stderr});
        return;
    }

    // Execute final binary
    const run_res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "./a.out" },
    });
    defer {
        allocator.free(run_res.stdout);
        allocator.free(run_res.stderr);
    }
    std.debug.print("{s}", .{run_res.stdout});
}

test "imports" {
    _ = @import("core/ast.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("backend/c_transpiler.zig");
}
