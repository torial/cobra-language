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
        if (std.mem.eql(u8, arg, "-c")) {
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

    // ── 3b. Compile imported dependencies ────────────────────────────────────
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
    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc);
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
        _ = try CodeGen.generate(module, &resolve, &tc, alloc, buf.writer(alloc).any(), gui_backend, &native_uses, false);
        try std.fs.File.stdout().writeAll(buf.items);
        return 0;
    }

    // ── 8. Backend (Pass 5) ───────────────────────────────────────────────────
    // Derive output path: foo/bar.zbr → foo/bar.zig
    const zig_path = try zigPath(path, alloc);
    defer alloc.free(zig_path);

    return backend(module, &resolve, &tc, zig_path, mode, gui_backend, &native_uses, c_sources.items, emit_exports, release, alloc);
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

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc);
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
    _ = try CodeGen.generate(module, &resolve, &tc, alloc, buf.writer(alloc).any(), .stub, &dep_native_uses, false);

    const f = try std.fs.cwd().createFile(zig, .{});
    defer f.close();
    try f.writeAll(buf.items);

    return iface;
}

// ── Backend: emit Zig file + invoke zig compiler ──────────────────────────────

fn backend(
    module:       Ast.Module,
    resolve:      *const Resolver.ResolveResult,
    tc:           *const TypeChecker.TypeCheckResult,
    zig_path:     []const u8,
    mode:         Mode,
    gui_backend:  CodeGen.GuiBackend,
    native_uses:  *const std.StringHashMap(CodeGen.NativeUse),
    c_sources:    []const []u8,
    emit_exports: bool,
    release:      bool,
    alloc:        std.mem.Allocator,
) !u8 {
    // Emit Zig source to file.
    const result = blk: {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(alloc);
        const r = try CodeGen.generate(module, resolve, tc, alloc, buf.writer(alloc).any(), gui_backend, native_uses, emit_exports);
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
    return runChild(argv.items, alloc);
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
