//! Zebra compiler entry point.
//!
//! Usage:
//!   zebra <source-file>                        Compile and run.
//!   zebra -c <source-file>                     Compile only; leave binary alongside source.
//!   zebra --emit-zig <source-file>             Print generated Zig source to stdout.
//!   zebra --gui-backend=stub|glfw <source>     Select GUI backend (default: stub).
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

// ── Version ───────────────────────────────────────────────────────────────────
//
// Milestone versioning: each learner-readiness checkpoint = 0.1 increment.
// Format: "<zebra>-zig<major>.<minor>"
//   0.1  Math stdlib
//   0.2  JSON stdlib
//   0.3  Date/time stdlib
//   0.4  CSV stdlib
//   0.5  Source-mapped error messages ✅ DONE
//   0.6  REPL
//   0.7  Escape analysis (replace scanReturnedNames heuristic)
//   0.8  User-defined generics (struct(T))
//   0.9  Book reconciliation (all examples compile)
//   1.0  Language stability / changelog commitment

const ZEBRA_VERSION = std.fmt.comptimePrint("0.1-zig{d}.{d}", .{
    builtin.zig_version.major,
    builtin.zig_version.minor,
});

// ── CLI mode ──────────────────────────────────────────────────────────────────

const Mode = enum {
    /// Compile and immediately run the program (default).
    run,
    /// Compile only; leave the binary alongside the source file.
    compile_only,
    /// Print generated Zig source to stdout; do not invoke the Zig compiler.
    emit_zig,
    /// Compile to a static library (.a / .lib) with C-export wrappers.
    lib_static,
    /// Compile to a shared library (.so / .dll) with C-export wrappers.
    lib_shared,
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
    var gui_backend: CodeGen.GuiBackend = .stub;
    var release: bool = false;
    var source_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zebra {s}\n", .{ZEBRA_VERSION});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-c")) {
            mode = .compile_only;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            mode = .emit_zig;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            mode = .lib_static;
        } else if (std.mem.eql(u8, arg, "--shared")) {
            mode = .lib_shared;
        } else if (std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.startsWith(u8, arg, "--gui-backend=")) {
            const val = arg["--gui-backend=".len..];
            if (std.mem.eql(u8, val, "stub")) {
                gui_backend = .stub;
            } else if (std.mem.eql(u8, val, "glfw")) {
                gui_backend = .glfw;
            } else if (std.mem.eql(u8, val, "sdl2")) {
                gui_backend = .sdl2;
            } else if (std.mem.eql(u8, val, "dx12")) {
                gui_backend = .dx12;
            } else {
                std.debug.print("zebra: unknown gui backend '{s}' (stub|glfw|sdl2|dx12)\n", .{val});
                std.process.exit(1);
            }
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
            \\  zebra <source-file>                        compile and run
            \\  zebra -c <source-file>                     compile only
            \\  zebra --emit-zig <source-file>             print Zig source to stdout
            \\  zebra --lib <source-file>                  compile to static library + .h header
            \\  zebra --shared <source-file>               compile to shared library + .h header
            \\  zebra --release <source-file>              compile with -OReleaseFast
            \\  zebra --gui-backend=stub|glfw <source>     select GUI backend (default: stub)
            \\  zebra --version                            print version and exit
            \\
        , .{});
        std.process.exit(1);
    };

    const src = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer alloc.free(src);

    const exit_code = run(src, path, mode, gui_backend, release, alloc) catch |err| {
        std.debug.print("internal compiler error: {}\n", .{err});
        std.process.exit(2);
    };
    std.process.exit(exit_code);
}

// ── Full pipeline ─────────────────────────────────────────────────────────────

/// Run the full pipeline on `src`.  Returns 0 on success, 1 on user-visible
/// errors, 2 on backend (Zig compiler) errors.
/// Internal (OOM etc.) errors propagate as Zig errors.
fn run(src: []const u8, path: []const u8, mode: Mode, gui_backend: CodeGen.GuiBackend, release: bool, alloc: std.mem.Allocator) !u8 {
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

    // ── 3b. Merge partial class files (<stem>.*.zbr) ──────────────────────────
    var partial_srcs = try mergePartials(&module, path, sym_arena.allocator(), alloc);
    defer { for (partial_srcs.items) |s| alloc.free(s); partial_srcs.deinit(alloc); }

    // ── 3c. Compile imported dependencies ────────────────────────────────────
    // Before running the semantic passes, ensure every `use`d module has been
    // compiled to a .zig file (for Zebra deps) or noted as native (zig/c deps).
    var dep_visited = std.StringHashMap(void).init(alloc);
    defer dep_visited.deinit();
    try dep_visited.put(path, {});

    // Accumulate ModuleInterface for each compiled Zebra dep so the root file's
    // TypeChecker can resolve cross-module member types.
    var imported_modules = std.StringHashMap(TypeChecker.ModuleInterface).init(alloc);
    defer {
        var mit = imported_modules.valueIterator();
        while (mit.next()) |v| v.deinit();
        imported_modules.deinit();
    }

    var native_uses = std.StringHashMap(CodeGen.NativeUse).init(alloc);
    defer native_uses.deinit();
    // Paths of C source files to pass to the Zig backend.  Freed at end of run().
    var c_sources: std.ArrayListUnmanaged([]u8) = .{};
    defer { for (c_sources.items) |p| alloc.free(p); c_sources.deinit(alloc); }

    const src_dir = std.fs.path.dirname(path) orelse ".";
    for (module.decls) |decl| {
        const u = switch (decl) { .use => |u| u, else => continue };
        const dep = try discoverDep(u.path, src_dir, alloc) orelse {
            std.debug.print("{s}: cannot find module '{s}' (tried .zbr, .zig, .c)\n", .{ path, u.path });
            return 1;
        };
        switch (dep.kind) {
            .zbr => {
                // dep.path lives until dep_visited is freed (end of run()).
                // Skip if already compiled as a transitive dep of an earlier
                // direct dep (diamond-dep case) — cross-module inference for
                // it will show .unknown, which is an acceptable MVP limitation.
                if (dep_visited.contains(dep.path)) continue;
                if (try compileZbrToZig(dep.path, &dep_visited, alloc)) |iface| {
                    try imported_modules.put(u.path, iface);
                } else {
                    alloc.free(dep.path);
                    return 1;
                }
            },
            .zig => {
                try native_uses.put(u.path, .zig);
                alloc.free(dep.path); // path not needed beyond this point
            },
            .c_with_header => {
                try native_uses.put(u.path, .c_with_header);
                try c_sources.append(alloc, dep.path); // c_sources takes ownership
            },
            .c_no_header => {
                try native_uses.put(u.path, .c_no_header);
                try c_sources.append(alloc, dep.path);
            },
        }
    }

    // ── 4. Bind (Pass 1) ──────────────────────────────────────────────────────
    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    // ── 5. Resolve (Pass 2) ───────────────────────────────────────────────────
    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc, &imported_modules);
    defer resolve.deinit();

    // ── 6. TypeCheck (Pass 3) ─────────────────────────────────────────────────
    var tc = try TypeChecker.typeCheckPass3(module, &resolve, alloc, alloc, &imported_modules);
    defer tc.deinit();

    // ── Report diagnostics ────────────────────────────────────────────────────
    var had_error = false;
    for (bind.diags)    |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    for (resolve.diags) |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }
    for (tc.diags)      |d| { printDiag(path, d); if (d.kind == .err) had_error = true; }

    if (had_error) return 1;

    // ── 7. CodeGen (Pass 4) ───────────────────────────────────────────────────
    const emit_exports = (mode == .lib_static or mode == .lib_shared);
    if (mode == .emit_zig) {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(alloc);
        _ = try CodeGen.generate(module, &resolve, &tc, alloc, buf.writer(alloc).any(), gui_backend, &native_uses, false, &imported_modules);
        try std.fs.File.stdout().writeAll(buf.items);
        return 0;
    }

    // ── 8. Backend (Pass 5) ───────────────────────────────────────────────────
    // Derive output path: foo/bar.zbr → foo/bar.zig
    const zig_path = try zigPath(path, alloc);
    defer alloc.free(zig_path);

    return backend(module, &resolve, &tc, zig_path, mode, gui_backend, &native_uses, c_sources.items, emit_exports, release, alloc, &imported_modules);
}

// ── Partial class merging ─────────────────────────────────────────────────────

/// Scan the directory of `root_path` for partial files matching `<stem>.*.zbr`
/// (where `<stem>` is the root filename without `.zbr`) and merge their
/// declarations into `module`.
///
/// Convention: `Foo.zbr` is the primary file; `Foo.json.zbr`, `Foo.ui.zbr`
/// etc. are partials.  Each partial may contain:
///   - `class Foo` — members/implements/adds/invariants merged into root's Foo.
///   - `use X`     — appended to root's decl list so dep resolution finds them.
///   - Other decls — appended to root's decl list directly.
///
/// Source text for each partial is heap-allocated and returned in the result
/// list.  The caller must free each slice and deinit the list after the full
/// compilation pipeline completes (arena nodes may reference the text).
fn mergePartials(
    module:    *Ast.Module,
    root_path: []const u8,
    arena:     std.mem.Allocator,
    alloc:     std.mem.Allocator,
) !std.ArrayListUnmanaged([]u8) {
    var srcs = std.ArrayListUnmanaged([]u8){};
    errdefer { for (srcs.items) |s| alloc.free(s); srcs.deinit(alloc); }

    // Only primary files (stem has no dots) can own partials.
    const basename = std.fs.path.basename(root_path);
    if (!std.mem.endsWith(u8, basename, ".zbr")) return srcs;
    const stem = basename[0 .. basename.len - 4];
    if (std.mem.indexOfScalar(u8, stem, '.') != null) return srcs;

    const src_dir_path = std.fs.path.dirname(root_path) orelse ".";

    // Collect matching partial paths.
    var partial_paths = std.ArrayListUnmanaged([]u8){};
    defer { for (partial_paths.items) |p| alloc.free(p); partial_paths.deinit(alloc); }

    var dir = std.fs.cwd().openDir(src_dir_path, .{ .iterate = true }) catch return srcs;
    defer dir.close();
    var dir_it = dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, stem)) continue;
        if (name.len <= stem.len + 1) continue;
        if (name[stem.len] != '.') continue;
        if (!std.mem.endsWith(u8, name, ".zbr")) continue;
        if (std.mem.eql(u8, name, basename)) continue;
        // Require at least one char between the first dot and ".zbr".
        // e.g. "Foo.json.zbr" → after_stem="json.zbr" (len 8, > 4)
        const after_stem = name[stem.len + 1..];
        if (after_stem.len <= 4) continue;
        const full = try std.fs.path.join(alloc, &.{ src_dir_path, name });
        try partial_paths.append(alloc, full);
    }

    if (partial_paths.items.len == 0) return srcs;

    // Sort for deterministic merge order across platforms.
    std.mem.sort([]u8, partial_paths.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.lessThan(u8, a, b); }
    }.lt);

    for (partial_paths.items) |partial_path| {
        const partial_src = std.fs.cwd().readFileAlloc(alloc, partial_path, 64 * 1024 * 1024) catch |err| {
            std.debug.print("error reading partial '{s}': {}\n", .{ partial_path, err });
            continue;
        };
        try srcs.append(alloc, partial_src);

        const ptokens = try Tokenizer.tokenize(partial_src, alloc);
        defer alloc.free(ptokens);

        var presult = try Parser.parse(ptokens, alloc);
        defer presult.deinit();

        const pok = switch (presult) {
            .ok  => |*s| s,
            .err => |e| {
                const bad = if (e.error_pos < ptokens.len) ptokens[e.error_pos] else ptokens[ptokens.len - 1];
                std.debug.print("{s}:{}:{}: syntax error near '{s}'\n", .{
                    partial_path, bad.line, bad.col, bad.text,
                });
                continue;
            },
        };

        var partial_module = try AstBuilder.build(pok, arena);
        // Dupe the path into the arena so it outlives the partial_paths list.
        partial_module.file = try arena.dupe(u8, partial_path);

        try mergePartialInto(module, &partial_module, arena);
    }

    return srcs;
}

/// Merge top-level declarations from `partial` into `root`.
/// Class declarations are merged member-by-member; everything else is appended.
fn mergePartialInto(root: *Ast.Module, partial: *const Ast.Module, arena: std.mem.Allocator) !void {
    var extra = std.ArrayListUnmanaged(Ast.Decl){};
    // Arena-allocated — no explicit deinit needed; freed when arena is freed.

    for (partial.decls) |pdecl| {
        switch (pdecl) {
            .class => |pc| {
                var matched = false;
                for (root.decls) |rdecl| {
                    if (rdecl != .class) continue;
                    const rc = rdecl.class; // *Ast.DeclClass — mutable pointer into arena
                    if (!std.mem.eql(u8, rc.name, pc.name)) continue;
                    // Check for duplicate method names before merging.
                    // Duplicate methods cause Zig compile errors and are almost
                    // always an accidental copy-paste between partial files.
                    // NOTE: Zebra supports overloading via different signatures,
                    // but the Binder does not currently distinguish overloads by
                    // parameter count — same-named methods ARE duplicates.
                    for (pc.members) |pm| {
                        if (pm != .method) continue;
                        const pname = pm.method.name;
                        for (rc.members) |rm| {
                            if (rm != .method) continue;
                            if (std.mem.eql(u8, rm.method.name, pname)) {
                                std.debug.print(
                                    "{s}: duplicate method '{s}.{s}' — already defined in root; skipping partial definition\n",
                                    .{ partial.file, rc.name, pname });
                                break;
                            }
                        }
                    }
                    // Filter out duplicates before appending.
                    var filtered = std.ArrayListUnmanaged(Ast.Decl){};
                    for (pc.members) |pm| {
                        if (pm == .method) {
                            const pname = pm.method.name;
                            var is_dup = false;
                            for (rc.members) |rm| {
                                if (rm == .method and std.mem.eql(u8, rm.method.name, pname)) {
                                    is_dup = true;
                                    break;
                                }
                            }
                            if (is_dup) continue;
                        }
                        try filtered.append(arena, pm);
                    }
                    rc.members    = try concatSlice(Ast.Decl,    rc.members,    filtered.items, arena);
                    rc.implements = try concatSlice(Ast.TypeRef, rc.implements, pc.implements,  arena);
                    rc.adds       = try concatSlice(Ast.TypeRef, rc.adds,       pc.adds,        arena);
                    rc.invariants = try concatSlice(*Ast.Expr,   rc.invariants, pc.invariants,  arena);
                    matched = true;
                    break;
                }
                if (!matched) {
                    std.debug.print("{s}: partial class '{s}' has no matching class in root — skipped\n",
                        .{ partial.file, pc.name });
                }
            },
            else => try extra.append(arena, pdecl),
        }
    }

    if (extra.items.len > 0) {
        root.decls = try concatSlice(Ast.Decl, root.decls, extra.items, arena);
    }
}

/// Concatenate two slices using `arena`.  Returns `a` unchanged when `b` is empty.
fn concatSlice(comptime T: type, a: []const T, b: []const T, arena: std.mem.Allocator) ![]const T {
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    const out = try arena.alloc(T, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

// ── Dependency discovery ──────────────────────────────────────────────────────

/// What kind of file backs a `use` dependency.
const DepKind = enum {
    /// Zebra source file (.zbr) — compile via the Zebra pipeline.
    zbr,
    /// Native Zig file (.zig) — pass to `@import` directly.
    zig,
    /// C source file (.c) — pass as `--c-source` to the Zig compiler.
    /// Sub-fields indicate whether a matching `.h` header was found.
    c_with_header,
    c_no_header,
};

/// Result of discovering a single `use` dependency.
const DepInfo = struct {
    /// Allocated path to the backing file.  Caller must free.
    path: []u8,
    kind: DepKind,
};

/// Convert `kind` to the `CodeGen.NativeUse` variant (only for non-zbr kinds).
fn depKindToNativeUse(kind: DepKind) ?CodeGen.NativeUse {
    return switch (kind) {
        .zbr           => null,
        .zig           => .zig,
        .c_with_header => .c_with_header,
        .c_no_header   => .c_no_header,
    };
}

/// Resolve a dotted Zebra `use` path to a backing file, trying `.zbr`, `.zig`,
/// and `.c` in that order.  Returns null when no matching file is found.
/// Caller must free `DepInfo.path`.
fn discoverDep(
    use_path: []const u8,
    src_dir:  []const u8,
    alloc:    std.mem.Allocator,
) !?DepInfo {
    const rel = try std.mem.replaceOwned(u8, alloc, use_path, ".", std.fs.path.sep_str);
    defer alloc.free(rel);
    const base = try std.fs.path.join(alloc, &.{ src_dir, rel });
    defer alloc.free(base);

    // Try each extension in priority order.
    const candidates = [_]struct { ext: []const u8, kind: DepKind }{
        .{ .ext = ".zbr", .kind = .zbr },
        .{ .ext = ".zig", .kind = .zig },
        .{ .ext = ".c",   .kind = .c_no_header }, // refined below if .h found
    };
    for (candidates) |cand| {
        const p = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base, cand.ext });
        std.fs.cwd().access(p, .{}) catch |err| {
            alloc.free(p);
            if (err == error.FileNotFound) continue;
            return err;
        };
        // Found a .c file — check whether a matching .h header also exists.
        if (cand.kind == .c_no_header) {
            const h = try std.fmt.allocPrint(alloc, "{s}.h", .{base});
            const has_header = if (std.fs.cwd().access(h, .{})) true else |_| false;
            alloc.free(h);
            return DepInfo{ .path = p, .kind = if (has_header) .c_with_header else .c_no_header };
        }
        return DepInfo{ .path = p, .kind = cand.kind };
    }
    return null;
}

/// Compile a .zbr file to the corresponding .zig file, first recursively
/// compiling any of its own `use` dependencies.
///
/// `visited` prevents redundant work and detects import cycles.  Keys are the
/// .zbr paths; they must remain valid for the lifetime of `visited` (caller
/// owns the memory).
///
/// Returns the `ModuleInterface` on success, `null` on any user-visible error
/// (already printed).
///
/// `visited` guards against duplicate / circular compilation.  An
/// already-visited path returns a fresh empty `ModuleInterface` (non-null) so
/// callers can distinguish it from a compilation failure.  Callers in `run()`
/// should pre-check `dep_visited.contains()` and skip the call when the path
/// was already compiled as a transitive dependency.
fn compileZbrToZig(
    zbr_path: []const u8,
    visited:  *std.StringHashMap(void),
    alloc:    std.mem.Allocator,
) anyerror!?TypeChecker.ModuleInterface {
    // Guard against duplicate or circular imports.
    const gop = try visited.getOrPut(zbr_path);
    if (gop.found_existing) return TypeChecker.ModuleInterface{
        .methods = std.StringHashMap(TypeChecker.Type).init(alloc),
        .fields  = std.StringHashMap(TypeChecker.Type).init(alloc),
        .types   = std.StringHashMap(void).init(alloc),
    };

    // ── 1. Read source ────────────────────────────────────────────────────────
    const src = std.fs.cwd().readFileAlloc(alloc, zbr_path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error reading '{s}': {}\n", .{ zbr_path, err });
        return null;
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
            return null;
        },
    };

    // ── 3. Build AST ─────────────────────────────────────────────────────────
    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    defer sym_arena.deinit();

    var module = try AstBuilder.build(ok, sym_arena.allocator());
    module.file = zbr_path;

    // Merge partial class files alongside this dep module.
    var partial_srcs_dep = try mergePartials(&module, zbr_path, sym_arena.allocator(), alloc);
    defer { for (partial_srcs_dep.items) |s| alloc.free(s); partial_srcs_dep.deinit(alloc); }

    // ── 3b. Recurse into this file's own dependencies ─────────────────────────
    const dep_dir = std.fs.path.dirname(zbr_path) orelse ".";
    var dep_native_uses = std.StringHashMap(CodeGen.NativeUse).init(alloc);
    defer dep_native_uses.deinit();
    for (module.decls) |decl| {
        const u = switch (decl) { .use => |u| u, else => continue };
        const dep = try discoverDep(u.path, dep_dir, alloc) orelse {
            std.debug.print("{s}: cannot find module '{s}' (tried .zbr, .zig, .c)\n", .{ zbr_path, u.path });
            return null;
        };
        switch (dep.kind) {
            .zbr => {
                const sub = try compileZbrToZig(dep.path, visited, alloc);
                if (sub == null) { alloc.free(dep.path); return null; }
                var sub_iface = sub.?;
                sub_iface.deinit(); // transitive interfaces not propagated upward
            },
            .zig => {
                try dep_native_uses.put(u.path, .zig);
                alloc.free(dep.path);
            },
            .c_with_header => {
                try dep_native_uses.put(u.path, .c_with_header);
                alloc.free(dep.path); // C sources for dep files are their own concern
            },
            .c_no_header => {
                try dep_native_uses.put(u.path, .c_no_header);
                alloc.free(dep.path);
            },
        }
    }

    // ── 4–6. Semantic passes ──────────────────────────────────────────────────
    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc, null);
    defer resolve.deinit();

    var tc = try TypeChecker.typeCheckPass3(module, &resolve, alloc, alloc, null);
    defer tc.deinit();

    var had_error = false;
    for (bind.diags)    |d| { printDiag(zbr_path, d); if (d.kind == .err) had_error = true; }
    for (resolve.diags) |d| { printDiag(zbr_path, d); if (d.kind == .err) had_error = true; }
    for (tc.diags)      |d| { printDiag(zbr_path, d); if (d.kind == .err) had_error = true; }
    if (had_error) return null;

    // ── 7a. Extract module interface ──────────────────────────────────────────
    // Must happen before sym_arena / resolve are freed (deferred above).
    const iface = try TypeChecker.extractModuleInterface(module, &resolve, alloc);

    // ── 7b. CodeGen → write .zig file ────────────────────────────────────────
    const zig = try zigPath(zbr_path, alloc);
    defer alloc.free(zig);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);
    _ = try CodeGen.generate(module, &resolve, &tc, alloc, buf.writer(alloc).any(), .stub, &dep_native_uses, false, null);

    const f = try std.fs.cwd().createFile(zig, .{});
    defer f.close();
    try f.writeAll(buf.items);

    return iface;
}

// ── Backend: emit Zig file + invoke zig compiler ──────────────────────────────

fn backend(
    module:           Ast.Module,
    resolve:          *const Resolver.ResolveResult,
    tc:               *const TypeChecker.TypeCheckResult,
    zig_path:         []const u8,
    mode:             Mode,
    gui_backend:      CodeGen.GuiBackend,
    native_uses:      *const std.StringHashMap(CodeGen.NativeUse),
    c_sources:        []const []u8,
    emit_exports:     bool,
    release:          bool,
    alloc:            std.mem.Allocator,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
) !u8 {
    // Emit Zig source to file.
    const result = blk: {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(alloc);
        const r = try CodeGen.generate(module, resolve, tc, alloc, buf.writer(alloc).any(), gui_backend, native_uses, emit_exports, imported_modules);
        const f = try std.fs.cwd().createFile(zig_path, .{});
        defer f.close();
        try f.writeAll(buf.items);
        break :blk r;
    };

    // In lib modes, write the C header alongside the .zig file.
    if (emit_exports and result.has_exports) {
        const h_path = try headerPath(zig_path, alloc);
        defer alloc.free(h_path);
        var hbuf = std.ArrayList(u8){};
        defer hbuf.deinit(alloc);
        try CodeGen.generateHeader(module, hbuf.writer(alloc).any());
        const hf = try std.fs.cwd().createFile(h_path, .{});
        defer hf.close();
        try hf.writeAll(hbuf.items);
    }

    // When using a real GUI backend and the program actually references the
    // GUI API, we need a `zig build` project (zgui requires build dependencies).
    if (gui_backend != .stub and result.uses_gui) {
        return compileGuiProject(zig_path, mode, alloc);
    }

    return switch (mode) {
        .compile_only => compileOnly(zig_path, c_sources, release, alloc),
        .run          => compileAndRun(zig_path, c_sources, release, alloc),
        .lib_static   => compileLib(false, zig_path, c_sources, release, alloc),
        .lib_shared   => compileLib(true,  zig_path, c_sources, release, alloc),
        .emit_zig     => unreachable, // handled before backend() is called
    };
}

// ── GUI project compilation ───────────────────────────────────────────────────
//
// When using a non-stub GUI backend, the generated .zig file imports zgui,
// zglfw, and zopengl, which require a `zig build` project with declared
// dependencies.  `compileGuiProject` creates a minimal project directory
// alongside the generated .zig file, fetches zgui (to populate its hash), and
// invokes `zig build run` or `zig build install`.

/// zgui git commit used for the generated GUI project.
const zgui_commit = "d6c4f53c2fbd54673790dc2a5208160a3586ef29";
const zgui_url    = "https://github.com/zig-gamedev/zgui/archive/" ++ zgui_commit ++ ".tar.gz";

/// Minimal `build.zig` written into the generated GUI project.
const gui_project_build_zig =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target   = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const zgui_dep = b.dependency("zgui", .{
    \\        .target   = target,
    \\        .optimize = optimize,
    \\        .backend  = .glfw_opengl3,
    \\    });
    \\    const zglfw_dep = b.dependency("zglfw", .{
    \\        .target   = target,
    \\        .optimize = optimize,
    \\    });
    \\    const zopengl_dep = b.dependency("zopengl", .{
    \\        .target = target,
    \\    });
    \\    const app_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target           = target,
    \\        .optimize         = optimize,
    \\    });
    \\    app_mod.addImport("zgui",    zgui_dep.module("root"));
    \\    app_mod.addImport("zglfw",   zglfw_dep.module("root"));
    \\    app_mod.addImport("zopengl", zopengl_dep.module("root"));
    \\    const exe = b.addExecutable(.{
    \\        .name        = "app",
    \\        .root_module = app_mod,
    \\    });
    \\    exe.linkLibrary(zgui_dep.artifact("imgui"));
    \\    exe.linkLibrary(zglfw_dep.artifact("glfw"));
    \\    b.installArtifact(exe);
    \\    const run_step = b.addRunArtifact(exe);
    \\    b.step("run", "Run the app").dependOn(&run_step.step);
    \\}
    \\
;

/// Initial `build.zig.zon` (without zgui — added by `zig fetch --save=zgui`).
const gui_project_build_zig_zon =
    \\.{
    \\    .name                 = .app,
    \\    .version              = "0.0.1",
    \\    .minimum_zig_version  = "0.15.0",
    \\    .fingerprint          = 0xc96e70cfa59200d7,
    \\    .dependencies = .{
    \\        .zglfw = .{
    \\            .url  = "https://github.com/zig-gamedev/zglfw/archive/0dd29d8073487c9fe1e45e6b729b3aac271d5a71.tar.gz",
    \\            .hash = "zglfw-0.10.0-dev-zgVDNIG4IQBWN_sfMD-xfC9bJS2hbBN2W7jNlDLovcdC",
    \\        },
    \\        .zopengl = .{
    \\            .url  = "https://github.com/zig-gamedev/zopengl/archive/db9d615c742086b39954eef064f957e92dafc7e2.tar.gz",
    \\            .hash = "zopengl-0.6.0-dev-5-tnz36mDgBuU9pDfag6_B-qCWOJQc5GXiXuZ6z41zQM",
    \\        },
    \\    },
    \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
    \\}
    \\
;

/// Create a `zig build` project next to `zig_path`, fetch zgui, then build/run.
/// Project dir: `<stem>_gui/` (e.g. `test/gui_test_gui/`).
fn compileGuiProject(zig_path: []const u8, mode: Mode, alloc: std.mem.Allocator) !u8 {
    const stem    = pathStem(zig_path);
    const proj    = try std.fmt.allocPrint(alloc, "{s}_gui", .{stem});
    defer alloc.free(proj);
    const src_dir = try std.fs.path.join(alloc, &.{ proj, "src" });
    defer alloc.free(src_dir);

    // 1. Create directory tree.
    try std.fs.cwd().makePath(src_dir);

    // 2. Copy generated .zig → project/src/main.zig.
    const main_zig = try std.fs.path.join(alloc, &.{ src_dir, "main.zig" });
    defer alloc.free(main_zig);
    try std.fs.cwd().copyFile(zig_path, std.fs.cwd(), main_zig, .{});

    // 3. Write build.zig and build.zig.zon.
    inline for (.{
        .{ "build.zig",     gui_project_build_zig     },
        .{ "build.zig.zon", gui_project_build_zig_zon },
    }) |pair| {
        const fpath = try std.fs.path.join(alloc, &.{ proj, pair[0] });
        defer alloc.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll(pair[1]);
    }

    // 4. Absolute path of the project dir (needed for child.cwd).
    const abs_proj = try std.fs.cwd().realpathAlloc(alloc, proj);
    defer alloc.free(abs_proj);

    // 5. zig fetch --save=zgui <url>  (adds zgui entry + hash to build.zig.zon).
    {
        const argv = [_][]const u8{ "zig", "fetch", "--save=zgui", zgui_url };
        var child = std.process.Child.init(&argv, alloc);
        child.cwd              = abs_proj;
        child.stdin_behavior   = .Inherit;
        child.stdout_behavior  = .Inherit;
        child.stderr_behavior  = .Inherit;
        const term = try child.spawnAndWait();
        const code = switch (term) { .Exited => |c| c, else => @as(u8, 1) };
        if (code != 0) {
            std.debug.print("zebra: 'zig fetch' failed (exit {d})\n", .{code});
            return code;
        }
    }

    // 6. zig build run / install.
    {
        const build_step = if (mode == .run) "run" else "install";
        const argv = [_][]const u8{ "zig", "build", build_step };
        var child = std.process.Child.init(&argv, alloc);
        child.cwd             = abs_proj;
        child.stdin_behavior  = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const term = try child.spawnAndWait();
        return switch (term) { .Exited => |c| c, else => 1 };
    }
}

/// `zig build-exe <file.zig> [c_sources...] -lc`
/// The `-lc` flag is required so that stdlib functions like std.posix.recv
/// resolve correctly on all platforms (including Windows sockets).
/// C source files (from `use X` where `X.c` exists) are appended as positional
/// args — Zig recognises `.c` extensions and compiles them as C translation units.
/// `zig build-exe <file.zig> [c_sources...] -lc`
/// For each C source file, adds `-I <parent_dir>` so `@cInclude("Foo.h")` resolves.
fn compileOnly(zig_path: []const u8, c_sources: []const []u8, release: bool, alloc: std.mem.Allocator) !u8 {
    return runZigCmd("build-exe", zig_path, c_sources, release, alloc);
}

/// `zig run <file.zig> [c_sources...] -lc` — compile and immediately execute.
fn compileAndRun(zig_path: []const u8, c_sources: []const []u8, release: bool, alloc: std.mem.Allocator) !u8 {
    return runZigCmd("run", zig_path, c_sources, release, alloc);
}

/// `zig build-lib [--dynamic] <file.zig> [c_sources...] -lc`
/// Produces a static `.a` / `.lib` or shared `.so` / `.dll`.
fn compileLib(shared: bool, zig_path: []const u8, c_sources: []const []u8, release: bool, alloc: std.mem.Allocator) !u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(alloc);
    var i_flags: std.ArrayListUnmanaged([]u8) = .{};
    defer { for (i_flags.items) |f| alloc.free(f); i_flags.deinit(alloc); }

    try argv.appendSlice(alloc, &.{ "zig", "build-lib", zig_path });
    if (shared) try argv.append(alloc, "--dynamic");
    if (release) try argv.append(alloc, "-OReleaseFast");

    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer seen_dirs.deinit();
    for (c_sources) |cs| {
        try argv.append(alloc, cs);
        const dir = std.fs.path.dirname(cs) orelse ".";
        const gop = try seen_dirs.getOrPut(dir);
        if (!gop.found_existing) {
            const flag = try std.fmt.allocPrint(alloc, "-I{s}", .{dir});
            try i_flags.append(alloc, flag);
            try argv.append(alloc, flag);
        }
    }
    try argv.append(alloc, "-lc");
    return runChild(argv.items, alloc);
}

fn runZigCmd(
    cmd:       []const u8,
    zig_path:  []const u8,
    c_sources: []const []u8,
    release:   bool,
    alloc:     std.mem.Allocator,
) !u8 {
    // Collect argv + any allocated -I flags (freed after child exits).
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(alloc);
    var i_flags: std.ArrayListUnmanaged([]u8) = .{};
    defer { for (i_flags.items) |f| alloc.free(f); i_flags.deinit(alloc); }

    try argv.appendSlice(alloc, &.{ "zig", cmd, zig_path });
    if (release) try argv.append(alloc, "-OReleaseFast");

    // For each C source: append the file path, then deduplicate -I <dir> flags.
    var seen_dirs = std.StringHashMap(void).init(alloc);
    defer seen_dirs.deinit();
    for (c_sources) |cs| {
        try argv.append(alloc, cs);
        const dir = std.fs.path.dirname(cs) orelse ".";
        const gop = try seen_dirs.getOrPut(dir);
        if (!gop.found_existing) {
            const flag = try std.fmt.allocPrint(alloc, "-I{s}", .{dir});
            try i_flags.append(alloc, flag);
            try argv.append(alloc, flag);
        }
    }
    try argv.append(alloc, "-lc");
    return runChildRemapped(argv.items, zig_path, alloc);
}

/// Spawn a child process with inherited stdio.  Returns the exit code.
/// Used for non-primary compile steps (zig fetch, zig build) where we
/// don't have a generated .zig file to remap errors against.
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

/// Spawn a child process, capture stderr, and on failure remap Zig compiler
/// error locations to their originating Zebra source lines using the
/// `// zbr:file:line` markers emitted by CodeGen.
fn runChildRemapped(argv: []const []const u8, zig_path: []const u8, alloc: std.mem.Allocator) !u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior  = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stderr_text = try child.stderr.?.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(stderr_text);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited  => |c| c,
        .Signal  => |_| 1,
        .Stopped => |_| 1,
        .Unknown => |_| 1,
    };

    if (stderr_text.len > 0) {
        if (code != 0) {
            // Remap Zig error locations → Zebra source locations.
            const remapped = remapZigErrors(stderr_text, zig_path, alloc) catch stderr_text;
            defer if (remapped.ptr != stderr_text.ptr) alloc.free(remapped);
            std.debug.print("{s}", .{remapped});
        } else {
            // Warnings on success — pass through unchanged.
            std.debug.print("{s}", .{stderr_text});
        }
    }
    return code;
}

// ── Source-map error remapping ────────────────────────────────────────────────

/// Remap Zig compiler error messages to Zebra source locations.
///
/// The generated .zig file contains `// zbr:filename:line` comments before
/// each statement.  When the Zig compiler reports `file.zig:N:M: error: …`,
/// we read the generated file, walk backward from line N to the nearest
/// `// zbr:` comment, and re-emit the error with the Zebra location.
///
/// Lines referencing files other than `zig_path` (stdlib, etc.) pass through
/// unchanged.  Generated-code context lines (indented source + caret) are
/// suppressed since they show Zig internals the user never wrote.
fn remapZigErrors(stderr_text: []const u8, zig_path: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    // Read the generated .zig file.  If unavailable, return original text.
    const zig_src = std.fs.cwd().readFileAlloc(alloc, zig_path, 64 * 1024 * 1024) catch {
        return alloc.dupe(u8, stderr_text);
    };
    defer alloc.free(zig_src);

    // Split into lines for backward searching.
    var zig_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer zig_lines.deinit(alloc);
    var lit = std.mem.splitScalar(u8, zig_src, '\n');
    while (lit.next()) |l| try zig_lines.append(alloc, l);

    const zig_base = std.fs.path.basename(zig_path);

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);

    var sit = std.mem.splitScalar(u8, stderr_text, '\n');
    var skip_context = false;

    while (sit.next()) |line| {
        // Context lines from the Zig compiler (indented source + caret):
        // suppress them when we successfully remapped the preceding error line.
        if (skip_context) {
            if (line.len == 0 or line[0] != ' ') {
                skip_context = false;
                // Fall through — process this line normally.
            } else {
                continue; // drop indented context line
            }
        }

        if (parseZigDiagLine(line, zig_base)) |d| {
            // Walk backward in the generated file to find the zbr: marker.
            if (findZbrComment(zig_lines.items, d.zig_line)) |loc| {
                try out.writer(alloc).print("{s}:{d}: {s}: {s}\n", .{
                    loc.file, loc.line, d.severity, d.message,
                });
                skip_context = true;
                continue;
            }
            // No marker found — emit original line unchanged.
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

const ZigDiag = struct {
    zig_line: usize,
    severity: []const u8,
    message:  []const u8,
};

/// Parse a Zig diagnostic line of the form:
///   <path_containing_zig_base>:N:M: (error|note|warning): message
/// Returns null if the line doesn't match or doesn't reference our file.
fn parseZigDiagLine(line: []const u8, zig_base: []const u8) ?ZigDiag {
    // Find the basename in the path portion.
    const base_pos = std.mem.indexOf(u8, line, zig_base) orelse return null;
    const after = line[base_pos + zig_base.len ..];
    if (after.len == 0 or after[0] != ':') return null;
    var rest = after[1..]; // skip first ':'

    // Parse line number.
    const c1 = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const zig_line = std.fmt.parseInt(usize, rest[0..c1], 10) catch return null;
    rest = rest[c1 + 1 ..]; // skip 'N:'

    // Skip column number.
    const c2 = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    _ = std.fmt.parseInt(usize, rest[0..c2], 10) catch return null;
    rest = rest[c2 + 1 ..]; // skip 'M:'

    if (rest.len == 0 or rest[0] != ' ') return null;
    rest = rest[1..];

    const sevs = [_][]const u8{ "error", "note", "warning" };
    for (sevs) |sev| {
        if (std.mem.startsWith(u8, rest, sev) and
            rest.len > sev.len + 1 and
            rest[sev.len] == ':' and rest[sev.len + 1] == ' ')
        {
            return ZigDiag{
                .zig_line = zig_line,
                .severity = sev,
                .message  = rest[sev.len + 2 ..],
            };
        }
    }
    return null;
}

const ZbrLoc = struct { file: []const u8, line: u32 };

/// Walk backward from `error_line` (1-based) through the generated Zig source
/// lines to find the nearest `// zbr:filename:N` marker.
fn findZbrComment(zig_lines: []const []const u8, error_line: usize) ?ZbrLoc {
    if (error_line == 0 or zig_lines.len == 0) return null;
    // Convert 1-based line to 0-based index, clamped to file length.
    var i: usize = @min(error_line - 1, zig_lines.len - 1);
    while (true) {
        const trimmed = std.mem.trimLeft(u8, zig_lines[i], " \t");
        if (std.mem.startsWith(u8, trimmed, "// zbr:")) {
            const payload = trimmed["// zbr:".len..];
            // payload = "filename:N"  (last colon separates file from line)
            const colon = std.mem.lastIndexOfScalar(u8, payload, ':') orelse return null;
            const file = payload[0..colon];
            const line_num = std.fmt.parseInt(u32, payload[colon + 1 ..], 10) catch return null;
            return ZbrLoc{ .file = file, .line = line_num };
        }
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

// ── Path helpers ──────────────────────────────────────────────────────────────

/// Derive the output Zig file path from the Zebra source path.
/// `foo/bar.zbr` → `foo/bar.zig`
/// `foo/bar`     → `foo/bar.zig`
fn zigPath(source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const stem = pathStem(source);
    return std.fmt.allocPrint(alloc, "{s}.zig", .{stem});
}

/// Derive the C header path from the Zig file path.
/// `foo/bar.zig` → `foo/bar.h`
fn headerPath(zig: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const stem = pathStem(zig);
    return std.fmt.allocPrint(alloc, "{s}.h", .{stem});
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
