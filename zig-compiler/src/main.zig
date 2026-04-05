//! Zebra compiler entry point.
//!
//! Usage:
//!   zebra <source-file>           Compile and run.
//!   zebra -c <source-file>        Compile only; leave binary alongside source.
//!   zebra --emit-zig <source-file> Print generated Zig source to stdout.
//!
//! Semantic pipeline:
//!   1. Tokenize
//!   2. Parse
//!   3. Build AST
//!   4. Bind       (Pass 1 — forward-declare all names)
//!   5. Resolve    (Pass 2 — resolve TypeRefs, ExprIdents, declare locals)
//!   6. TypeCheck  (Pass 3 — assign types, check compatibility)
//!   7. CodeGen    (Pass 4 — emit Zig source)
//!   8. Backend    (Pass 5 — invoke `zig` to produce / run the binary)

const std         = @import("std");
const builtin     = @import("builtin");
const Ast         = @import("Ast.zig");
const Tokenizer   = @import("Tokenizer.zig");
const Parser      = @import("Parser.zig");
const AstBuilder  = @import("AstBuilder.zig");
const Binder      = @import("Binder.zig");
const Resolver    = @import("Resolver.zig");
const TypeChecker = @import("TypeChecker.zig");
const CodeGen     = @import("CodeGen.zig");

// ── CLI mode ──────────────────────────────────────────────────────────────────

const Mode = enum {
    /// Compile and immediately run the program (default).
    run,
    /// Compile only; leave the binary alongside the source file.
    compile_only,
    /// Print generated Zig source to stdout; do not invoke the Zig compiler.
    emit_zig,
};

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = std.process.argsAlloc(alloc) catch @panic("OOM");
    defer std.process.argsFree(alloc, args);

    // Parse flags and find the source path.
    var mode: Mode = .run;
    var source_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            mode = .compile_only;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            mode = .emit_zig;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("zebra: unknown flag '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            if (source_path != null) {
                std.debug.print("zebra: too many source files\n", .{});
                std.process.exit(1);
            }
            source_path = arg;
        }
    }

    const path = source_path orelse {
        std.debug.print(
            \\usage:
            \\  zebra <source-file>            compile and run
            \\  zebra -c <source-file>         compile only
            \\  zebra --emit-zig <source-file> print Zig source to stdout
            \\
        , .{});
        std.process.exit(1);
    };

    const src = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer alloc.free(src);

    const exit_code = run(src, path, mode, alloc) catch |err| {
        std.debug.print("internal compiler error: {}\n", .{err});
        std.process.exit(2);
    };
    std.process.exit(exit_code);
}

// ── Full pipeline ─────────────────────────────────────────────────────────────

/// Run the full pipeline on `src`.  Returns 0 on success, 1 on user-visible
/// errors, 2 on backend (Zig compiler) errors.
/// Internal (OOM etc.) errors propagate as Zig errors.
fn run(src: []const u8, path: []const u8, mode: Mode, alloc: std.mem.Allocator) !u8 {
    // ── 1. Tokenize ───────────────────────────────────────────────────────────
    const tokens = try Tokenizer.tokenize(src, alloc);
    defer alloc.free(tokens);

    // ── 2. Parse ──────────────────────────────────────────────────────────────
    var parse_result = try Parser.parse(tokens, alloc);
    defer parse_result.deinit();

    const ok = switch (parse_result) {
        .ok  => |*s| s,
        .err => |e| {
            const bad = if (e.error_pos < tokens.len) tokens[e.error_pos] else tokens[tokens.len - 1];
            std.debug.print("{s}:{}:{}: syntax error near '{s}'\n", .{
                path, bad.line, bad.col, bad.text,
            });
            return 1;
        },
    };

    // ── 3. Build AST ──────────────────────────────────────────────────────────
    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    defer sym_arena.deinit();

    var module = try AstBuilder.build(ok, sym_arena.allocator());
    module.file = path;

    // ── 3b. Compile imported dependencies ────────────────────────────────────
    // Before running the semantic passes, ensure every `use`d module has been
    // compiled to a .zig file in the right location.  We track visited paths to
    // handle diamonds and detect cycles.
    var dep_visited = std.StringHashMap(void).init(alloc);
    defer dep_visited.deinit();
    // Mark the root file itself so a dep can't recursively trigger recompilation
    // of the root (which isn't built yet at this point).
    try dep_visited.put(path, {});
    const src_dir = std.fs.path.dirname(path) orelse ".";
    for (module.decls) |decl| {
        const u = switch (decl) { .use => |u| u, else => continue };
        const dep_zbr = try usePathToZbrPath(u.path, src_dir, alloc);
        // dep_zbr outlives dep_visited (both live until end of run()) so no free yet.
        if (!try compileZbrToZig(dep_zbr, &dep_visited, alloc)) return 1;
    }

    // ── 4. Bind (Pass 1) ──────────────────────────────────────────────────────
    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    // ── 5. Resolve (Pass 2) ───────────────────────────────────────────────────
    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc);
    defer resolve.deinit();

    // ── 6. TypeCheck (Pass 3) ─────────────────────────────────────────────────
    var tc = try TypeChecker.typeCheckPass3(module, &resolve, alloc, alloc);
    defer tc.deinit();

    // ── Report diagnostics ────────────────────────────────────────────────────
    var had_error = false;
    for (bind.diags)    |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    for (resolve.diags) |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    for (tc.diags)      |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }

    if (had_error) return 1;

    // ── 7. CodeGen (Pass 4) ───────────────────────────────────────────────────
    if (mode == .emit_zig) {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(alloc);
        try CodeGen.generate(module, &resolve, &tc, alloc, buf.writer(alloc).any());
        try std.fs.File.stdout().writeAll(buf.items);
        return 0;
    }

    // ── 8. Backend (Pass 5) ───────────────────────────────────────────────────
    // Derive output path: foo/bar.zbr → foo/bar.zig
    const zig_path = try zigPath(path, alloc);
    defer alloc.free(zig_path);

    return backend(module, &resolve, &tc, zig_path, mode, alloc);
}

// ── Dependency compilation ────────────────────────────────────────────────────

/// Convert a Zebra dotted module path to a .zbr file path relative to `src_dir`.
/// `use Math.Utils` from `dir/main.zbr` → `dir/Math/Utils.zbr`.
/// Caller must free the returned slice when `visited` no longer needs the key.
fn usePathToZbrPath(
    zebra_path: []const u8,
    src_dir:    []const u8,
    alloc:      std.mem.Allocator,
) ![]u8 {
    // Replace '.' with OS path separator for file-system lookups.
    const rel = try std.mem.replaceOwned(u8, alloc, zebra_path, ".", std.fs.path.sep_str);
    defer alloc.free(rel);
    const joined = try std.fs.path.join(alloc, &.{ src_dir, rel });
    defer alloc.free(joined);
    return std.fmt.allocPrint(alloc, "{s}.zbr", .{joined});
}

/// Compile a .zbr file to the corresponding .zig file, first recursively
/// compiling any of its own `use` dependencies.
///
/// `visited` prevents redundant work and detects import cycles.  Keys are the
/// .zbr paths; they must remain valid for the lifetime of `visited` (caller
/// owns the memory).
///
/// Returns `true` on success, `false` on any user-visible error (already printed).
fn compileZbrToZig(
    zbr_path: []const u8,
    visited:  *std.StringHashMap(void),
    alloc:    std.mem.Allocator,
) anyerror!bool {
    // Guard against duplicate or circular imports.
    const gop = try visited.getOrPut(zbr_path);
    if (gop.found_existing) return true;

    // ── 1. Read source ────────────────────────────────────────────────────────
    const src = std.fs.cwd().readFileAlloc(alloc, zbr_path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error reading '{s}': {}\n", .{ zbr_path, err });
        return false;
    };
    defer alloc.free(src);

    // ── 2. Tokenize + Parse ───────────────────────────────────────────────────
    const tokens = try Tokenizer.tokenize(src, alloc);
    defer alloc.free(tokens);

    var parse_result = try Parser.parse(tokens, alloc);
    defer parse_result.deinit();

    const ok = switch (parse_result) {
        .ok  => |*s| s,
        .err => |e| {
            const bad = if (e.error_pos < tokens.len) tokens[e.error_pos] else tokens[tokens.len - 1];
            std.debug.print("{s}:{}:{}: syntax error near '{s}'\n", .{
                zbr_path, bad.line, bad.col, bad.text,
            });
            return false;
        },
    };

    // ── 3. Build AST ─────────────────────────────────────────────────────────
    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    defer sym_arena.deinit();

    var module = try AstBuilder.build(ok, sym_arena.allocator());
    module.file = zbr_path;

    // ── 3b. Recurse into this file's own dependencies ─────────────────────────
    const dep_dir = std.fs.path.dirname(zbr_path) orelse ".";
    for (module.decls) |decl| {
        const u = switch (decl) { .use => |u| u, else => continue };
        const dep_zbr = try usePathToZbrPath(u.path, dep_dir, alloc);
        // dep_zbr key must outlive `visited`; caller is responsible for freeing
        // it after visited is destroyed.  Here visited is in the root run() frame
        // which outlives all recursive calls, so the alloc'd key is fine.
        if (!try compileZbrToZig(dep_zbr, visited, alloc)) return false;
    }

    // ── 4–6. Semantic passes ──────────────────────────────────────────────────
    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc);
    defer resolve.deinit();

    var tc = try TypeChecker.typeCheckPass3(module, &resolve, alloc, alloc);
    defer tc.deinit();

    var had_error = false;
    for (bind.diags)    |d| { printDiag(zbr_path, d); if (d.kind == .err) had_error = true; }
    for (resolve.diags) |d| { printDiag(zbr_path, d); if (d.kind == .err) had_error = true; }
    for (tc.diags)      |d| { printDiag(zbr_path, d); if (d.kind == .err) had_error = true; }
    if (had_error) return false;

    // ── 7. CodeGen → write .zig file ─────────────────────────────────────────
    const zig = try zigPath(zbr_path, alloc);
    defer alloc.free(zig);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);
    try CodeGen.generate(module, &resolve, &tc, alloc, buf.writer(alloc).any());

    const f = try std.fs.cwd().createFile(zig, .{});
    defer f.close();
    try f.writeAll(buf.items);

    return true;
}

// ── Backend: emit Zig file + invoke zig compiler ──────────────────────────────

fn backend(
    module:   Ast.Module,
    resolve:  *const Resolver.ResolveResult,
    tc:       *const TypeChecker.TypeCheckResult,
    zig_path: []const u8,
    mode:     Mode,
    alloc:    std.mem.Allocator,
) !u8 {
    // Emit Zig source to file.
    {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(alloc);
        try CodeGen.generate(module, resolve, tc, alloc, buf.writer(alloc).any());
        const f = try std.fs.cwd().createFile(zig_path, .{});
        defer f.close();
        try f.writeAll(buf.items);
    }

    return switch (mode) {
        .compile_only => compileOnly(zig_path, alloc),
        .run          => compileAndRun(zig_path, alloc),
        .emit_zig     => unreachable, // handled before backend() is called
    };
}

/// `zig build-exe <file.zig> -lc` — produces a binary in the current directory.
/// The `-lc` flag is required so that stdlib functions like std.posix.recv
/// resolve correctly on all platforms (including Windows sockets).
fn compileOnly(zig_path: []const u8, alloc: std.mem.Allocator) !u8 {
    const argv = [_][]const u8{ "zig", "build-exe", zig_path, "-lc" };
    return runChild(&argv, alloc);
}

/// `zig run <file.zig> -lc` — compile and immediately execute.
fn compileAndRun(zig_path: []const u8, alloc: std.mem.Allocator) !u8 {
    const argv = [_][]const u8{ "zig", "run", zig_path, "-lc" };
    return runChild(&argv, alloc);
}

/// Spawn a child process with inherited stdio.  Returns the exit code.
fn runChild(argv: []const []const u8, alloc: std.mem.Allocator) !u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior  = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited  => |code| code,
        .Signal  => |_|    1,
        .Stopped => |_|    1,
        .Unknown => |_|    1,
    };
}

// ── Path helpers ──────────────────────────────────────────────────────────────

/// Derive the output Zig file path from the Zebra source path.
/// `foo/bar.zbr` → `foo/bar.zig`
/// `foo/bar`     → `foo/bar.zig`
fn zigPath(source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const stem = pathStem(source);
    return std.fmt.allocPrint(alloc, "{s}.zig", .{stem});
}

/// Strip the file extension (everything from the last `.` that comes after the
/// last path separator).  Returns the input unchanged if there is no extension.
fn pathStem(path: []const u8) []const u8 {
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\") orelse 0;
    if (std.mem.lastIndexOf(u8, path, ".")) |dot| {
        if (dot > last_sep) return path[0..dot];
    }
    return path;
}

// ── Diagnostics ───────────────────────────────────────────────────────────────

fn printDiag(path: []const u8, d: Binder.Diagnostic) void {
    const label: []const u8 = if (d.kind == .err) "error" else "warning";
    std.debug.print("{s}:{}:{}: {s}: {s}\n", .{
        path, d.span.line, d.span.col, label, d.message,
    });
}

// ── Sub-module test pull-in ───────────────────────────────────────────────────

comptime {
    _ = @import("Token.zig");
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
    _ = @import("Parser.zig");
    _ = @import("ZebraGrammar.zig");
    _ = @import("AstBuilder.zig");
    _ = @import("AstPrinter.zig");
    _ = @import("SymbolTable.zig");
    _ = @import("Binder.zig");
    _ = @import("Resolver.zig");
    _ = @import("TypeChecker.zig");
    _ = @import("CodeGen.zig");
}
