//! CodeGen: emit Zig source from a Zebra AST.
//!
//! Pass 4 of the compiler: consumes the AST and Resolver's name-resolution
//! tables, and emits a Zig source file to `writer`.
//!
//! ## Mapping rules
//!
//! | Zebra              | Zig                                              |
//! |--------------------|--------------------------------------------------|
//! | `class Foo`        | `pub const Foo = struct { ... };`                |
//! | `interface IFoo`   | `pub fn IFoo(comptime T: type) void { ... }`     |
//! | `mixin M`          | inlined at `adds M` sites; no standalone output  |
//! | `struct Foo`       | `pub const Foo = struct { ... };`                |
//! | `enum Color`       | `pub const Color = enum { ... };`                |
//! | `namespace Ns`     | `pub const Ns = struct { ... };`                 |
//! | `int`              | `i64`                                            |
//! | `float`            | `f64`                                            |
//! | `bool`             | `bool`                                           |
//! | `char`             | `u21`                                            |
//! | `String`           | `[]const u8`                                     |
//! | `T?`               | `?T`                                             |
//! | `!T`               | `anyerror!T`                                     |
//! | `zig"..."`, `zig'...'` | inner content (inline Zig literal)           |
//!
//! ## Self-prefix injection
//!
//! Inside method bodies, `ExprIdent` nodes that resolve to `.var_` (field)
//! symbols are emitted as `self.name`.  All other identifiers are emitted as
//! `name`.  This uses the `exprs` map from the Resolver.
//!
//! ## Mixins
//!
//! Mixin members are inlined directly into every class that names them in an
//! `adds` clause.  Mixins are not emitted as standalone types.
//!
//! ## Interfaces
//!
//! Interfaces are emitted as comptime checker functions:
//! ```zig
//! pub fn IFoo(comptime T: type) void {
//!     comptime {
//!         if (!@hasDecl(T, "method")) @compileError("...");
//!     }
//! }
//! ```
//! Every class that `implements IFoo` gets a `comptime { IFoo(@This()); }` block.
//!
//! ## Inheritance
//!
//! Zebra inheritance is intentionally **not** mapped to Zig.  Classes that
//! extend other classes require manual rewrite to use composition.

const std         = @import("std");
const Ast         = @import("Ast.zig");
const Resolver    = @import("Resolver.zig");
const ST          = @import("SymbolTable.zig");
const TypeChecker = @import("TypeChecker.zig");
const Builtins    = @import("Builtins.zig");

const Allocator = std.mem.Allocator;

// ── Compile-time hash (FNV-1a 32-bit) ────────────────────────────────────────
// Used internally by CodeGen to compute class-name hash components for
// `_ttag_ClassName` constants.  The algorithm must stay bitwise-identical to
// the `_zbr_hash` function emitted into the preamble so that generic type-arg
// hashes agree (Phase 3: `is Stack(int)` checks).
//
// Type-tag layout (u64):
//   bits [31: 0] = FNV-1a 32-bit hash of the class name
//   bits [63:32] = combined FNV-1a 32-bit hash of type args (0 for non-generics)
//
// This means:
//   - `expr is Dog`        → expr._type_tag == _ttag_Dog     (upper bits 0)
//   - `expr is Stack`      → (expr._type_tag & 0xFFFFFFFF) == _ttag_Stack
//   - `expr is Stack(int)` → expr._type_tag == <combined u64 literal>

fn zbr_hash_str(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |c| {
        h ^= @as(u32, c);
        h = h *% 16777619;
    }
    return h;
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Which GUI backend to embed in the generated Zig preamble.
pub const GuiBackend = enum { stub, glfw, sdl2, dx12 };

/// How a native (non-Zebra) `use` dependency is backed.
/// Used by `genUse` to emit the correct import statement.
pub const NativeUse = enum {
    /// A plain `.zig` file — emit `const Alias = @import("path.zig");`
    zig,
    /// A `.c` file with a matching `.h` header — emit `@cImport(@cInclude(...))`.
    c_with_header,
    /// A `.c` file with no header — compiled as a translation unit only;
    /// emit a comment and let the user declare symbols via `zig"extern fn..."`.
    c_no_header,
};

/// Result returned by `generate()`.  Currently carries only `uses_gui`; more
/// fields may be added without breaking callers that ignore or destructure.
pub const GenerateResult = struct {
    /// True when the generated code references any GUI API (`Gui.run`, widget
    /// calls, etc.).  Callers may use this to decide whether to wire up an
    /// external GUI dependency (e.g. zgui + zglfw for the glfw backend).
    uses_gui: bool,
    /// True when at least one `export fn` wrapper was emitted (lib mode only).
    /// Callers may use this to decide whether to write a `.h` header file.
    has_exports: bool,
};

/// Emit Zig source for `module` to `writer`.
///
/// - `resolve`      — Pass-2 name-resolution tables (needed for `self.` injection).
/// - `tc`           — Pass-3 type information.  Pass `null` to skip typed format
///                    specifiers (all `print` args fall back to `{any}`).
/// - `alloc`        — Used for the mixin index and per-method mutation analysis.
/// - `writer`       — Destination for the generated Zig source.
/// - `gui_backend`  — Which GUI backend preamble to embed (default: `.stub`).
/// - `native_uses`  — Map from dotted `use` path → `NativeUse` kind for deps that
///                    are native `.zig` or `.c` files (not compiled from Zebra).
///                    Pass `null` when all deps are Zebra-compiled.
pub fn generate(
    module:           Ast.Module,
    resolve:          *const Resolver.ResolveResult,
    tc:               ?*const TypeChecker.TypeCheckResult,
    alloc:            Allocator,
    writer:           std.io.AnyWriter,
    gui_backend:      GuiBackend,
    native_uses:      ?*const std.StringHashMap(NativeUse),
    emit_exports:     bool,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
) anyerror!GenerateResult {
    var mixins = try collectMixins(module, alloc);
    defer mixins.deinit();
    var union_names = try collectUnionNames(module, alloc);
    defer union_names.deinit();
    var union_decls = try collectUnionDecls(module, alloc);
    defer union_decls.deinit();
    var exposed_unions = std.StringHashMap([]const u8).init(alloc); // maps exposed name → module alias
    defer exposed_unions.deinit();
    var exposed_classes = std.StringHashMap(void).init(alloc);
    defer exposed_classes.deinit();

    var uses_gui    = false;
    var has_exports = false;
    const g = Generator{
        .resolve     = resolve,
        .tc          = tc,
        .w           = writer,
        .indent      = 0,
        .owner       = "",
        .in_method   = false,
        .mixins      = &mixins,
        .alloc       = alloc,
        .mutated          = null,
        .closure_vars     = null,
        .capture_fields   = &.{},
        .union_names      = &union_names,
        .union_decls      = &union_decls,
        .exposed_unions   = &exposed_unions,
        .exposed_classes  = &exposed_classes,
        .gui_backend      = gui_backend,
        .uses_gui_ptr     = &uses_gui,
        .native_uses      = native_uses,
        .emit_exports     = emit_exports,
        .has_exports_ptr  = &has_exports,
        .source_file      = module.file,
        .imported_modules = imported_modules,
    };
    try g.genModule(module);
    return GenerateResult{ .uses_gui = uses_gui, .has_exports = has_exports };
}

// ── Mixin pre-pass ────────────────────────────────────────────────────────────

fn collectMixins(
    module: Ast.Module,
    alloc:  Allocator,
) !std.StringHashMap(*const Ast.DeclMixin) {
    var map = std.StringHashMap(*const Ast.DeclMixin).init(alloc);
    errdefer map.deinit();
    for (module.decls) |decl| {
        switch (decl) {
            .mixin => |m| try map.put(m.name, m),
            else   => {},
        }
    }
    return map;
}

// ── Union pre-pass ────────────────────────────────────────────────────────────

fn collectUnionNames(module: Ast.Module, alloc: Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    collectUnionNamesInDecls(module.decls, &set) catch {};
    return set;
}

fn collectUnionNamesInDecls(decls: []const Ast.Decl, set: *std.StringHashMap(void)) !void {
    for (decls) |decl| switch (decl) {
        .union_    => |u| try set.put(u.name, {}),
        .namespace => |n| try collectUnionNamesInDecls(n.decls, set),
        .class     => |c| try collectUnionNamesInDecls(c.members, set),
        else       => {},
    };
}

/// Collect a map from union-type name → DeclUnion pointer for same-module
/// union variant construction.  Used by CodeGen to detect `^T` payloads and
/// emit the labeled-block boxing expression instead of a bare value.
fn collectUnionDecls(module: Ast.Module, alloc: Allocator) !std.StringHashMap(*const Ast.DeclUnion) {
    var map = std.StringHashMap(*const Ast.DeclUnion).init(alloc);
    errdefer map.deinit();
    collectUnionDeclsInDecls(module.decls, &map) catch {};
    return map;
}

fn collectUnionDeclsInDecls(decls: []const Ast.Decl, map: *std.StringHashMap(*const Ast.DeclUnion)) !void {
    for (decls) |*decl| switch (decl.*) {
        .union_    => try map.put(decl.union_.name, decl.union_),
        .namespace => |n|  try collectUnionDeclsInDecls(n.decls, map),
        .class     => |c|  try collectUnionDeclsInDecls(c.members, map),
        else       => {},
    };
}

// ── Free helper functions ─────────────────────────────────────────────────────

/// Extract the simple name from a TypeRef, or null for compound forms.
/// Convert a TypeRef to a human-readable string for reflection metadata.
/// Caller owns the returned slice (allocated with `alloc`).
fn typeRefStr(tr: Ast.TypeRef, alloc: Allocator) ![]const u8 {
    return switch (tr) {
        .named       => |n| try alloc.dupe(u8, n.name),
        .nilable     => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "?{s}", .{s});
        },
        .stream      => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "{s}*", .{s});
        },
        .error_union => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "!{s}", .{s});
        },
        .ref_to      => |inner| blk: {
            const s = try typeRefStr(inner.*, alloc);
            defer alloc.free(s);
            break :blk try std.fmt.allocPrint(alloc, "^{s}", .{s});
        },
        .generic     => |g| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            try buf.appendSlice(alloc, g.name);
            try buf.append(alloc, '(');
            for (g.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                const s = try typeRefStr(arg, alloc);
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            }
            try buf.append(alloc, ')');
            break :blk try buf.toOwnedSlice(alloc);
        },
        .void_       => try alloc.dupe(u8, "void"),
        .same        => try alloc.dupe(u8, "same"),
        .tuple       => try alloc.dupe(u8, "tuple"),
    };
}

fn typeRefSimpleName(tr: Ast.TypeRef) ?[]const u8 {
    return switch (tr) {
        .named   => |n| n.name,
        .generic => |g| g.name,
        else     => null,
    };
}

/// Map a Zebra primitive / built-in type name to the Zig equivalent.
/// User-defined type names are returned unchanged.
// Delegate to Builtins — single source of truth for type name mappings.
const zigTypeName     = Builtins.zigTypeName;
const isStringTypeName = Builtins.isStringTypeName;
const zigGenericName  = Builtins.zigGenericName;

fn isStringTypeRef(tr: Ast.TypeRef) bool {
    return tr == .named and isStringTypeName(tr.named.name);
}

fn assignOpStr(op: Ast.AssignOp) []const u8 {
    return switch (op) {
        .assign          => "=",
        .plus_eq         => "+=",
        .minus_eq        => "-=",
        .star_eq         => "*=",
        .slash_eq        => "/=",
        .percent_eq      => "%=",
        .ampersand_eq    => "&=",
        .vertical_bar_eq => "|=",
        .caret_eq        => "^=",
        .double_lt_eq    => "<<=",
        .double_gt_eq    => ">>=",
        // slashslash_eq, starstar_eq, question_eq are handled specially.
        .slashslash_eq, .starstar_eq, .question_eq => "=",
    };
}

fn binaryOpStr(op: Ast.BinaryOp) []const u8 {
    return switch (op) {
        .add     => "+",
        .sub     => "-",
        .mul     => "*",
        .div     => "/",
        .mod     => "%",
        .bit_and => "&",
        .bit_or  => "|",
        .bit_xor => "^",
        .shl     => "<<",
        .shr     => ">>",
        .eq      => "==",
        .ne      => "!=",
        .lt      => "<",
        .le      => "<=",
        .gt      => ">",
        .ge      => ">=",
        .and_    => "and",
        .or_     => "or",
        // int_div, pow, dotdot, in_ handled specially in genBinary.
        .int_div, .pow, .dotdot, .in_ => unreachable,
    };
}

// ── Body reference analysis ───────────────────────────────────────────────────
//
// Three pre-scans are run on each method body before emitting code:
//
//  1. collectRefs    — which params / self are actually referenced?
//                     Used to emit `_ = param;` only when a param is unused.
//
//  2. scanMutations  — which local names appear as assignment targets?
//                     Used to emit `const` vs `var` for local declarations.
//
//  3. analyzeEscapes — which local string variables escape the function (i.e.
//                     reach a `return` statement)?  Used to suppress
//                     `defer _allocator.free(name)` for strings whose ownership
//                     transfers to the caller.  List/HashMap variables do NOT
//                     get individual deinit calls (arena owns all memory), so
//                     this analysis is string-only.  Uses fixed-point propagation
//                     through the alias/depends-on graph.

const Refs = struct {
    /// True if any `ExprIdent` in the body resolves to a `.var_` (field) symbol,
    /// meaning `self` is actually needed.
    uses_self:    bool,
    /// Names of parameters that are actually referenced in the body.
    param_names: std.StringHashMap(void),

    fn deinit(r: *Refs) void { r.param_names.deinit(); }
};

fn collectRefs(
    stmts:   []const Ast.Stmt,
    resolve: *const Resolver.ResolveResult,
    alloc:   Allocator,
) !Refs {
    var out = Refs{ .uses_self = false, .param_names = std.StringHashMap(void).init(alloc) };
    errdefer out.param_names.deinit();
    try refsInStmts(stmts, resolve, &out);
    return out;
}

fn refsInStmts(stmts: []const Ast.Stmt, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    for (stmts) |s| try refsInStmt(s, r, o);
}

fn refsInStmt(stmt: Ast.Stmt, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    switch (stmt) {
        .var_      => |n| { if (n.init) |e| try refsInExpr(e, r, o); },
        .assign    => |s| { try refsInExpr(s.target, r, o); try refsInExpr(s.value, r, o); },
        .return_   => |s| { if (s.value) |v| try refsInExpr(v, r, o); },
        .if_       => |s| {
            try refsInExpr(s.cond, r, o);
            try refsInStmts(s.then_body, r, o);
            for (s.else_ifs) |ei| { try refsInExpr(ei.cond, r, o); try refsInStmts(ei.body, r, o); }
            if (s.else_body) |eb| try refsInStmts(eb, r, o);
        },
        .while_    => |s| {
            if (s.bind) |bind| try refsInExpr(bind.init, r, o);
            try refsInExpr(s.cond, r, o);
            try refsInStmts(s.body, r, o);
            if (s.post_body) |pb| try refsInStmts(pb, r, o);
        },
        .for_in    => |s| { try refsInExpr(s.iter, r, o); if (s.where) |w| try refsInExpr(w, r, o); try refsInStmts(s.body, r, o); },
        .for_num   => |s| { try refsInExpr(s.start, r, o); try refsInExpr(s.stop, r, o); if (s.step) |st| try refsInExpr(st, r, o); try refsInStmts(s.body, r, o); },
        .branch    => |s| {
            try refsInExpr(s.expr, r, o);
            for (s.on) |on| { for (on.values) |v| try refsInExpr(v, r, o); try refsInStmts(on.body, r, o); }
            if (s.else_) |eb| try refsInStmts(eb, r, o);
        },
        .print     => |s| { for (s.args) |a|    try refsInExpr(a, r, o); },
        .assert    => |s| { try refsInExpr(s.cond, r, o); if (s.message) |m| try refsInExpr(m, r, o); },
        .yield     => |s| try refsInExpr(s.value, r, o),
        .expr      => |e| try refsInExpr(e, r, o),
        .defer_    => |s| try refsInStmt(s.body, r, o),
        .contract  => |s| { for (s.exprs) |e| try refsInExpr(e, r, o); },
        .with        => |s| { try refsInExpr(s.target, r, o); try refsInStmts(s.body, r, o); },
        .arena_scope => |s| try refsInStmts(s.body, r, o),
        .var_except    => |s| { try refsInExpr(s.base, r, o); for (s.fields) |f| try refsInExpr(f.value, r, o); },
        .assign_except => |s| { try refsInExpr(s.target, r, o); try refsInExpr(s.base, r, o); for (s.fields) |f| try refsInExpr(f.value, r, o); },
        .raise    => |s| { if (s.message) |m| try refsInExpr(m, r, o); if (s.details) |d| try refsInExpr(d, r, o); },
        .try_catch => |s| { try refsInStmts(s.body, r, o); for (s.clauses) |cl| try refsInStmts(cl.body, r, o); },
        .guard => |s| { try refsInExpr(s.cond, r, o); try refsInStmts(s.else_body, r, o); },
        .destruct => |s| try refsInExpr(s.init, r, o),
        .pass, .break_, .continue_ => {},
    }
}

/// Returns true if the method body contains a `raise` statement or a bare
/// `try expr` (i.e., one not wrapped in a `try/catch` block).  Used to
/// auto-emit `anyerror!` for methods that lack a `throws` annotation.
/// Best-effort type name for `raise` details expression.
/// Used to generate the per-type heap-alloc and shim.
/// Falls back to "anyopaque" if the expression is too complex to name.
fn detailsTypeName(expr: *const Ast.Expr) []const u8 {
    return switch (expr.*) {
        .ident  => |e| e.name,
        .call   => |e| switch (e.callee.*) {
            .ident  => |i| i.name,
            .member => |m| switch (m.object.*) {
                .ident => |i| i.name,   // ClassName.init(...) → "ClassName"
                else   => "anyopaque",
            },
            else    => "anyopaque",
        },
        else    => "anyopaque",
    };
}

fn bodyHasRaise(stmts: []const Ast.Stmt, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise   => return true,
            .var_    => |n| { if (n.init) |e| if (exprHasTry(e, tc_opt)) return true; },
            .assign  => |s| { if (exprHasTry(s.value, tc_opt)) return true; },
            .return_ => |s| { if (s.value) |v| if (exprHasTry(v, tc_opt)) return true; },
            .expr    => |e| if (exprHasTry(e, tc_opt)) return true,
            .print   => |s| { for (s.args) |a| if (exprHasTry(a, tc_opt)) return true; },
            .if_     => |s| {
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyHasRaise(s.then_body, tc_opt)) return true;
                for (s.else_ifs) |ei| {
                    if (exprHasTry(ei.cond, tc_opt)) return true;
                    if (bodyHasRaise(ei.body, tc_opt)) return true;
                }
                if (s.else_body) |eb| if (bodyHasRaise(eb, tc_opt)) return true;
            },
            .while_  => |s| {
                if (s.bind) |bind| if (exprHasTry(bind.init, tc_opt)) return true;
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyHasRaise(s.body, tc_opt)) return true;
            },
            .for_in  => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .for_num => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .branch  => |s| {
                for (s.on) |on| if (bodyHasRaise(on.body, tc_opt)) return true;
                if (s.else_) |eb| if (bodyHasRaise(eb, tc_opt)) return true;
            },
            .with        => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .arena_scope => |s| if (bodyHasRaise(s.body, tc_opt)) return true,
            .defer_  => |s| return bodyHasRaise(&.{s.body}, tc_opt),
            .guard   => |s| { if (exprHasTry(s.cond, tc_opt)) return true; if (bodyHasRaise(s.else_body, tc_opt)) return true; },
            .try_catch => {}, // try/catch absorbs raises — don't propagate
            .destruct => {},
            else => {},
        }
    }
    return false;
}

/// Returns true if the try block needs a mutable `_try_err` variable — i.e., when
/// the body contains either a `raise` statement or a `try expr` expression (both of
/// which route errors through the tracking variable).
/// Does not recurse into nested try/catch — inner blocks have their own variables.
fn bodyNeedsErrVar(stmts: []const Ast.Stmt, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise   => return true,
            .var_    => |n| { if (n.init) |e| if (exprHasTry(e, tc_opt)) return true; },
            .assign  => |s| { if (exprHasTry(s.value, tc_opt)) return true; },
            .return_ => |s| { if (s.value) |v| if (exprHasTry(v, tc_opt)) return true; },
            .expr    => |e| if (exprHasTry(e, tc_opt)) return true,
            .print   => |s| { for (s.args) |a| if (exprHasTry(a, tc_opt)) return true; },
            .if_     => |s| {
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyNeedsErrVar(s.then_body, tc_opt)) return true;
                for (s.else_ifs) |ei| {
                    if (exprHasTry(ei.cond, tc_opt)) return true;
                    if (bodyNeedsErrVar(ei.body, tc_opt)) return true;
                }
                if (s.else_body) |eb| if (bodyNeedsErrVar(eb, tc_opt)) return true;
            },
            .while_  => |s| {
                if (s.bind) |bind| if (exprHasTry(bind.init, tc_opt)) return true;
                if (exprHasTry(s.cond, tc_opt)) return true;
                if (bodyNeedsErrVar(s.body, tc_opt)) return true;
            },
            .for_in  => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .for_num => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .branch  => |s| {
                for (s.on) |on| if (bodyNeedsErrVar(on.body, tc_opt)) return true;
                if (s.else_) |eb| if (bodyNeedsErrVar(eb, tc_opt)) return true;
            },
            .with        => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .arena_scope => |s| if (bodyNeedsErrVar(s.body, tc_opt)) return true,
            .defer_  => |s| return bodyNeedsErrVar(&.{s.body}, tc_opt),
            .guard   => |s| { if (exprHasTry(s.cond, tc_opt)) return true; if (bodyNeedsErrVar(s.else_body, tc_opt)) return true; },
            .try_catch => {}, // inner try has its own err variable
            .destruct => {},
            else => {},
        }
    }
    return false;
}

/// Returns true if `e` is a call to a `throws`-annotated method
/// (ClassName.methodName(args) form only, including cross-module Module.method calls).
fn exprCallIsThrows(
    e:                *const Ast.ExprCall,
    resolve:          *const Resolver.ResolveResult,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
    owner_members:    []const Ast.Decl,
) bool {
    if (e.callee.* != .member) return false;
    const mem = e.callee.member;
    // `.method()` syntax: callee is `this.method_name` — walk owner members.
    if (mem.object.* == .this) {
        for (owner_members) |decl| {
            if (decl == .method) {
                const m = decl.method;
                if (std.mem.eql(u8, m.name, mem.member)) return m.throws;
            }
        }
        return false;
    }
    if (mem.object.* != .ident) return false;
    const sym = resolve.exprs.get(&mem.object.ident) orelse return false;
    // Cross-module call: receiver is a `.module` symbol (from `use ModuleName`).
    if (sym.kind == .module) {
        if (imported_modules) |imp| {
            if (imp.get(sym.name)) |iface| {
                // Key format: "ClassName.methodName" — for a sole-class module the
                // class name equals the module alias.
                // Try both "Alias.method" and "Alias.Alias.method" forms.
                if (iface.throws_methods.contains(mem.member)) return true;
                const key_buf: [256]u8 = undefined;
                _ = key_buf;
                // Build "ModAlias.method" key.
                var buf: [512]u8 = undefined;
                const k1 = std.fmt.bufPrint(&buf, "{s}.{s}", .{ sym.name, mem.member }) catch return false;
                if (iface.throws_methods.contains(k1)) return true;
            }
        }
        return false;
    }
    // Same-file class/struct call.
    const members: []const Ast.Decl = switch (sym.decl) {
        .class   => |c| c.members,
        .struct_ => |s| s.members,
        else     => return false,
    };
    for (members) |m| {
        switch (m) {
            .method => |md| if (std.mem.eql(u8, md.name, mem.member)) return md.throws,
            else    => {},
        }
    }
    return false;
}

/// Returns true if any statement in `stmts` is a direct call to a `throws` method.
fn bodyHasThrowsCall(
    stmts:            []const Ast.Stmt,
    resolve:          *const Resolver.ResolveResult,
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface),
    owner_members:    []const Ast.Decl,
) bool {
    for (stmts) |stmt| {
        if (stmt == .expr and stmt.expr.* == .call) {
            if (exprCallIsThrows(stmt.expr.call, resolve, imported_modules, owner_members)) return true;
        }
        // Var init that's a throws call also counts (affects try-block var tracking).
        if (stmt == .var_ and stmt.var_.init != null and stmt.var_.init.?.* == .call) {
            if (exprCallIsThrows(stmt.var_.init.?.call, resolve, imported_modules, owner_members)) return true;
        }
    }
    return false;
}

fn exprHasTry(expr: *const Ast.Expr, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
    return switch (expr.*) {
        .try_ => |_| blk: {
            // TC records optional-unwrap `.try_` nodes in `optional_unwraps` by
            // checking the inner ident's DECLARED type (pre nil-narrowing).
            // Only count this as a real error propagation if it's NOT an opt-unwrap.
            if (tc_opt) |tc| {
                if (tc.optional_unwraps.contains(expr)) break :blk false;
            }
            break :blk true;
        },
        .binary => |e| exprHasTry(e.left, tc_opt) or exprHasTry(e.right, tc_opt),
        .unary  => |e| exprHasTry(e.operand, tc_opt),
        .call   => |e| blk: {
            if (exprHasTry(e.callee, tc_opt)) break :blk true;
            for (e.args) |a| if (exprHasTry(a.value, tc_opt)) break :blk true;
            break :blk false;
        },
        .member    => |e| exprHasTry(e.object, tc_opt),
        .orelse_   => |e| exprHasTry(e.expr, tc_opt) or exprHasTry(e.fallback, tc_opt),
        .catch_    => |e| exprHasTry(e.expr, tc_opt) or exprHasTry(e.fallback, tc_opt),
        .to_non_nil => |e| exprHasTry(e.expr, tc_opt),
        .to_nilable => |e| exprHasTry(e.expr, tc_opt),
        .is_nil    => |e| exprHasTry(e.expr, tc_opt),
        else => false,
    };
}

fn refsInExpr(expr: *const Ast.Expr, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    switch (expr.*) {
        .ident => |*e| {
            if (r.exprs.get(e)) |sym| switch (sym.kind) {
                .var_    => o.uses_self = true,
                // Unqualified instance method call within the same class → emitted as
                // self.method() in Zig, so self IS needed.
                // Exception: top-level `def` (LANG-001) are called without self, so
                // referencing them does NOT imply self is used.
                .method  => {
                    const is_top = switch (sym.decl) {
                        .method => |m| m.is_top_level,
                        else    => false,
                    };
                    if (!is_top) o.uses_self = true;
                },
                .param   => try o.param_names.put(e.name, {}),
                else     => {},
            };
        },
        .binary      => |e| { try refsInExpr(e.left, r, o);    try refsInExpr(e.right, r, o); },
        .unary       => |e| try refsInExpr(e.operand, r, o),
        .call        => |e| { try refsInExpr(e.callee, r, o);  for (e.args) |a| try refsInExpr(a.value, r, o); },
        .member      => |e| try refsInExpr(e.object, r, o),
        .index       => |e| { try refsInExpr(e.object, r, o);  try refsInExpr(e.index, r, o); },
        .slice       => |e| { try refsInExpr(e.object, r, o);  if (e.start) |s| try refsInExpr(s, r, o); if (e.stop) |s| try refsInExpr(s, r, o); },
        .if_expr     => |e| { try refsInExpr(e.cond, r, o);    try refsInExpr(e.then_expr, r, o); try refsInExpr(e.else_expr, r, o); },
        .orelse_     => |e| { try refsInExpr(e.expr, r, o);    try refsInExpr(e.fallback, r, o); },
        .catch_      => |e| { try refsInExpr(e.expr, r, o);    try refsInExpr(e.fallback, r, o); },
        .to_nilable  => |e| try refsInExpr(e.expr, r, o),
        .to_non_nil  => |e| try refsInExpr(e.expr, r, o),
        .is_nil      => |e| try refsInExpr(e.expr, r, o),
        .cast        => |e| try refsInExpr(e.expr, r, o),
        .old         => |e| try refsInExpr(e.expr, r, o),
        .list_lit    => |e| { for (e.elems) |el| try refsInExpr(el, r, o); },
        .array_lit   => |e| { for (e.elems) |el| try refsInExpr(el, r, o); },
        .dict_lit    => |e| { for (e.entries) |en| { try refsInExpr(en.key, r, o); try refsInExpr(en.value, r, o); } },
        .string_interp => |e| { for (e.parts) |p| switch (p) { .expr => |ex| try refsInExpr(ex, r, o), else => {} }; },
        .all_any     => |e| { try refsInExpr(e.iter, r, o); try refsInExpr(e.cond, r, o); },
        .lambda      => |e| switch (e.body) {
            .expr  => |ex| try refsInExpr(ex, r, o),
            .stmts => |ss| try refsInStmts(ss, r, o),
        },
        .try_        => |e| try refsInExpr(e.expr, r, o),
        .tuple_lit   => |e| { for (e.elems) |el| try refsInExpr(el, r, o); },
        .type_check  => |e| try refsInExpr(e.expr, r, o),
        .this        => o.uses_self = true,  // extension methods: `this` means self is used
        .int_lit, .float_lit, .bool_lit, .char_lit,
        .string_lit, .nil, .zig_lit => {},
    }
}

// ── Mutation analysis ─────────────────────────────────────────────────────────

/// Return a set of every identifier name that appears as the direct target of
/// an assignment (`ident = value`, as opposed to `obj.member = value`) inside
/// `stmts` or any nested control-flow body.
///
/// Used by the CodeGen to emit `const` for locals that are never reassigned,
/// avoiding Zig's "local variable is never mutated" compile error.
/// Collect the names of every local variable that is directly returned (either as
/// the sole return value or as an argument to a call in a return expression).
/// These variables must NOT receive a `defer _allocator.free` because the caller
/// takes ownership of the allocation.
// ── Escape analysis ───────────────────────────────────────────────────────────

/// Exhaustively collect all ExprIdent names reachable within `expr` into `set`.
/// Used both to seed the initial escape set from return expressions and to compute
/// the "depends-on" set for each var initialiser.
fn collectAllIdents(expr: *const Ast.Expr, set: *std.StringHashMap(void)) anyerror!void {
    switch (expr.*) {
        .ident         => |e|  try set.put(e.name, {}),
        .call          => |e|  {
            if (e.callee.* == .member)     try collectAllIdents(e.callee.member.object, set)
            else if (e.callee.* == .ident) try set.put(e.callee.ident.name, {});
            for (e.args) |a| try collectAllIdents(a.value, set);
        },
        .member        => |m|  try collectAllIdents(m.object, set),
        .binary        => |b|  { try collectAllIdents(b.left, set); try collectAllIdents(b.right, set); },
        .unary         => |u|  try collectAllIdents(u.operand, set),
        .to_nilable    => |u|  try collectAllIdents(u.expr, set),
        .to_non_nil    => |u|  try collectAllIdents(u.expr, set),
        .is_nil        => |u|  try collectAllIdents(u.expr, set),
        .orelse_       => |o|  { try collectAllIdents(o.expr, set); try collectAllIdents(o.fallback, set); },
        .catch_        => |c|  { try collectAllIdents(c.expr, set); try collectAllIdents(c.fallback, set); },
        .if_expr       => |i|  { try collectAllIdents(i.cond, set); try collectAllIdents(i.then_expr, set); try collectAllIdents(i.else_expr, set); },
        .cast          => |c|  try collectAllIdents(c.expr, set),
        .old           => |o|  try collectAllIdents(o.expr, set),
        .try_          => |t|  try collectAllIdents(t.expr, set),
        .index         => |i|  { try collectAllIdents(i.object, set); try collectAllIdents(i.index, set); },
        .slice         => |s|  { try collectAllIdents(s.object, set);
                                  if (s.start) |b| try collectAllIdents(b, set);
                                  if (s.stop)  |b| try collectAllIdents(b, set); },
        .tuple_lit     => |t|  { for (t.elems)    |e| try collectAllIdents(e, set); },
        .type_check    => |t|  try collectAllIdents(t.expr, set),
        .list_lit      => |l|  { for (l.elems)    |e| try collectAllIdents(e, set); },
        .array_lit     => |a|  { for (a.elems)    |e| try collectAllIdents(e, set); },
        .dict_lit      => |d|  { for (d.entries) |e| { try collectAllIdents(e.key, set); try collectAllIdents(e.value, set); } },
        .all_any       => |a|  { try collectAllIdents(a.iter, set); try collectAllIdents(a.cond, set); },
        .string_interp => |si| { for (si.parts) |p| { switch (p) { .expr => |e| try collectAllIdents(e, set), else => {} } } },
        else           => {},  // literals, nil, this, zig_lit — no idents
    }
}

/// Recursively add all ExprIdent names appearing in any `return` expression to `set`.
fn seedEscapedFromReturns(stmts: []const Ast.Stmt, set: *std.StringHashMap(void)) anyerror!void {
    for (stmts) |stmt| {
        switch (stmt) {
            .return_   => |s| if (s.value) |v| try collectAllIdents(v, set),
            .if_       => |s| {
                try seedEscapedFromReturns(s.then_body, set);
                for (s.else_ifs) |ei| try seedEscapedFromReturns(ei.body, set);
                if (s.else_body) |eb| try seedEscapedFromReturns(eb, set);
            },
            .while_    => |s| { try seedEscapedFromReturns(s.body, set); if (s.post_body) |pb| try seedEscapedFromReturns(pb, set); },
            .for_in    => |s| try seedEscapedFromReturns(s.body, set),
            .for_num   => |s| try seedEscapedFromReturns(s.body, set),
            .branch    => |s| {
                for (s.on) |on| try seedEscapedFromReturns(on.body, set);
                if (s.else_) |eb| try seedEscapedFromReturns(eb, set);
            },
            .with        => |s| try seedEscapedFromReturns(s.body, set),
            .arena_scope => |s| try seedEscapedFromReturns(s.body, set),
            .try_catch => |s| {
                try seedEscapedFromReturns(s.body, set);
                for (s.clauses) |cl| try seedEscapedFromReturns(cl.body, set);
            },
            .guard     => |s| try seedEscapedFromReturns(s.else_body, set),
            else       => {},
        }
    }
}

/// One propagation pass over var decls and field-write assigns:
///
///   • `var y = <expr>` — if `y` is escaped, add all idents in <expr> to the
///     escaped set (y's string buffer may have come from those idents).
///   • `obj.field = <expr>` — if `obj` is escaped, add all idents in <expr> to
///     the escaped set.  Without this, code like:
///       var s = str.format(x); result.msg = s; return result
///     would incorrectly emit `defer _allocator.free(s)` while `result.msg`
///     still references the freed slice.
///
/// Returns true if the set grew (caller loops until stable).
fn propagateEscapesOnce(stmts: []const Ast.Stmt, set: *std.StringHashMap(void)) anyerror!bool {
    var grew = false;
    for (stmts) |stmt| {
        switch (stmt) {
            .var_ => |n| if (n.init) |e| {
                if (set.contains(n.name)) {
                    const before = set.count();
                    try collectAllIdents(e, set);
                    if (set.count() > before) grew = true;
                }
            },
            // Field write: `escaped_obj.field = rhs` — rhs values may embed
            // into escaped_obj so they should not be freed before the caller.
            .assign => |s| if (s.target.* == .member) {
                const m = s.target.member;
                if (m.object.* == .ident and set.contains(m.object.ident.name)) {
                    const before = set.count();
                    try collectAllIdents(s.value, set);
                    if (set.count() > before) grew = true;
                }
            },
            .if_ => |s| {
                if (try propagateEscapesOnce(s.then_body, set)) grew = true;
                for (s.else_ifs) |ei| { if (try propagateEscapesOnce(ei.body, set)) grew = true; }
                if (s.else_body) |eb| { if (try propagateEscapesOnce(eb, set)) grew = true; }
            },
            .while_    => |s| {
                if (try propagateEscapesOnce(s.body, set)) grew = true;
                if (s.post_body) |pb| { if (try propagateEscapesOnce(pb, set)) grew = true; }
            },
            .for_in    => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .for_num   => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .branch    => |s| {
                for (s.on) |on| { if (try propagateEscapesOnce(on.body, set)) grew = true; }
                if (s.else_) |eb| { if (try propagateEscapesOnce(eb, set)) grew = true; }
            },
            .with        => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .arena_scope => |s| { if (try propagateEscapesOnce(s.body, set)) grew = true; },
            .try_catch => |s| {
                if (try propagateEscapesOnce(s.body, set)) grew = true;
                for (s.clauses) |cl| { if (try propagateEscapesOnce(cl.body, set)) grew = true; }
            },
            .guard     => |s| { if (try propagateEscapesOnce(s.else_body, set)) grew = true; },
            else       => {},
        }
    }
    return grew;
}

/// Compute the set of local *string* variable names whose heap-owned values
/// escape this function body.  A variable escapes if its value (or the value of
/// any variable initialised from it) reaches a `return` statement.
///
/// Purpose: suppresses `defer _allocator.free(name)` for strings whose slice
/// ownership transfers to the caller.  List/HashMap variables are NOT covered
/// here — they no longer receive individual deinit calls at all (the arena
/// allocator owns all collection memory and frees it at program exit).
///
/// Conservative: over-escaping (marking a variable escaped when it isn't)
/// causes a memory leak, never a use-after-free.  Under-escaping causes UAF.
fn analyzeEscapes(stmts: []const Ast.Stmt, alloc: Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    // Phase 1 — seed from all return expressions.
    try seedEscapedFromReturns(stmts, &set);
    // Phase 2 — fixed-point propagation through the depends-on graph.
    while (try propagateEscapesOnce(stmts, &set)) {}
    return set;
}

fn scanMutations(
    stmts:  []const Ast.Stmt,
    alloc:  Allocator,
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    try scanMutationsInto(stmts, &set, tc_opt);
    return set;
}

fn scanMutationsInto(
    stmts:  []const Ast.Stmt,
    set:    *std.StringHashMap(void),
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .assign  => |s| switch (s.target.*) {
                // Bare `name = value` — marks `name` as mutated.
                .ident => |e| try set.put(e.name, {}),
                // `obj.member = value` — the object needs to be `var` in Zig.
                .member => |m| if (m.object.* == .ident) try set.put(m.object.ident.name, {}),
                else   => {},
            },
            .if_     => |s| {
                try scanMutationsInto(s.then_body, set, tc_opt);
                for (s.else_ifs) |ei| try scanMutationsInto(ei.body, set, tc_opt);
                if (s.else_body) |eb| try scanMutationsInto(eb, set, tc_opt);
            },
            .while_  => |s| {
                if (s.bind) |bind| try scanMutationsInExpr(bind.init, set, tc_opt);
                try scanMutationsInto(s.body, set, tc_opt);
                if (s.post_body) |pb| try scanMutationsInto(pb, set, tc_opt);
            },
            .for_in  => |s| try scanMutationsInto(s.body, set, tc_opt),
            .for_num => |s| try scanMutationsInto(s.body, set, tc_opt),
            .branch  => |s| {
                for (s.on) |on| try scanMutationsInto(on.body, set, tc_opt);
                if (s.else_) |eb| try scanMutationsInto(eb, set, tc_opt);
            },
            // Scan expressions in remaining statement kinds for call-receivers.
            .var_    => |n| { if (n.init) |e| try scanMutationsInExpr(e, set, tc_opt); },
            .return_ => |s| { if (s.value) |v| try scanMutationsInExpr(v, set, tc_opt); },
            .expr    => |e| try scanMutationsInExpr(e, set, tc_opt),
            .print   => |s| { for (s.args) |a| try scanMutationsInExpr(a, set, tc_opt); },
            // `with target` — the target variable is mutated (fields are assigned).
            .with    => |s| {
                if (s.target.* == .ident) try set.put(s.target.ident.name, {});
                try scanMutationsInto(s.body, set, tc_opt);
            },
            .arena_scope => |s| try scanMutationsInto(s.body, set, tc_opt),
            .try_catch => |s| {
                try scanMutationsInto(s.body, set, tc_opt);
                for (s.clauses) |cl| try scanMutationsInto(cl.body, set, tc_opt);
            },
            .guard    => |s| try scanMutationsInto(s.else_body, set, tc_opt),
            .destruct => |s| try scanMutationsInExpr(s.init, set, tc_opt),
            .assert   => |s| try scanMutationsInExpr(s.cond, set, tc_opt),
            else      => {},
        }
    }
}

/// Mark local variables whose values are modified in-place as "mutated" (→ emit
/// `var` rather than `const`).
///
/// Previous approach: a large `non_mutating` *deny-list* — any method not on the
/// list was assumed mutating.  Problem: every new stdlib method defaulted to
/// "mutating" until manually added, causing spurious `var` declarations and Zig
/// "local variable is never mutated" errors.
///
/// New approach: a small `mutating_methods` *allow-list* — only methods that
/// actually modify the receiver's internal state are listed.  Default is
/// non-mutating.  For user-defined types (TC type `.named`) we conservatively
/// always mark as mutating because we cannot inspect the method body.
fn scanMutationsInExpr(
    expr:   *const Ast.Expr,
    set:    *std.StringHashMap(void),
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) anyerror!void {
    switch (expr.*) {
        .call => |e| {
            if (e.callee.* == .member) {
                const obj    = e.callee.member.object;
                const method = e.callee.member.member;

                // Methods that modify the receiver's internal state in-place.
                // Everything else defaults to non-mutating.
                const mutating_methods = std.StaticStringMap(void).initComptime(&.{
                    // List — in-place mutations
                    .{ "add",            {} }, .{ "remove",        {} },
                    .{ "clear",          {} }, .{ "sort",          {} },
                    .{ "sortBy",         {} }, .{ "reverse",       {} },
                    // HashMap — in-place mutations
                    .{ "set",            {} },
                    // StringBuilder — all write methods
                    .{ "append",         {} }, .{ "appendLine",    {} },
                    .{ "appendChar",     {} }, .{ "appendInt",     {} },
                    .{ "appendFloat",    {} }, .{ "appendBool",    {} },
                    // JsonValue — mutating builders
                    .{ "put",            {} }, .{ "putInt",        {} },
                    .{ "putFloat",       {} }, .{ "putBool",       {} },
                    // CsvWriter — write
                    .{ "writeRow",       {} },
                });

                if (obj.* == .ident) {
                    // Extension methods are pass-by-value — never mutate the receiver.
                    const is_ext = blk: {
                        if (tc_opt) |tc| {
                            const obj_type = tc.expr_types.get(obj) orelse .unknown;
                            const tname: ?[]const u8 = switch (obj_type) {
                                .string         => "String",
                                .int            => "int",
                                .uint           => "uint",
                                .float          => "float",
                                .bool           => "bool",
                                .char           => "char",
                                .string_builder => "StringBuilder",
                                .named          => |sym| switch (sym.decl) {
                                    .class     => |c| c.name,
                                    .struct_   => |s| s.name,
                                    .interface => |i| i.name,
                                    else       => null,
                                },
                                else => null,
                            };
                            if (tname) |tn| {
                                var buf: [256]u8 = undefined;
                                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, method})) |key| {
                                    if (tc.ext_methods.get(key) != null) break :blk true;
                                } else |_| {}
                            }
                        }
                        break :blk false;
                    };

                    if (!is_ext) {
                        // Determine if this call needs the receiver to be `var`.
                        const needs_var: bool = blk: {
                            if (tc_opt) |tc| {
                                const obj_type = tc.expr_types.get(obj) orelse .unknown;
                                // User-defined class or cross-module instance: conservative —
                                // methods take *self, so ANY call may mutate the receiver.
                                if (obj_type == .named or obj_type == .generic_named or
                                    obj_type == .cross_module) break :blk true;
                                // Strings are immutable values in Zebra — no method
                                // mutates a string in-place.  `reverse` is in the
                                // allow-list for List (which is in-place), but
                                // str.reverse() always returns a new allocation.
                                if (obj_type == .string) break :blk false;
                                // `.unknown` falls through to the allow-list below.
                                // Previously we treated unknown as always-mutating, which
                                // caused spurious `var` for stdlib builtins (sys.args(),
                                // str methods, etc.) whose idents aren't registered in
                                // resolve.exprs, making TC return .unknown for them.
                                // User-class instances resolve as .named, so the
                                // conservative path above still fires for them.
                            }
                            // Stdlib / unknown type: only explicitly-listed mutating methods.
                            break :blk mutating_methods.get(method) != null;
                        };
                        if (needs_var) try set.put(obj.ident.name, {});
                    }
                }
            }
            for (e.args) |a| try scanMutationsInExpr(a.value, set, tc_opt);
        },
        .binary    => |e| { try scanMutationsInExpr(e.left, set, tc_opt); try scanMutationsInExpr(e.right, set, tc_opt); },
        .unary     => |e| try scanMutationsInExpr(e.operand, set, tc_opt),
        .member    => |e| try scanMutationsInExpr(e.object, set, tc_opt),
        .index     => |e| { try scanMutationsInExpr(e.object, set, tc_opt); try scanMutationsInExpr(e.index, set, tc_opt); },
        .if_expr   => |e| { try scanMutationsInExpr(e.cond, set, tc_opt); try scanMutationsInExpr(e.then_expr, set, tc_opt); try scanMutationsInExpr(e.else_expr, set, tc_opt); },
        .orelse_   => |e| { try scanMutationsInExpr(e.expr, set, tc_opt); try scanMutationsInExpr(e.fallback, set, tc_opt); },
        .catch_    => |e| { try scanMutationsInExpr(e.expr, set, tc_opt); try scanMutationsInExpr(e.fallback, set, tc_opt); },
        .tuple_lit  => |e| { for (e.elems) |el| try scanMutationsInExpr(el, set, tc_opt); },
        .type_check => |e| try scanMutationsInExpr(e.expr, set, tc_opt),
        // `expr?` — recurse so that `localVar.method()?` marks `localVar` as mutated.
        .try_       => |e| try scanMutationsInExpr(e.expr, set, tc_opt),
        else        => {},
    }
}

/// True if `name` appears as an identifier anywhere in `stmts`.
/// Returns the variable name being nil-checked in `x != nil` (for_then=true) or `x == nil` (for_then=false).
fn nilNarrowVar(cond: *const Ast.Expr, for_then: bool) ?[]const u8 {
    if (cond.* != .binary) return null;
    const b = cond.binary;
    const want: Ast.BinaryOp = if (for_then) .ne else .eq;
    if (b.op != want) return null;
    if (b.left.* == .ident and b.right.* == .nil) return b.left.ident.name;
    if (b.right.* == .ident and b.left.* == .nil) return b.right.ident.name;
    return null;
}

fn nameUsedInStmts(name: []const u8, stmts: []const Ast.Stmt) bool {
    for (stmts) |s| if (nameUsedInStmt(name, s)) return true;
    return false;
}
fn nameUsedInStmt(name: []const u8, stmt: Ast.Stmt) bool {
    return switch (stmt) {
        .var_    => |n| { if (n.init) |e| return nameUsedInExpr(name, e); return false; },
        .assign  => |s| nameUsedInExpr(name, s.target) or nameUsedInExpr(name, s.value),
        .return_ => |s| if (s.value) |v| nameUsedInExpr(name, v) else false,
        .print   => |s| blk: { for (s.args) |a| if (nameUsedInExpr(name, a)) break :blk true; break :blk false; },
        .expr    => |e| nameUsedInExpr(name, e),
        .if_     => |s| blk: {
            if (nameUsedInExpr(name, s.cond)) break :blk true;
            if (nameUsedInStmts(name, s.then_body)) break :blk true;
            for (s.else_ifs) |ei| if (nameUsedInExpr(name, ei.cond) or nameUsedInStmts(name, ei.body)) break :blk true;
            if (s.else_body) |eb| if (nameUsedInStmts(name, eb)) break :blk true;
            break :blk false;
        },
        .while_  => |s| blk: {
            if (s.bind) |bind| if (nameUsedInExpr(name, bind.init)) break :blk true;
            break :blk nameUsedInExpr(name, s.cond) or nameUsedInStmts(name, s.body);
        },
        .for_in  => |s| nameUsedInExpr(name, s.iter) or nameUsedInStmts(name, s.body),
        .for_num => |s| nameUsedInExpr(name, s.start) or nameUsedInExpr(name, s.stop) or nameUsedInStmts(name, s.body),
        .guard       => |s| nameUsedInExpr(name, s.cond) or nameUsedInStmts(name, s.else_body),
        .destruct    => |s| nameUsedInExpr(name, s.init),
        .arena_scope => |s| nameUsedInStmts(name, s.body),
        else         => false,
    };
}
fn nameUsedInExpr(name: []const u8, expr: *const Ast.Expr) bool {
    return switch (expr.*) {
        .ident     => |e| std.mem.eql(u8, e.name, name),
        .call      => |e| nameUsedInExpr(name, e.callee) or blk: {
            for (e.args) |a| if (nameUsedInExpr(name, a.value)) break :blk true;
            break :blk false;
        },
        .member    => |e| nameUsedInExpr(name, e.object),
        .binary    => |e| nameUsedInExpr(name, e.left) or nameUsedInExpr(name, e.right),
        .unary     => |e| nameUsedInExpr(name, e.operand),
        .index     => |e| nameUsedInExpr(name, e.object) or nameUsedInExpr(name, e.index),
        .tuple_lit => |e| blk: {
            for (e.elems) |el| if (nameUsedInExpr(name, el)) break :blk true;
            break :blk false;
        },
        else       => false,
    };
}

// ── Generator ─────────────────────────────────────────────────────────────────

const Generator = struct {
    resolve:   *const Resolver.ResolveResult,
    /// Pass-3 type map.  Null when called from tests that don't run TypeChecker.
    tc:        ?*const TypeChecker.TypeCheckResult,
    /// Output writer.  `AnyWriter` is a fat pointer; copying it is cheap and
    /// both copies still target the same underlying output stream.
    w:         std.io.AnyWriter,
    /// Current indentation depth (4 spaces per level).
    indent:    u32,
    /// Name of the enclosing type (class / struct / enum / mixin).
    /// Empty string when at module scope.
    owner:     []const u8,
    /// True when generating the body of a method, property accessor, or
    /// constructor.  Enables `self.` prefix injection for field identifiers.
    in_method: bool,
    /// All mixin declarations in the module, keyed by name.
    mixins:    *const std.StringHashMap(*const Ast.DeclMixin),
    /// Allocator used for per-method mutation analysis.
    alloc:     Allocator,
    /// Names of local variables that are assigned to somewhere in the current
    /// method body.  Null at module scope.  Used to emit `const` vs `var`.
    mutated:   ?*const std.StringHashMap(void),
    /// Names of locals that are lambdas with capture blocks (struct-instance
    /// closures).  Call sites emit `name.call(args)` instead of `name(args)`.
    /// Populated lazily as `genLocalVar` processes capture-lambda var decls.
    closure_vars: ?*std.StringHashMap(void),
    /// Variable names that are known to be std.ArrayList at runtime, introduced
    /// by `for k, v in HashMap(K, List(T))` loops.  `genForIn` checks this so
    /// that `for elem in v` emits `for (v.items)` instead of `for (v)`.
    list_loop_vars: ?*const std.StringHashMap(void) = null,
    /// Capture field names in scope when generating a lambda body that has a
    /// `capture` block.  Ident refs to these names become `self.name`.
    capture_fields: []const []const u8,
    /// Names of all union types declared in the current module.
    /// Used to detect union construction calls: `Type.variant(value)`.
    union_names: *const std.StringHashMap(void),
    /// DeclUnion pointers for all union types declared in the current module.
    /// Used to check whether a variant's payload is `^T` so the construction
    /// expression can emit a labeled-block boxing expression.
    union_decls: *const std.StringHashMap(*const Ast.DeclUnion),
    /// Union type names introduced by selective imports (`use Mod exposing UnionName`).
    /// Maps exposed name → module alias so boxing info can be fetched from ModuleInterface.
    /// Populated lazily by `genUse`; allows `UnionName.variant(v)` → `UnionName{ .variant = v }`.
    exposed_unions: *std.StringHashMap([]const u8),
    /// Class/struct names introduced by selective imports (`use Mod exposing ClassName`).
    /// Populated lazily by `genUse` when the exposed name is a class (non-union) type.
    /// Allows `ClassName(args)` → `ClassName.init(args)` without a class symbol lookup.
    exposed_classes: *std.StringHashMap(void),
    /// When non-null, we are inside a `try` block.  `raise` breaks the labeled
    /// block (name = try_block_label) and records the error into this variable
    /// instead of returning from the enclosing method.
    try_block_label: ?[]const u8 = null,
    /// Name of the `?anyerror` variable that records the error in the current
    /// try block.  Always set together with `try_block_label`.
    try_err_var: ?[]const u8 = null,
    /// Name of the catch clause binding variable (e.g. "e" in `catch e`).
    /// Non-empty only when generating a catch clause body.
    /// `e.message` → `_error_ctx.message`, `e.details` → fat-pointer dispatch.
    catch_var: []const u8 = "",
    /// Names of local variables that appear directly in `return` expressions
    /// (or as arguments to calls in return expressions) in the current body.
    /// When a name is in this set, we skip emitting `defer _allocator.free(name)`
    /// because the caller takes ownership of the allocated string.
    returned_names: ?*const std.StringHashMap(void) = null,
    /// Which GUI backend preamble to embed.
    gui_backend: GuiBackend = .stub,
    /// Set to true the first time any GUI API call is encountered.
    /// Allows `generate()` to return a `GenerateResult` with `uses_gui`.
    uses_gui_ptr: ?*bool = null,
    /// When true, emit `export fn Owner_method(...)` wrappers after each
    /// class/struct for eligible `shared` methods (lib mode only).
    emit_exports: bool = false,
    /// Points to the `has_exports` bool in `generate()`.  Set to true the
    /// first time an export wrapper is emitted.
    has_exports_ptr: ?*bool = null,
    /// Variable names that are nil-narrowed in the current if-then scope.
    /// These idents should be accessed with `.?` in Zig to unwrap the optional.
    nil_narrowed: ?*const std.StringHashMap(void) = null,
    /// Non-null inside `extend T` method bodies: the Zebra type of `self`/`this`.
    /// Used so stdlib method calls on `self` dispatch correctly.
    ext_self_type: ?TypeChecker.Type = null,
    /// When set, genExpr substitutes the named expression pointer with this
    /// variable name.  Used to hoist allocating receivers in `genReturn`.
    expr_subst: ?struct { orig: *const Ast.Expr, name: []const u8 } = null,
    /// Native (non-Zebra) `use` dep kinds.  Keyed by dotted Zebra path.
    /// Null = all deps are Zebra-compiled; missing key = Zebra dep.
    native_uses: ?*const std.StringHashMap(NativeUse) = null,
    /// Non-empty when generating a TCO-transformed method: the current method
    /// name.  `genReturn` checks tail-recursive calls against this name.
    tco_method_name: []const u8 = "",
    /// Parameter names of the TCO method (declaration order).
    /// `genReturn` uses these to emit assignments before `continue`.
    tco_params: []const []const u8 = &.{},
    /// True when the TCO method is `shared` (class-level static).
    tco_shared: bool = false,
    /// Source file path (e.g. "test/hello.zbr").  Set from module.file.
    /// Used to emit `// zbr:file:line` markers before each statement so
    /// that Zig compiler errors can be remapped to Zebra source locations.
    source_file: []const u8 = "",
    /// True when generating the body of a generic class (emitted as a comptime
    /// function `pub fn Name(comptime T: type) type { return struct { … }; }`).
    /// Enables `@This()` instead of `owner` for self-type references in init/methods.
    is_generic: bool = false,
    /// When `is_generic`, points to the class declaration so that `genAssign` can
    /// resolve field types for explicit `std.ArrayList(T){}` emission.
    owner_class: ?*const Ast.DeclClass = null,
    /// True when generating the body of a `struct` (not a `class`).
    /// Structs have no `_type_tag` field, so `cue init` bodies must skip the
    /// `self._type_tag = _ttag_*` stamp that classes require.
    is_struct_owner: bool = false,
    /// True when the enclosing method is `throws` (returns `anyerror!T`).
    /// Enables automatic `try` prefix for calls to other `throws` methods,
    /// avoiding Zig's "error union is ignored" error at call sites.
    current_method_throws: bool = false,
    /// Set to true by the `.try_` codegen path before calling genExpr on the inner
    /// expression, so that genCall does not also emit a `try` prefix.  Prevents
    /// `try try self.foo()` when the Zebra source has `foo()?`.
    suppress_auto_try: bool = false,
    /// Member declarations of the current class or struct.  Used in genCall to
    /// look up whether a self-method called via `.method()` syntax is `throws`.
    /// Empty slice at module scope or when owner is a namespace.
    owner_members: []const Ast.Decl = &.{},
    /// Incremented each time we enter an `arena` block so nested scopes get
    /// unique variable names (_arena_scope_1, _arena_scope_2, …).
    arena_depth: u32 = 0,
    /// Module interfaces of `use`d deps — used in `genUse` to decide whether to
    /// import the whole module or unwrap a same-named class.
    imported_modules: ?*const std.StringHashMap(TypeChecker.ModuleInterface) = null,

    // ── Context-adjustment helpers ────────────────────────────────────────────

    fn withOwner(g: Generator, new_owner: []const u8) Generator {
        var c = g; c.owner = new_owner; return c;
    }
    /// Set owner name + owner_class pointer for a non-generic concrete class.
    /// This enables `resolveFieldTypeRef` for `^T` boxing in the class body.
    fn withClass(g: Generator, cls: *const Ast.DeclClass) Generator {
        var c = g; c.owner = cls.name; c.owner_class = cls; c.owner_members = cls.members; return c;
    }
    /// Set owner name + owner_members for a struct body.
    /// Mirrors `withClass` so that `exprCallIsThrows` and `genCall`'s auto-try
    /// logic can look up throws status for `self.method()` calls inside struct methods.
    fn withStruct(g: Generator, s: *const Ast.DeclStruct) Generator {
        var c = g; c.owner = s.name; c.owner_members = s.members; c.is_struct_owner = true; return c;
    }
    fn withGeneric(g: Generator, cls: *const Ast.DeclClass) Generator {
        var c = g; c.is_generic = true; c.owner_class = cls; return c;
    }
    fn withExtSelf(g: Generator, t: TypeChecker.Type) Generator {
        var c = g; c.ext_self_type = t; return c;
    }

    /// When inside a generic class body, resolve the Zig element-type string for a
    /// `List(X)` field named `field_name`.  Returns null if the field isn't a List.
    ///
    /// Examples:
    ///   `items as List(T)` with type_params=["T"] → "T"   (comptime param name)
    ///   `items as List(str)`                       → "[]const u8"
    /// Return the declared TypeRef for a field of the current class, or null.
    fn resolveFieldTypeRef(g: Generator, field_name: []const u8) ?Ast.TypeRef {
        // Use owner_class.members when in a class body; fall back to owner_members
        // (which is set for structs via withStruct) so that struct field ^T boxing works.
        const members: []const Ast.Decl = if (g.owner_class) |cls|
            cls.members
        else
            g.owner_members;
        for (members) |m| {
            const vd: *const Ast.DeclVar = switch (m) {
                .var_ => |v| v,
                else  => continue,
            };
            if (!std.mem.eql(u8, vd.name, field_name)) continue;
            return vd.type_;
        }
        return null;
    }

    /// Return the `GenericTypeRef` for a class field named `field_name`, or null
    /// if the field doesn't exist, has no type annotation, or isn't a generic type.
    /// Works for any `List(T)`, `HashMap(K,V)`, or user-defined generic `Stack(T)`.
    fn resolveFieldGenericTypeRef(g: Generator, field_name: []const u8) ?Ast.GenericTypeRef {
        const tr = g.resolveFieldTypeRef(field_name) orelse return null;
        if (tr != .generic) return null;
        return tr.generic;
    }
    fn asMethod(g: Generator) Generator {
        var c = g; c.in_method = true; return c;
    }
    fn indented(g: Generator) Generator {
        var c = g; c.indent += 1; return c;
    }
    fn withMutated(g: Generator, m: *const std.StringHashMap(void)) Generator {
        var c = g; c.mutated = m; return c;
    }
    fn withClosureVars(g: Generator, cv: *std.StringHashMap(void)) Generator {
        var c = g; c.closure_vars = cv; return c;
    }
    fn withCatchVar(g: Generator, name: []const u8) Generator {
        var c = g; c.catch_var = name; return c;
    }
    fn withCaptureFields(g: Generator, fields: []const []const u8) Generator {
        var c = g; c.capture_fields = fields; return c;
    }
    fn withTryLabel(g: Generator, label: []const u8, err_var: []const u8) Generator {
        var c = g; c.try_block_label = label; c.try_err_var = err_var; return c;
    }
    fn withReturnedNames(g: Generator, rn: *const std.StringHashMap(void)) Generator {
        var c = g; c.returned_names = rn; return c;
    }
    fn withNilNarrowed(g: Generator, nn: *const std.StringHashMap(void)) Generator {
        var c = g; c.nil_narrowed = nn; return c;
    }
    fn withTco(g: Generator, method_name: []const u8, params: []const []const u8, shared: bool) Generator {
        var c = g; c.tco_method_name = method_name; c.tco_params = params; c.tco_shared = shared; return c;
    }

    // ── Low-level output ──────────────────────────────────────────────────────

    fn writeIndent(g: Generator) anyerror!void {
        var i: u32 = 0;
        while (i < g.indent) : (i += 1) try g.w.writeAll("    ");
    }

    /// Write an indented line (adds trailing newline).
    fn line(g: Generator, s: []const u8) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll(s);
        try g.w.writeAll("\n");
    }

    // ── Module ────────────────────────────────────────────────────────────────

    fn genModule(g: Generator, module: Ast.Module) anyerror!void {
        try g.w.writeAll("// Generated by the Zebra compiler.\n// Source: ");
        try g.w.writeAll(module.file);
        try g.w.writeAll("\n\nconst std     = @import(\"std\");\nconst builtin = @import(\"builtin\");\n\n");
        // Global allocator — used by List, HashMap, and allocating string ops.
        // ArenaAllocator: individual free() calls are no-ops; everything released
        // at program exit via _arena.deinit().  Much faster than GPA for programs
        // that do many small allocations (string ops, trigram maps, etc.).
        // For leak detection during development, swap to GeneralPurposeAllocator.
        try g.w.writeAll("var _arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n");
        // `var` (not `const`) so that `arena` blocks can save/restore it.
        try g.w.writeAll("var _allocator: std.mem.Allocator = undefined;\n");
        // `_initAllocator` sets this module's allocator AND propagates to every
        // directly-imported Zebra module, so transitive deps are always initialised
        // even when the root `main` only calls it for direct imports.
        try g.w.writeAll("pub fn _initAllocator(a: std.mem.Allocator) void {\n    _allocator = a;\n");
        for (module.decls) |decl| {
            const u = switch (decl) { .use => |u| u, else => continue };
            if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
            const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
            defer g.alloc.free(imp_path);
            try g.w.print("    @import(\"{s}.zig\")._initAllocator(a);\n", .{imp_path});
        }
        try g.w.writeAll("}\n\n");
        // Thread-local error context — populated by `raise` statements.
        try g.w.writeAll("const _Stringable = struct {\n");
        try g.w.writeAll("    ptr:         *anyopaque,\n");
        try g.w.writeAll("    toString_fn: *const fn (*anyopaque) []const u8,\n");
        try g.w.writeAll("    pub fn toString(self: _Stringable) []const u8 {\n");
        try g.w.writeAll("        return self.toString_fn(self.ptr);\n");
        try g.w.writeAll("    }\n");
        try g.w.writeAll("};\n");
        try g.w.writeAll("const _ZebraErrorCtx = struct { message: []const u8 = \"\", details: ?_Stringable = null };\n");
        try g.w.writeAll("threadlocal var _error_ctx: _ZebraErrorCtx = .{};\n");
        // ── Comparison helpers — handle both numeric and string ([]const u8) types ──
        try g.w.writeAll(
            \\fn _zebra_lt(a: anytype, b: anytype) bool {
            \\    if (comptime @TypeOf(a) == []const u8) return std.mem.lessThan(u8, a, b);
            \\    return a < b;
            \\}
            \\fn _zebra_le(a: anytype, b: anytype) bool {
            \\    if (comptime @TypeOf(a) == []const u8) return std.mem.order(u8, a, b) != .gt;
            \\    return a <= b;
            \\}
            \\fn _zebra_gt(a: anytype, b: anytype) bool {
            \\    if (comptime @TypeOf(a) == []const u8) return std.mem.order(u8, a, b) == .gt;
            \\    return a > b;
            \\}
            \\fn _zebra_ge(a: anytype, b: anytype) bool {
            \\    if (comptime @TypeOf(a) == []const u8) return std.mem.order(u8, a, b) != .lt;
            \\    return a >= b;
            \\}
            \\/// `item in container` — membership test for List, string (substring), HashMap.
            \\fn _zebra_in(item: anytype, container: anytype) bool {
            \\    const C = @TypeOf(container);
            \\    const I = @TypeOf(item);
            \\    // Struct types: ArrayList (has .items field) or HashMap (has .contains decl).
            \\    if (comptime @typeInfo(C) == .@"struct") {
            \\        if (comptime @hasField(C, "items")) {
            \\            for (container.items) |elem| {
            \\                if (comptime I == []const u8 or @typeInfo(I) == .pointer) {
            \\                    if (std.mem.eql(u8, elem, item)) return true;
            \\                } else {
            \\                    if (elem == item) return true;
            \\                }
            \\            }
            \\            return false;
            \\        }
            \\        if (comptime @hasDecl(C, "contains")) return container.contains(item);
            \\        return false;
            \\    }
            \\    // Pointer/array types: string substring check (coerce to []const u8).
            \\    return std.mem.indexOf(u8, @as([]const u8, container), @as([]const u8, item)) != null;
            \\}
            \\/// `s + t` — string concatenation.
            \\fn _str_concat(a: []const u8, b: []const u8, alloc: std.mem.Allocator) []const u8 {
            \\    return std.mem.concat(alloc, u8, &.{ a, b }) catch @panic("OOM");
            \\}
            \\/// `s * n` — repeat string s n times.
            \\fn _str_repeat(s: []const u8, n: anytype, alloc: std.mem.Allocator) []const u8 {
            \\    const count: usize = @intCast(n);
            \\    if (count == 0 or s.len == 0) return "";
            \\    const buf = alloc.alloc(u8, s.len * count) catch @panic("OOM");
            \\    for (0..count) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
            \\    return buf;
            \\}
            \\/// FNV-1a 32-bit hash — used as the type-arg component of _type_tag.
            \\/// Low 32 bits of _ttag_ClassName hold the class hash; high 32 bits
            \\/// hold the combined type-arg hash for generic instantiations (Phase 3).
            \\/// Also usable as Symbol.hash for fast string identity comparison.
            \\fn _zbr_hash(comptime s: []const u8) u32 {
            \\    comptime var h: u32 = 2166136261;
            \\    comptime for (s) |c| { h ^= c; h *%= 16777619; };
            \\    return h;
            \\}
        );
        // ── Result(T, E) — functional error type ──────────────────────────────
        try g.w.writeAll(
            \\fn _Result(comptime T: type, comptime E: type) type {
            \\    return union(enum) {
            \\        ok: T,
            \\        err: E,
            \\        pub fn isOk(self: @This()) bool { return self == .ok; }
            \\        pub fn isErr(self: @This()) bool { return self == .err; }
            \\        pub fn unwrap(self: @This()) T {
            \\            return switch (self) { .ok => |v| v, .err => std.debug.panic("unwrap() on error Result\n", .{}) };
            \\        }
            \\        pub fn unwrapOr(self: @This(), default: T) T {
            \\            return switch (self) { .ok => |v| v, .err => default };
            \\        }
            \\        pub fn okValue(self: @This()) ?T {
            \\            return switch (self) { .ok => |v| v, .err => null };
            \\        }
            \\        pub fn errValue(self: @This()) ?E {
            \\            return switch (self) { .ok => null, .err => |e| e };
            \\        }
            \\        /// map(f) — apply f to the ok value; propagate err unchanged.
            \\        /// f may be a fn pointer or a capture-closure struct with a `call` method.
            \\        pub fn map(self: @This(), f: anytype) _Result(
            \\            @TypeOf(if (comptime @typeInfo(@TypeOf(f)) == .@"fn") f(@as(T, undefined)) else f.call(@as(T, undefined))), E
            \\        ) {
            \\            const _is_fn = comptime @typeInfo(@TypeOf(f)) == .@"fn";
            \\            return switch (self) {
            \\                .ok  => |v| .{ .ok = if (_is_fn) f(v) else f.call(v) },
            \\                .err => |e| .{ .err = e },
            \\            };
            \\        }
            \\        /// flatMap(f) — apply f to the ok value; f must return Result(U, E).
            \\        pub fn flatMap(self: @This(), f: anytype) @TypeOf(
            \\            if (comptime @typeInfo(@TypeOf(f)) == .@"fn") f(@as(T, undefined)) else f.call(@as(T, undefined))
            \\        ) {
            \\            const _is_fn = comptime @typeInfo(@TypeOf(f)) == .@"fn";
            \\            return switch (self) {
            \\                .ok  => |v| if (_is_fn) f(v) else f.call(v),
            \\                .err => |e| .{ .err = e },
            \\            };
            \\        }
            \\    };
            \\}
            \\
        );
        // ── String padding helpers ──────────────────────────────────────────
        // fill is `anytype`: comptime char literal (' ') or a 1-char string ("*").
        // _pad_fill() normalises both to u8.
        try g.w.writeAll(
            \\fn _pad_fill(fill: anytype) u8 {
            \\    if (comptime @typeInfo(@TypeOf(fill)) == .pointer) return fill[0];
            \\    return @as(u8, @intCast(fill));
            \\}
            \\fn _pad_left(s: []const u8, width: usize, fill: anytype, alloc: std.mem.Allocator) []const u8 {
            \\    if (s.len >= width) return s;
            \\    const buf = alloc.alloc(u8, width) catch @panic("OOM");
            \\    @memset(buf[0 .. width - s.len], _pad_fill(fill));
            \\    @memcpy(buf[width - s.len ..], s);
            \\    return buf;
            \\}
            \\fn _pad_right(s: []const u8, width: usize, fill: anytype, alloc: std.mem.Allocator) []const u8 {
            \\    if (s.len >= width) return s;
            \\    const buf = alloc.alloc(u8, width) catch @panic("OOM");
            \\    @memcpy(buf[0 .. s.len], s);
            \\    @memset(buf[s.len ..], _pad_fill(fill));
            \\    return buf;
            \\}
            \\fn _pad_center(s: []const u8, width: usize, fill: anytype, alloc: std.mem.Allocator) []const u8 {
            \\    if (s.len >= width) return s;
            \\    const pad = width - s.len;
            \\    const lpad = pad / 2;
            \\    const buf = alloc.alloc(u8, width) catch @panic("OOM");
            \\    @memset(buf[0 .. lpad], _pad_fill(fill));
            \\    @memcpy(buf[lpad .. lpad + s.len], s);
            \\    @memset(buf[lpad + s.len ..], _pad_fill(fill));
            \\    return buf;
            \\}
            \\
        );
        // ── List sort helpers ───────────────────────────────────────────────
        try g.w.writeAll(
            \\fn _zebra_sort_natural(comptime T: type, items: []T) void {
            \\    const _I = struct {
            \\        fn less(_: void, a: T, b: T) bool {
            \\            if (comptime T == []const u8) return std.mem.lessThan(u8, a, b);
            \\            return a < b;
            \\        }
            \\    };
            \\    std.mem.sort(T, items, {}, _I.less);
            \\}
            \\fn _zebra_sort_by(comptime T: type, comptime cmp: anytype, items: []T) void {
            \\    const _I = struct {
            \\        fn less(_: void, a: T, b: T) bool {
            \\            return cmp(a, b);
            \\        }
            \\    };
            \\    std.mem.sort(T, items, {}, _I.less);
            \\}
            \\
        );
        // ── sys.run — subprocess spawn + capture ───────────────────────────
        try g.w.writeAll(
            \\const SysRunResult = struct { exit_code: i64, stdout: []const u8, stderr: []const u8 };
            \\fn _sys_run(argv: std.ArrayList([]const u8)) SysRunResult {
            \\    const _r = std.process.Child.run(.{
            \\        .allocator = _allocator,
            \\        .argv = argv.items,
            \\        .max_output_bytes = 16 * 1024 * 1024,
            \\    }) catch return SysRunResult{ .exit_code = -1, .stdout = "", .stderr = "spawn failed" };
            \\    const _ec: i64 = switch (_r.term) {
            \\        .Exited => |code| @intCast(code),
            \\        else    => -1,
            \\    };
            \\    return .{ .exit_code = _ec, .stdout = _r.stdout, .stderr = _r.stderr };
            \\}
            \\
        );
        // ── DateTime stdlib ──────────────────────────────────────────────────
        try g.w.writeAll(
            \\const _DateTime = struct { epoch_ms: i64 };
            \\const _CalendarView = struct {
            \\    year: i64, month: i64, day: i64, weekday: i64,
            \\    monthName: []const u8, era: []const u8,
            \\};
            \\const _DtG = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64 };
            \\fn _dt_is_leap(year: i64) bool {
            \\    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
            \\}
            \\fn _dt_days_in_month(year: i64, month: i64) i64 {
            \\    const _d = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            \\    if (month == 2 and _dt_is_leap(year)) return 29;
            \\    return _d[@intCast(month - 1)];
            \\}
            \\fn _dt_to_gregorian(epoch_ms: i64) _DtG {
            \\    const epoch_s   = @divFloor(epoch_ms, 1000);
            \\    const epoch_days = @divFloor(epoch_s, 86400);
            \\    const time_rem  = @mod(epoch_s, 86400);
            \\    // Fliegel-Van Flandern: JDN → civil Gregorian date
            \\    const jd = epoch_days + 2440588;
            \\    var l  = jd + 68569;
            \\    const n  = @divFloor(4 * l, 146097);
            \\    l = l - @divFloor(146097 * n + 3, 4);
            \\    const ii = @divFloor(4000 * (l + 1), 1461001);
            \\    l = l - @divFloor(1461 * ii, 4) + 31;
            \\    const jj = @divFloor(80 * l, 2447);
            \\    const day   = l - @divFloor(2447 * jj, 80);
            \\    l = @divFloor(jj, 11);
            \\    const month = jj + 2 - 12 * l;
            \\    const year  = 100 * (n - 49) + ii + l;
            \\    return .{
            \\        .year = year, .month = month, .day = day,
            \\        .hour   = @divFloor(time_rem, 3600),
            \\        .minute = @divFloor(@mod(time_rem, 3600), 60),
            \\        .second = @mod(time_rem, 60),
            \\    };
            \\}
            \\fn _dt_from_gregorian(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) _DateTime {
            \\    // Richards algorithm: civil date → JDN
            \\    const a   = @divFloor(14 - month, 12);
            \\    const y   = year + 4800 - a;
            \\    const m   = month + 12 * a - 3;
            \\    const jdn = day + @divFloor(153 * m + 2, 5) + 365 * y
            \\              + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) - 32045;
            \\    const epoch_days = jdn - 2440588;
            \\    const epoch_s    = epoch_days * 86400 + hour * 3600 + minute * 60 + second;
            \\    return .{ .epoch_ms = epoch_s * 1000 };
            \\}
            \\fn _dt_now() _DateTime { return .{ .epoch_ms = std.time.milliTimestamp() }; }
            \\fn _dt_weekday(dt: _DateTime) i64 {
            \\    // epoch_days=0 is Thursday (ISO 4); Monday=1 … Sunday=7
            \\    const epoch_days = @divFloor(dt.epoch_ms, 86400000);
            \\    return @mod(epoch_days + 3, 7) + 1;
            \\}
            \\fn _dt_add_days(dt: _DateTime, n: i64) _DateTime    { return .{ .epoch_ms = dt.epoch_ms + n * 86400000 }; }
            \\fn _dt_add_hours(dt: _DateTime, n: i64) _DateTime   { return .{ .epoch_ms = dt.epoch_ms + n * 3600000 }; }
            \\fn _dt_add_minutes(dt: _DateTime, n: i64) _DateTime { return .{ .epoch_ms = dt.epoch_ms + n * 60000 }; }
            \\fn _dt_add_seconds(dt: _DateTime, n: i64) _DateTime { return .{ .epoch_ms = dt.epoch_ms + n * 1000 }; }
            \\fn _dt_add_months(dt: _DateTime, months: i64) _DateTime {
            \\    const g      = _dt_to_gregorian(dt.epoch_ms);
            \\    const total  = (g.month - 1) + months;
            \\    const ny     = g.year + @divFloor(total, 12);
            \\    const nm     = @mod(total, 12) + 1;
            \\    const max_d  = _dt_days_in_month(ny, nm);
            \\    const nd     = if (g.day > max_d) max_d else g.day;
            \\    return _dt_from_gregorian(ny, nm, nd, g.hour, g.minute, g.second);
            \\}
            \\fn _dt_add_years(dt: _DateTime, years: i64) _DateTime {
            \\    const g     = _dt_to_gregorian(dt.epoch_ms);
            \\    const ny    = g.year + years;
            \\    const max_d = _dt_days_in_month(ny, g.month);
            \\    const nd    = if (g.day > max_d) max_d else g.day;
            \\    return _dt_from_gregorian(ny, g.month, nd, g.hour, g.minute, g.second);
            \\}
            \\fn _dt_to_iso8601(dt: _DateTime) []const u8 {
            \\    const g = _dt_to_gregorian(dt.epoch_ms);
            \\    return std.fmt.allocPrint(_allocator,
            \\        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            \\        .{ @as(u32, @intCast(g.year)), @as(u8, @intCast(g.month)), @as(u8, @intCast(g.day)),
            \\           @as(u8, @intCast(g.hour)),  @as(u8, @intCast(g.minute)), @as(u8, @intCast(g.second)) }) catch "";
            \\}
            \\fn _dt_format(dt: _DateTime, pattern: []const u8) []const u8 {
            \\    const g = _dt_to_gregorian(dt.epoch_ms);
            \\    const _sm = [_][]const u8{"","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
            \\    const _lm = [_][]const u8{"","January","February","March","April","May","June","July","August","September","October","November","December"};
            \\    const _sw = [_][]const u8{"","Mon","Tue","Wed","Thu","Fri","Sat","Sun"};
            \\    const _lw = [_][]const u8{"","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"};
            \\    var out: std.ArrayListUnmanaged(u8) = .{};
            \\    var tmp: [32]u8 = undefined;
            \\    var i: usize = 0;
            \\    while (i < pattern.len) {
            \\        const c = pattern[i];
            \\        var cnt: usize = 1;
            \\        while (i + cnt < pattern.len and pattern[i + cnt] == c) cnt += 1;
            \\        const _uy = @as(u32, @intCast(g.year));
            \\        const _um = @as(u8,  @intCast(g.month));
            \\        const _ud = @as(u8,  @intCast(g.day));
            \\        const _uh = @as(u8,  @intCast(g.hour));
            \\        const _umin = @as(u8, @intCast(g.minute));
            \\        const _us = @as(u8,  @intCast(g.second));
            \\        switch (c) {
            \\            'y' => if (cnt >= 4) out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>4}", .{_uy}) catch "") catch {}
            \\                   else out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{_uy % 100}) catch "") catch {},
            \\            'M' => if (cnt >= 4) out.appendSlice(_allocator, _lm[@intCast(g.month)]) catch {}
            \\                   else if (cnt >= 3) out.appendSlice(_allocator, _sm[@intCast(g.month)]) catch {}
            \\                   else if (cnt >= 2) out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{_um}) catch "") catch {}
            \\                   else out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d}", .{_um}) catch "") catch {},
            \\            'd' => if (cnt >= 2) out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{_ud}) catch "") catch {}
            \\                   else out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d}", .{_ud}) catch "") catch {},
            \\            'H' => out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{_uh}) catch "") catch {},
            \\            'm' => out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{_umin}) catch "") catch {},
            \\            's' => out.appendSlice(_allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{_us}) catch "") catch {},
            \\            'E' => { const _wd: usize = @intCast(_dt_weekday(dt)); out.appendSlice(_allocator, if (cnt >= 4) _lw[_wd] else _sw[_wd]) catch {}; },
            \\            else => out.appendNTimes(_allocator, c, cnt) catch {},
            \\        }
            \\        i += cnt;
            \\    }
            \\    return out.toOwnedSlice(_allocator) catch "";
            \\}
            \\fn _dt_days_between(a: _DateTime, b: _DateTime) i64    { return @divFloor(b.epoch_ms - a.epoch_ms, 86400000); }
            \\fn _dt_seconds_between(a: _DateTime, b: _DateTime) i64 { return @divFloor(b.epoch_ms - a.epoch_ms, 1000); }
            \\fn _dt_in_calendar(dt: _DateTime, cal: []const u8) _CalendarView {
            \\    _ = cal; // only Gregorian implemented; future: dispatch on cal
            \\    const g  = _dt_to_gregorian(dt.epoch_ms);
            \\    const _lm2 = [_][]const u8{"","January","February","March","April","May","June","July","August","September","October","November","December"};
            \\    return .{
            \\        .year = g.year, .month = g.month, .day = g.day,
            \\        .weekday   = _dt_weekday(dt),
            \\        .monthName = _lm2[@intCast(g.month)],
            \\        .era       = "",
            \\    };
            \\}
            \\const Calendar = struct {
            \\    pub const Gregorian = "gregorian";
            \\    pub const Hebrew    = "hebrew";
            \\    pub const Islamic   = "islamic";
            \\    pub const Persian   = "persian";
            \\    pub const Julian    = "julian";
            \\};
            \\
        );
        // ── JSON stdlib ──────────────────────────────────────────────────────
        try g.w.writeAll(
            \\const JsonValue = std.json.Value;
            \\fn _json_parse(src: []const u8) ?JsonValue {
            \\    // parseFromSliceLeaky uses allocator directly (no arena), intentionally leaked.
            \\    return std.json.parseFromSliceLeaky(JsonValue, std.heap.page_allocator, src, .{}) catch return null;
            \\}
            \\fn _json_stringify(v: JsonValue) []const u8 {
            \\    return std.json.Stringify.valueAlloc(std.heap.page_allocator, v, .{}) catch "{}";
            \\}
            \\fn _json_object() JsonValue { return .{ .object = std.json.ObjectMap.init(std.heap.page_allocator) }; }
            \\fn _json_array() JsonValue  { return .{ .array = std.json.Array.init(std.heap.page_allocator) }; }
            \\fn _json_get_str(v: JsonValue, key: []const u8) []const u8 {
            \\    switch (v) { .object => |o| if (o.get(key)) |it| switch (it) { .string => |s| return s, else => {} }, else => {} }
            \\    return "";
            \\}
            \\fn _json_get_int(v: JsonValue, key: []const u8) i64 {
            \\    switch (v) { .object => |o| if (o.get(key)) |it| switch (it) { .integer => |n| return n, else => {} }, else => {} }
            \\    return 0;
            \\}
            \\fn _json_get_float(v: JsonValue, key: []const u8) f64 {
            \\    switch (v) { .object => |o| if (o.get(key)) |it| switch (it) {
            \\        .float => |f| return f, .integer => |n| return @floatFromInt(n), else => {} }, else => {} }
            \\    return 0.0;
            \\}
            \\fn _json_get_bool(v: JsonValue, key: []const u8) bool {
            \\    switch (v) { .object => |o| if (o.get(key)) |it| switch (it) { .bool => |b| return b, else => {} }, else => {} }
            \\    return false;
            \\}
            \\fn _json_get_obj(v: JsonValue, key: []const u8) JsonValue {
            \\    switch (v) { .object => |o| if (o.get(key)) |it| switch (it) { .object => return it, else => {} }, else => {} }
            \\    return .{ .object = std.json.ObjectMap.init(std.heap.page_allocator) };
            \\}
            \\fn _json_get_list(v: JsonValue, key: []const u8) []JsonValue {
            \\    switch (v) { .object => |o| if (o.get(key)) |it| switch (it) { .array => |a| return a.items, else => {} }, else => {} }
            \\    return &[_]JsonValue{};
            \\}
            \\fn _json_is_null(v: JsonValue) bool   { return v == .null; }
            \\fn _json_is_object(v: JsonValue) bool  { return switch (v) { .object => true, else => false }; }
            \\fn _json_is_array(v: JsonValue) bool   { return switch (v) { .array  => true, else => false }; }
            \\fn _json_put_str(v: *JsonValue, key: []const u8, val: []const u8) void {
            \\    if (v.* != .object) return;
            \\    v.object.put(std.heap.page_allocator.dupe(u8, key) catch return, .{ .string = val }) catch {};
            \\}
            \\fn _json_put_int(v: *JsonValue, key: []const u8, val: i64) void {
            \\    if (v.* != .object) return;
            \\    v.object.put(std.heap.page_allocator.dupe(u8, key) catch return, .{ .integer = val }) catch {};
            \\}
            \\fn _json_put_float(v: *JsonValue, key: []const u8, val: f64) void {
            \\    if (v.* != .object) return;
            \\    v.object.put(std.heap.page_allocator.dupe(u8, key) catch return, .{ .float = val }) catch {};
            \\}
            \\fn _json_put_bool(v: *JsonValue, key: []const u8, val: bool) void {
            \\    if (v.* != .object) return;
            \\    v.object.put(std.heap.page_allocator.dupe(u8, key) catch return, .{ .bool = val }) catch {};
            \\}
            \\fn _json_arr_str(v: *JsonValue, val: []const u8) void {
            \\    if (v.* != .array) return;
            \\    v.array.append(.{ .string = val }) catch {};
            \\}
            \\fn _json_arr_int(v: *JsonValue, val: i64) void {
            \\    if (v.* != .array) return;
            \\    v.array.append(.{ .integer = val }) catch {};
            \\}
            \\fn _json_arr_float(v: *JsonValue, val: f64) void {
            \\    if (v.* != .array) return;
            \\    v.array.append(.{ .float = val }) catch {};
            \\}
            \\fn _json_arr_bool(v: *JsonValue, val: bool) void {
            \\    if (v.* != .array) return;
            \\    v.array.append(.{ .bool = val }) catch {};
            \\}
            \\
        );
        // ── HTTP networking helpers ─────────────────────────────────────────
        // Returns ?HttpResponse (null on any network/TLS error).
        // ca_bundle is populated on first HTTPS call via next_https_rescan_certs=true (Zig default).
        try g.w.writeAll("const HttpResponse = struct { status: u16, text: []const u8, headers: []const [2][]const u8 = &.{} };\n");
        try g.w.writeAll("fn _http_request(method: std.http.Method, url: []const u8, payload: ?[]const u8) ?HttpResponse {\n");
        try g.w.writeAll("    var _hc = std.http.Client{ .allocator = _allocator };\n");
        try g.w.writeAll("    defer _hc.deinit();\n");
        try g.w.writeAll("    var _hb = std.io.Writer.Allocating.init(std.heap.page_allocator);\n");
        try g.w.writeAll("    const _hr = _hc.fetch(.{ .location = .{ .url = url }, .method = method, .payload = payload, .response_writer = &_hb.writer }) catch return null;\n");
        try g.w.writeAll("    return .{ .status = @intFromEnum(_hr.status), .text = _hb.written() };\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _http_get(url: []const u8) ?HttpResponse { return _http_request(.GET, url, null); }\n");
        try g.w.writeAll("fn _http_post(url: []const u8, payload: []const u8) ?HttpResponse { return _http_request(.POST, url, payload); }\n");
        try g.w.writeAll("fn _http_json_get(url: []const u8) ?JsonValue { const _r = _http_request(.GET, url, null) orelse return null; return _json_parse(_r.text); }\n");
        try g.w.writeAll(
            \\fn _http_json_post(url: []const u8, body: []const u8) ?JsonValue {
            \\    var _hc = std.http.Client{ .allocator = _allocator };
            \\    defer _hc.deinit();
            \\    var _hb = std.io.Writer.Allocating.init(std.heap.page_allocator);
            \\    _ = _hc.fetch(.{ .location = .{ .url = url }, .method = .POST, .payload = body,
            \\        .extra_headers = &.{ .{ .name = "Content-Type", .value = "application/json" } },
            \\        .response_writer = &_hb.writer }) catch return null;
            \\    return _json_parse(_hb.written());
            \\}
            \\fn _http_with_header(resp: HttpResponse, key: []const u8, val: []const u8) HttpResponse {
            \\    var _new = std.heap.page_allocator.alloc([2][]const u8, resp.headers.len + 1) catch return resp;
            \\    @memcpy(_new[0..resp.headers.len], resp.headers);
            \\    _new[resp.headers.len] = .{ key, val };
            \\    return .{ .status = resp.status, .text = resp.text, .headers = _new };
            \\}
            \\
        );
        // ── HTTP server ─────────────────────────────────────────────────────
        // Threaded: each accepted connection is dispatched to a std.Thread.
        // page_allocator is used per-thread (thread-safe, unbounded lifetime).
        try g.w.writeAll("const HttpRequest = struct { method: []const u8, path: []const u8, content: []const u8 };\n");
        try g.w.writeAll(
            \\fn _http_serve(port: u16, handler: anytype) void {
            \\    const _HFn = *const fn(HttpRequest) HttpResponse;
            \\    const _fn: _HFn = handler;
            \\    const _Ctx = struct {
            \\        conn: std.net.Server.Connection,
            \\        handler_fn: _HFn,
            \\        fn run(ctx: *@This()) void {
            \\            defer std.heap.page_allocator.destroy(ctx);
            \\            defer ctx.conn.stream.close();
            \\            const _alloc = std.heap.page_allocator;
            \\            // Read request headers (scan for \r\n\r\n).
            \\            var _hd: [16384]u8 = undefined;
            \\            var _hl: usize = 0;
            \\            while (_hl < _hd.len - 4096) {
            \\                const _n = std.posix.recv(ctx.conn.stream.handle, _hd[_hl..@min(_hl+4096, _hd.len)], 0) catch break;
            \\                if (_n == 0) break;
            \\                _hl += _n;
            \\                if (std.mem.indexOf(u8, _hd[0.._hl], "\r\n\r\n") != null) break;
            \\            }
            \\            const _hdrs_end = (std.mem.indexOf(u8, _hd[0.._hl], "\r\n\r\n") orelse (_hl -| 4)) + 4;
            \\            const _head = _hd[0.._hdrs_end];
            \\            var _peeked: usize = if (_hl > _hdrs_end) _hl - _hdrs_end else 0;
            \\            // Parse request line: METHOD PATH VERSION
            \\            const _rl_end = std.mem.indexOf(u8, _head, "\r\n") orelse _hl;
            \\            var _rp = std.mem.splitScalar(u8, _head[0.._rl_end], ' ');
            \\            const _method = _rp.next() orelse "GET";
            \\            const _raw_path = _rp.next() orelse "/";
            \\            const _path = _raw_path[0 .. (std.mem.indexOfScalar(u8, _raw_path, '?') orelse _raw_path.len)];
            \\            // Parse Content-Length.
            \\            var _cl: usize = 0;
            \\            var _hdr_it = std.mem.splitSequence(u8, _head, "\r\n");
            \\            _ = _hdr_it.next();
            \\            while (_hdr_it.next()) |_hl_| {
            \\                if (_hl_.len == 0) break;
            \\                const _cp = std.mem.indexOfScalar(u8, _hl_, ':') orelse continue;
            \\                const _hn = std.mem.trim(u8, _hl_[0.._cp], " ");
            \\                const _hv = std.mem.trim(u8, _hl_[_cp+1..], " ");
            \\                if (std.ascii.eqlIgnoreCase(_hn, "content-length"))
            \\                    _cl = std.fmt.parseInt(usize, _hv, 10) catch 0;
            \\            }
            \\            var _body: []const u8 = "";
            \\            if (_cl > 0) {
            \\                const _bb = _alloc.alloc(u8, _cl) catch @panic("OOM");
            \\                const _pre = @min(_peeked, _cl);
            \\                if (_pre > 0) @memcpy(_bb[0.._pre], _hd[_hdrs_end.._hdrs_end+_pre]);
            \\                var _bi: usize = _pre;
            \\                while (_bi < _cl) {
            \\                    const _rn = std.posix.recv(ctx.conn.stream.handle, _bb[_bi..], 0) catch break;
            \\                    if (_rn == 0) break;
            \\                    _bi += _rn;
            \\                }
            \\                _body = _bb[0.._bi];
            \\                _ = &_peeked;
            \\            }
            \\            const _req = HttpRequest{ .method = _method, .path = _path, .content = _body };
            \\            const _resp = ctx.handler_fn(_req);
            \\            const _st: []const u8 = switch (_resp.status) {
            \\                200 => "OK", 201 => "Created", 204 => "No Content",
            \\                301 => "Moved Permanently", 302 => "Found",
            \\                400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
            \\                404 => "Not Found", 405 => "Method Not Allowed",
            \\                500 => "Internal Server Error",
            \\                else => "Unknown",
            \\            };
            \\            var _xh: std.ArrayList(u8) = .{};
            \\            for (_resp.headers) |_kv| { _xh.appendSlice(_alloc, _kv[0]) catch {}; _xh.appendSlice(_alloc, ": ") catch {}; _xh.appendSlice(_alloc, _kv[1]) catch {}; _xh.appendSlice(_alloc, "\r\n") catch {}; }
            \\            const _out = std.fmt.allocPrint(_alloc,
            \\                "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n{s}",
            \\                .{ _resp.status, _st, _resp.text.len, _xh.items, _resp.text }) catch @panic("OOM");
            \\            ctx.conn.stream.writeAll(_out) catch {};
            \\        }
            \\    };
            \\    const _alloc = std.heap.page_allocator;
            \\    var _srv = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port).listen(.{ .reuse_address = true }) catch |e| @panic(@errorName(e));
            \\    defer _srv.deinit();
            \\    while (true) {
            \\        const _conn = _srv.accept() catch continue;
            \\        const _ctx = _alloc.create(_Ctx) catch { _conn.stream.close(); continue; };
            \\        _ctx.* = .{ .conn = _conn, .handler_fn = _fn };
            \\        _ = std.Thread.spawn(.{}, _Ctx.run, .{_ctx}) catch {
            \\            _alloc.destroy(_ctx);
            \\            _conn.stream.close();
            \\        };
            \\    }
            \\}
            \\
        );
        try g.w.writeAll("\n");
        // ── CSV stdlib ─────────────────────────────────────────────────────────
        // RFC 4180-compliant parser and writer.  Uses page_allocator (program-lifetime,
        // consistent with JSON and HTTP response bodies).
        try g.w.writeAll(
            \\const _CsvTable = struct { rows: []const []const []const u8 };
            \\fn _csv_parse(src: []const u8) _CsvTable {
            \\    const _pa = std.heap.page_allocator;
            \\    var _rows: std.ArrayList([]const []const u8) = .{};
            \\    var _row:  std.ArrayList([]const u8) = .{};
            \\    var _f:    std.ArrayList(u8) = .{};
            \\    const _St = enum { s, fld, q, aq };
            \\    var _st: _St = .s;
            \\    for (src) |c| {
            \\        switch (_st) {
            \\            .s => switch (c) {
            \\                '"'  => { _st = .q; },
            \\                ','  => { _row.append(_pa, "") catch {}; },
            \\                '\r' => {},
            \\                '\n' => { if (_row.items.len > 0) { _rows.append(_pa, _row.toOwnedSlice(_pa) catch &.{}) catch {}; _row = .{}; } },
            \\                else => { _f.append(_pa, c) catch {}; _st = .fld; },
            \\            },
            \\            .fld => switch (c) {
            \\                ',' => { _row.append(_pa, _f.toOwnedSlice(_pa) catch "") catch {}; _f = .{}; _st = .s; },
            \\                '\r' => {},
            \\                '\n' => { _row.append(_pa, _f.toOwnedSlice(_pa) catch "") catch {}; _f = .{}; _rows.append(_pa, _row.toOwnedSlice(_pa) catch &.{}) catch {}; _row = .{}; _st = .s; },
            \\                else => { _f.append(_pa, c) catch {}; },
            \\            },
            \\            .q  => switch (c) {
            \\                '"'  => { _st = .aq; },
            \\                else => { _f.append(_pa, c) catch {}; },
            \\            },
            \\            .aq => switch (c) {
            \\                '"' => { _f.append(_pa, '"') catch {}; _st = .q; },
            \\                ',' => { _row.append(_pa, _f.toOwnedSlice(_pa) catch "") catch {}; _f = .{}; _st = .s; },
            \\                '\r' => {},
            \\                '\n' => { _row.append(_pa, _f.toOwnedSlice(_pa) catch "") catch {}; _f = .{}; _rows.append(_pa, _row.toOwnedSlice(_pa) catch &.{}) catch {}; _row = .{}; _st = .s; },
            \\                else => { _st = .s; },
            \\            },
            \\        }
            \\    }
            \\    if (_st == .fld or _st == .aq or _st == .q) {
            \\        _row.append(_pa, _f.toOwnedSlice(_pa) catch "") catch {};
            \\    } else if (_st == .s and _row.items.len > 0) {
            \\        _row.append(_pa, "") catch {};
            \\    }
            \\    if (_row.items.len > 0) _rows.append(_pa, _row.toOwnedSlice(_pa) catch &.{}) catch {};
            \\    return .{ .rows = _rows.toOwnedSlice(_pa) catch &.{} };
            \\}
            \\fn _csv_parse_file(path: []const u8) _CsvTable {
            \\    const src = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, std.math.maxInt(usize)) catch return .{ .rows = &.{} };
            \\    return _csv_parse(src);
            \\}
            \\fn _csv_row_count(t: _CsvTable) i64 { return @as(i64, @intCast(t.rows.len)); }
            \\fn _csv_col_count(t: _CsvTable) i64 { return if (t.rows.len > 0) @as(i64, @intCast(t.rows[0].len)) else 0; }
            \\fn _csv_header(t: _CsvTable) std.ArrayList([]const u8) {
            \\    var _r: std.ArrayList([]const u8) = .{};
            \\    if (t.rows.len > 0) for (t.rows[0]) |f| _r.append(std.heap.page_allocator, f) catch {};
            \\    return _r;
            \\}
            \\fn _csv_row(t: _CsvTable, n: i64) std.ArrayList([]const u8) {
            \\    var _r: std.ArrayList([]const u8) = .{};
            \\    const _i: usize = @intCast(@max(0, n));
            \\    if (_i < t.rows.len) for (t.rows[_i]) |f| _r.append(std.heap.page_allocator, f) catch {};
            \\    return _r;
            \\}
            \\fn _csv_rows(t: _CsvTable) std.ArrayList(std.ArrayList([]const u8)) {
            \\    var _out: std.ArrayList(std.ArrayList([]const u8)) = .{};
            \\    for (t.rows) |row| { var _r: std.ArrayList([]const u8) = .{}; for (row) |f| _r.append(std.heap.page_allocator, f) catch {}; _out.append(std.heap.page_allocator, _r) catch {}; }
            \\    return _out;
            \\}
            \\fn _csv_data_rows(t: _CsvTable) std.ArrayList(std.ArrayList([]const u8)) {
            \\    var _out: std.ArrayList(std.ArrayList([]const u8)) = .{};
            \\    const _s: usize = if (t.rows.len > 0) 1 else 0;
            \\    for (t.rows[_s..]) |row| { var _r: std.ArrayList([]const u8) = .{}; for (row) |f| _r.append(std.heap.page_allocator, f) catch {}; _out.append(std.heap.page_allocator, _r) catch {}; }
            \\    return _out;
            \\}
            \\fn _csv_get(t: _CsvTable, row: std.ArrayList([]const u8), col: []const u8) []const u8 {
            \\    if (t.rows.len == 0) return "";
            \\    for (t.rows[0], 0..) |h, i| { if (std.mem.eql(u8, h, col)) return if (i < row.items.len) row.items[i] else ""; }
            \\    return "";
            \\}
            \\const _CsvWriter = struct { buf: std.ArrayList(u8) };
            \\fn _csv_writer_init() _CsvWriter { return .{ .buf = .{} }; }
            \\fn _csv_write_row(w: *_CsvWriter, row: std.ArrayList([]const u8)) void {
            \\    const _pa = std.heap.page_allocator;
            \\    for (row.items, 0..) |field, i| {
            \\        if (i > 0) w.buf.append(_pa, ',') catch {};
            \\        const _nq = std.mem.indexOfAny(u8, field, ",\"\r\n") != null;
            \\        if (_nq) {
            \\            w.buf.append(_pa, '"') catch {};
            \\            for (field) |c| { if (c == '"') w.buf.append(_pa, '"') catch {}; w.buf.append(_pa, c) catch {}; }
            \\            w.buf.append(_pa, '"') catch {};
            \\        } else { w.buf.appendSlice(_pa, field) catch {}; }
            \\    }
            \\    w.buf.appendSlice(_pa, "\r\n") catch {};
            \\}
            \\fn _csv_build(w: *const _CsvWriter) []const u8 { return w.buf.items; }
            \\
        );
        // ── TCP helpers ────────────────────────────────────────────────────
        try g.w.writeAll("const TcpConn = struct { stream: std.net.Stream };\n");
        try g.w.writeAll("fn _tcp_connect(host: []const u8, port: u16) ?TcpConn {\n");
        try g.w.writeAll("    const s = std.net.tcpConnectToHost(_allocator, host, port) catch return null;\n");
        try g.w.writeAll("    return .{ .stream = s };\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _tcp_write(conn: TcpConn, data: []const u8) void {\n");
        try g.w.writeAll("    conn.stream.writeAll(data) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _tcp_read(conn: TcpConn) []const u8 {\n");
        try g.w.writeAll("    var _rb: [65536]u8 = undefined;\n");
        try g.w.writeAll("    var _rd = conn.stream.reader(&_rb);\n");
        try g.w.writeAll("    var _hb = std.io.Writer.Allocating.init(std.heap.page_allocator);\n");
        try g.w.writeAll("    _ = _rd.interface().streamRemaining(&_hb.writer) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("    return _hb.written();\n");
        try g.w.writeAll("}\n");
        // On Windows, stream.read() uses ReadFile which fails on sockets.
        // Use std.posix.recv instead (same as _http_serve).
        try g.w.writeAll("fn _tcp_read_line(conn: TcpConn) []const u8 {\n");
        try g.w.writeAll("    var _buf: std.ArrayList(u8) = .{};\n");
        try g.w.writeAll("    while (true) {\n");
        try g.w.writeAll("        var _b: [1]u8 = undefined;\n");
        try g.w.writeAll("        const _n = std.posix.recv(conn.stream.handle, &_b, 0) catch break;\n");
        try g.w.writeAll("        if (_n == 0) break;\n");
        try g.w.writeAll("        if (_b[0] == '\\n') break;\n");
        try g.w.writeAll("        if (_b[0] != '\\r') _buf.append(std.heap.page_allocator, _b[0]) catch break;\n");
        try g.w.writeAll("    }\n");
        try g.w.writeAll("    return _buf.items;\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _tcp_read_bytes(conn: TcpConn, n: usize) []const u8 {\n");
        try g.w.writeAll("    const _buf = std.heap.page_allocator.alloc(u8, n) catch @panic(\"OOM\");\n");
        try g.w.writeAll("    var _total: usize = 0;\n");
        try g.w.writeAll("    while (_total < n) {\n");
        try g.w.writeAll("        const _got = std.posix.recv(conn.stream.handle, _buf[_total..], 0) catch break;\n");
        try g.w.writeAll("        if (_got == 0) break;\n");
        try g.w.writeAll("        _total += _got;\n");
        try g.w.writeAll("    }\n");
        try g.w.writeAll("    return _buf[0.._total];\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _tcp_close(conn: TcpConn) void { conn.stream.close(); }\n\n");
        // ── UDP helpers ────────────────────────────────────────────────────
        try g.w.writeAll("const UdpSocket = struct { handle: std.posix.socket_t };\n");
        try g.w.writeAll("fn _udp_socket() UdpSocket {\n");
        try g.w.writeAll("    const s = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("    return .{ .handle = s };\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll(
            \\fn _udp_send(sock: UdpSocket, host: []const u8, port: u16, data: []const u8) void {
            \\    const dest = blk: {
            \\        if (std.net.Address.parseIp(host, port)) |a| break :blk a else |_| {}
            \\        const _list = std.net.getAddressList(std.heap.page_allocator, host, port) catch |e| @panic(@errorName(e));
            \\        defer _list.deinit();
            \\        if (_list.addrs.len == 0) @panic("UDP send: hostname resolution failed");
            \\        break :blk _list.addrs[0];
            \\    };
            \\    _ = std.posix.sendto(sock.handle, data, 0, &dest.any, dest.getOsSockLen()) catch |e| @panic(@errorName(e));
            \\}
            \\
        );
        try g.w.writeAll("fn _udp_recv(sock: UdpSocket, max_bytes: usize) []const u8 {\n");
        try g.w.writeAll("    const buf = std.heap.page_allocator.alloc(u8, max_bytes) catch @panic(\"OOM\");\n");
        try g.w.writeAll("    const n = std.posix.recv(sock.handle, buf, 0) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("    return buf[0..n];\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _udp_close(sock: UdpSocket) void { std.posix.close(sock.handle); }\n\n");
        // ── Net.resolve helpers ────────────────────────────────────────────
        try g.w.writeAll(
            \\fn _net_resolve(host: []const u8) []const []const u8 {
            \\    var _result: std.ArrayList([]const u8) = .{};
            \\    const _list = std.net.getAddressList(std.heap.page_allocator, host, 0) catch return &.{};
            \\    defer _list.deinit();
            \\    for (_list.addrs) |_addr| {
            \\        var _buf: [64]u8 = undefined;
            \\        const _full = std.fmt.bufPrint(&_buf, "{f}", .{_addr}) catch continue;
            \\        const _col = std.mem.lastIndexOfScalar(u8, _full, ':') orelse _full.len;
            \\        var _ip = _full[0.._col];
            \\        if (_ip.len >= 2 and _ip[0] == '[') _ip = _ip[1 .. _ip.len - 1];
            \\        const _owned = std.heap.page_allocator.dupe(u8, _ip) catch continue;
            \\        _result.append(std.heap.page_allocator, _owned) catch {};
            \\    }
            \\    return _result.toOwnedSlice(std.heap.page_allocator) catch &.{};
            \\}
            \\
        );
        // ── Regex (Thompson NFA) helpers ───────────────────────────────────
        try g.w.writeAll(
            \\// ─── Thompson NFA regex engine ───────────────────────────────────────────────
            \\const _RNodeKind = enum(u8) { match, lit, dot, cls, split, save, bol, eol_a, wb };
            \\const _RNode = struct {
            \\    kind: _RNodeKind, c: u8 = 0, bits: [32]u8 = [_]u8{0} ** 32,
            \\    neg: bool = false, slot: u8 = 0, out1: u32 = 0xFFFF_FFFF, out2: u32 = 0xFFFF_FFFF,
            \\};
            \\const _RFlags = struct {
            \\    ignore_case: bool = false, multiline: bool = false, dot_all: bool = false, unlimited: bool = false,
            \\    lazy_match: bool = false, // set when any *? +? ?? is parsed
            \\};
            \\const _RFrag = struct {
            \\    start: u32, outs: [64]u32 = [_]u32{0xFFFF_FFFF} ** 64, n: u8 = 0,
            \\    fn one(s: u32, d: u32) _RFrag { var f = _RFrag{ .start = s }; f.outs[0] = d; f.n = 1; return f; }
            \\    fn two(s: u32, d1: u32, d2: u32) _RFrag { var f = _RFrag{ .start = s }; f.outs[0] = d1; f.outs[1] = d2; f.n = 2; return f; }
            \\    fn merge(a: _RFrag, b: _RFrag) _RFrag {
            \\        var f = _RFrag{ .start = a.start }; var i: u8 = 0;
            \\        for (a.outs[0..a.n]) |o| { f.outs[i] = o; i += 1; }
            \\        for (b.outs[0..b.n]) |o| { f.outs[i] = o; i += 1; }
            \\        f.n = i; return f;
            \\    }
            \\};
            \\const _RC = struct {
            \\    pat: []const u8, pos: usize = 0,
            \\    nodes: std.ArrayListUnmanaged(_RNode) = .{}, alloc: std.mem.Allocator, n_caps: u8 = 0, flags: _RFlags = .{},
            \\    fn addNode(c: *_RC, n: _RNode) error{OutOfMemory}!u32 {
            \\        const idx: u32 = @intCast(c.nodes.items.len);
            \\        try c.nodes.append(c.alloc, n); return idx;
            \\    }
            \\    fn patch(c: *_RC, f: _RFrag, t: u32) void {
            \\        for (f.outs[0..f.n]) |i| c.nodes.items[i & 0x7FFF_FFFF].out1 = t;
            \\    }
            \\    fn patchFrag(c: *_RC, f: _RFrag, t: u32) void {
            \\        for (f.outs[0..f.n]) |i| {
            \\            if (i & 0x8000_0000 != 0) c.nodes.items[i & 0x7FFF_FFFF].out2 = t
            \\            else c.nodes.items[i].out1 = t;
            \\        }
            \\    }
            \\    fn peek(c: *_RC) ?u8 { return if (c.pos < c.pat.len) c.pat[c.pos] else null; }
            \\    fn eat(c: *_RC) ?u8 { if (c.pos < c.pat.len) { defer c.pos += 1; return c.pat[c.pos]; } return null; }
            \\    fn expect(c: *_RC, ch: u8) bool { if (c.peek() == ch) { c.pos += 1; return true; } return false; }
            \\    fn parseClass(c: *_RC) error{OutOfMemory}![32]u8 {
            \\        var bits = [_]u8{0} ** 32;
            \\        while (c.peek()) |ch| {
            \\            if (ch == ']') break; _ = c.eat();
            \\            if (ch == '\\') { const esc = c.eat() orelse break; _rSetEsc(&bits, esc); }
            \\            else if (c.peek() == '-' and c.pos + 1 < c.pat.len and c.pat[c.pos + 1] != ']') {
            \\                _ = c.eat(); const hi = c.eat() orelse ch;
            \\                var i: u8 = ch; while (true) : (i += 1) { _rSetBit(&bits, i); if (i == hi) break; }
            \\            } else _rSetBit(&bits, ch);
            \\        } return bits;
            \\    }
            \\    fn parseAtom(c: *_RC) error{OutOfMemory}!?_RFrag {
            \\        const ch = c.peek() orelse return null;
            \\        switch (ch) {
            \\            '^' => { _ = c.eat(); const idx = try c.addNode(.{ .kind = .bol }); return _RFrag.one(idx, idx); },
            \\            '$' => { _ = c.eat(); const idx = try c.addNode(.{ .kind = .eol_a }); return _RFrag.one(idx, idx); },
            \\            '(' => {
            \\                _ = c.eat();
            \\                // Non-capturing group (?:...)
            \\                if (c.peek() == '?' and c.pos + 1 < c.pat.len and c.pat[c.pos + 1] == ':') {
            \\                    c.pos += 2;
            \\                    if (try c.parseAlt()) |inner| { _ = c.expect(')'); return inner; }
            \\                    _ = c.expect(')'); return null;
            \\                }
            \\                // Capturing group
            \\                const slot: u8 = c.n_caps * 2; c.n_caps += 1;
            \\                const open = try c.addNode(.{ .kind = .save, .slot = slot });
            \\                if (try c.parseAlt()) |inner| {
            \\                    c.patchFrag(inner, try c.addNode(.{ .kind = .save, .slot = slot + 1 }));
            \\                    _ = c.expect(')');
            \\                    const close: u32 = @intCast(c.nodes.items.len - 1);
            \\                    c.nodes.items[open].out1 = inner.start;
            \\                    return _RFrag.one(open, close);
            \\                }
            \\                _ = c.expect(')'); return _RFrag.one(open, open);
            \\            },
            \\            ')', '|' => return null,
            \\            '[' => {
            \\                _ = c.eat(); const neg = c.expect('^');
            \\                const bits = try c.parseClass(); _ = c.expect(']');
            \\                const idx = try c.addNode(.{ .kind = .cls, .bits = bits, .neg = neg });
            \\                return _RFrag.one(idx, idx);
            \\            },
            \\            '.' => { _ = c.eat(); const _di = try c.addNode(.{ .kind = .dot }); return _RFrag.one(_di, _di); },
            \\            '\\' => {
            \\                _ = c.eat(); const esc = c.eat() orelse return null;
            \\                // \b / \B are zero-width word-boundary assertions, not char classes
            \\                if (esc == 'b' or esc == 'B') {
            \\                    const idx = try c.addNode(.{ .kind = .wb, .neg = (esc == 'B') });
            \\                    return _RFrag.one(idx, idx);
            \\                }
            \\                var bits = [_]u8{0} ** 32;
            \\                const neg = std.ascii.isUpper(esc);
            \\                if (neg) { _rSetEsc(&bits, std.ascii.toLower(esc)); const pb = bits; bits = [_]u8{0} ** 32; for (&bits, pb) |*b, p| b.* = ~p; }
            \\                else _rSetEsc(&bits, esc);
            \\                const _ci = try c.addNode(.{ .kind = .cls, .bits = bits, .neg = false });
            \\                return _RFrag.one(_ci, _ci);
            \\            },
            \\            else => { _ = c.eat(); const idx = try c.addNode(.{ .kind = .lit, .c = ch }); return _RFrag.one(idx, idx); },
            \\        }
            \\    }
            \\    fn parsePieceFixed(c: *_RC) error{OutOfMemory}!?_RFrag {
            \\        const atom_pos = c.pos;
            \\        const atom = try c.parseAtom() orelse return null;
            \\        const q = c.peek() orelse return atom;
            \\        switch (q) {
            \\            '*' => {
            \\                _ = c.eat(); const lazy = c.expect('?');
            \\                if (lazy) c.flags.lazy_match = true;
            \\                const sp = try c.addNode(.{ .kind = .split,
            \\                    .out1 = if (lazy) 0xFFFF_FFFF else atom.start,
            \\                    .out2 = if (lazy) atom.start  else 0xFFFF_FFFF });
            \\                c.patch(atom, sp);
            \\                var f = _RFrag{ .start = sp };
            \\                f.outs[0] = if (lazy) sp else sp | 0x8000_0000; f.n = 1; return f;
            \\            },
            \\            '+' => {
            \\                _ = c.eat(); const lazy = c.expect('?');
            \\                if (lazy) c.flags.lazy_match = true;
            \\                const sp = try c.addNode(.{ .kind = .split,
            \\                    .out1 = if (lazy) 0xFFFF_FFFF else atom.start,
            \\                    .out2 = if (lazy) atom.start  else 0xFFFF_FFFF });
            \\                c.patch(atom, sp);
            \\                var f = _RFrag{ .start = atom.start };
            \\                f.outs[0] = if (lazy) sp else sp | 0x8000_0000; f.n = 1; return f;
            \\            },
            \\            '?' => {
            \\                _ = c.eat(); const lazy = c.expect('?');
            \\                if (lazy) c.flags.lazy_match = true;
            \\                const sp = try c.addNode(.{ .kind = .split,
            \\                    .out1 = if (lazy) 0xFFFF_FFFF else atom.start,
            \\                    .out2 = if (lazy) atom.start  else 0xFFFF_FFFF });
            \\                return if (lazy) _RFrag.two(sp, sp, atom.outs[0])
            \\                       else      _RFrag.two(sp, atom.outs[0], sp | 0x8000_0000);
            \\            },
            \\            '{' => {
            \\                _ = c.eat();
            \\                var n: u32 = 0;
            \\                while (c.peek()) |d| { if (d < '0' or d > '9') break; n = n *% 10 +% (d - '0'); _ = c.eat(); }
            \\                var m: u32 = n; var unbounded = false;
            \\                if (c.expect(',')) {
            \\                    if (c.peek() == '}') { unbounded = true; }
            \\                    else { m = 0; while (c.peek()) |d| { if (d < '0' or d > '9') break; m = m *% 10 +% (d - '0'); _ = c.eat(); } }
            \\                }
            \\                _ = c.expect('}');
            \\                if (!c.flags.unlimited) { if (n > 100) n = 100; if (m > 100) m = 100; }
            \\                if (n == 0 and m == 0 and !unbounded) return atom; // degenerate {0}
            \\                const after_q = c.pos;
            \\                // build result: start with the already-parsed atom (counts as copy 1)
            \\                var result: _RFrag = atom;
            \\                // mandatory copies 2..n
            \\                var i: u32 = 1;
            \\                while (i < n) : (i += 1) {
            \\                    c.pos = atom_pos; const next = try c.parseAtom() orelse break; c.pos = after_q;
            \\                    c.patchFrag(result, next.start);
            \\                    result = .{ .start = result.start, .outs = next.outs, .n = next.n };
            \\                }
            \\                // optional copies n+1..m
            \\                var j: u32 = 0;
            \\                while (j < m -| n) : (j += 1) {
            \\                    c.pos = atom_pos; const next = try c.parseAtom() orelse break; c.pos = after_q;
            \\                    const sp = try c.addNode(.{ .kind = .split, .out1 = next.start, .out2 = 0xFFFF_FFFF });
            \\                    c.patchFrag(result, sp);
            \\                    var f2 = _RFrag{ .start = result.start }; f2.outs[0] = next.outs[0]; f2.outs[1] = sp | 0x8000_0000; f2.n = 2; result = f2;
            \\                }
            \\                // unbounded: add * at end
            \\                if (unbounded) {
            \\                    c.pos = atom_pos; const last_a = try c.parseAtom() orelse { c.pos = after_q; return result; }; c.pos = after_q;
            \\                    const sp = try c.addNode(.{ .kind = .split, .out1 = last_a.start, .out2 = 0xFFFF_FFFF });
            \\                    c.patch(last_a, sp);
            \\                    c.patchFrag(result, sp);
            \\                    var f3 = _RFrag{ .start = result.start }; f3.outs[0] = sp | 0x8000_0000; f3.n = 1; return f3;
            \\                }
            \\                return result;
            \\            },
            \\            else => return atom,
            \\        }
            \\    }
            \\    fn parsePiece(c: *_RC) error{OutOfMemory}!?_RFrag { return c.parsePieceFixed(); }
            \\    fn parseCat(c: *_RC) error{OutOfMemory}!?_RFrag {
            \\        var result: ?_RFrag = try c.parsePiece();
            \\        while (result != null) {
            \\            const next = try c.parsePiece() orelse break;
            \\            c.patchFrag(result.?, next.start);
            \\            result = _RFrag{ .start = result.?.start, .outs = next.outs, .n = next.n };
            \\        }
            \\        return result;
            \\    }
            \\    fn parseAlt(c: *_RC) error{OutOfMemory}!?_RFrag {
            \\        const left = try c.parseCat() orelse return null;
            \\        if (c.peek() != '|') return left;
            \\        _ = c.eat();
            \\        const right = try c.parseAlt() orelse return left;
            \\        const sp = try c.addNode(.{ .kind = .split, .out1 = left.start, .out2 = right.start });
            \\        return _RFrag.merge(_RFrag{ .start = sp, .outs = left.outs, .n = left.n }, right);
            \\    }
            \\};
            \\const Regex = struct {
            \\    nodes: []_RNode, start: u32, alloc: std.mem.Allocator, flags: _RFlags = .{},
            \\    fn closure(re: *const Regex, cur: *std.ArrayListUnmanaged(u32), vis: []bool, alloc: std.mem.Allocator, idx: u32, pos: usize, input: []const u8) error{OutOfMemory}!void {
            \\        if (idx == 0xFFFF_FFFF or idx >= re.nodes.len or vis[idx]) return;
            \\        vis[idx] = true;
            \\        const nd = &re.nodes[idx];
            \\        switch (nd.kind) {
            \\            .split => { try re.closure(cur, vis, alloc, nd.out1, pos, input); try re.closure(cur, vis, alloc, nd.out2, pos, input); },
            \\            .save  => try re.closure(cur, vis, alloc, nd.out1, pos, input),
            \\            .bol   => {
            \\                const ok = pos == 0 or (re.flags.multiline and pos > 0 and input[pos - 1] == '\n');
            \\                if (ok) try re.closure(cur, vis, alloc, nd.out1, pos, input);
            \\            },
            \\            .eol_a => {
            \\                const ok = pos == input.len or (re.flags.multiline and pos < input.len and input[pos] == '\n');
            \\                if (ok) try re.closure(cur, vis, alloc, nd.out1, pos, input);
            \\            },
            \\            .wb => {
            \\                const pw = pos > 0 and _rIsWord(input[pos - 1]);
            \\                const cw = pos < input.len and _rIsWord(input[pos]);
            \\                if ((pw != cw) != nd.neg) try re.closure(cur, vis, alloc, nd.out1, pos, input);
            \\            },
            \\            else => try cur.append(alloc, idx),
            \\        }
            \\    }
            \\    fn matchAt(re: *const Regex, input: []const u8, from: usize, shortest: bool) error{OutOfMemory}!?usize {
            \\        const alloc = re.alloc;
            \\        var cur: std.ArrayListUnmanaged(u32) = .{}; var nxt: std.ArrayListUnmanaged(u32) = .{};
            \\        defer cur.deinit(alloc); defer nxt.deinit(alloc);
            \\        const vis = try alloc.alloc(bool, re.nodes.len); defer alloc.free(vis);
            \\        @memset(vis, false); try re.closure(&cur, vis, alloc, re.start, from, input);
            \\        var last: ?usize = null;
            \\        for (cur.items) |si| if (re.nodes[si].kind == .match) { last = from; if (shortest) return last; break; };
            \\        var pos = from;
            \\        while (pos < input.len and cur.items.len > 0) : (pos += 1) {
            \\            const ch = input[pos]; nxt.clearRetainingCapacity(); @memset(vis, false);
            \\            for (cur.items) |si| {
            \\                const nd = &re.nodes[si];
            \\                const ok = switch (nd.kind) {
            \\                    .lit => if (re.flags.ignore_case) std.ascii.toLower(nd.c) == std.ascii.toLower(ch) else nd.c == ch,
            \\                    .dot => if (re.flags.dot_all) true else ch != '\n',
            \\                    .cls => if (re.flags.ignore_case) _rClsMatch(nd, ch) or _rClsMatch(nd, std.ascii.toLower(ch)) or _rClsMatch(nd, std.ascii.toUpper(ch)) else _rClsMatch(nd, ch),
            \\                    else => false,
            \\                };
            \\                if (ok) try re.closure(&nxt, vis, alloc, nd.out1, pos + 1, input);
            \\            }
            \\            std.mem.swap(std.ArrayListUnmanaged(u32), &cur, &nxt);
            \\            for (cur.items) |si| if (re.nodes[si].kind == .match) { last = pos + 1; if (shortest) return last; break; };
            \\        }
            \\        return last;
            \\    }
            \\};
            \\fn _rSetBit(bits: *[32]u8, c: u8) void { bits[c >> 3] |= @as(u8, 1) << @intCast(c & 7); }
            \\fn _rGetBit(bits: *const [32]u8, c: u8) bool { return (bits[c >> 3] >> @intCast(c & 7)) & 1 != 0; }
            \\fn _rClsMatch(nd: *const _RNode, c: u8) bool { const h = _rGetBit(&nd.bits, c); return if (nd.neg) !h else h; }
            \\fn _rIsWord(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'; }
            \\fn _rSetEsc(bits: *[32]u8, esc: u8) void {
            \\    switch (std.ascii.toLower(esc)) {
            \\        'd' => { var i: u16 = '0'; while (i <= '9') : (i += 1) _rSetBit(bits, @intCast(i)); },
            \\        'w' => { var i: u16 = 'a'; while (i <= 'z') : (i += 1) _rSetBit(bits, @intCast(i)); i = 'A'; while (i <= 'Z') : (i += 1) _rSetBit(bits, @intCast(i)); i = '0'; while (i <= '9') : (i += 1) _rSetBit(bits, @intCast(i)); _rSetBit(bits, '_'); },
            \\        's' => { for (" \t\n\r") |c| _rSetBit(bits, c); },
            \\        'n' => _rSetBit(bits, '\n'), 'r' => _rSetBit(bits, '\r'), 't' => _rSetBit(bits, '\t'),
            \\        else => _rSetBit(bits, esc),
            \\    }
            \\}
            \\fn _regex_compile(pattern: []const u8, flags_str: []const u8) Regex {
            \\    const alloc = std.heap.page_allocator;
            \\    var flags = _RFlags{};
            \\    for (flags_str) |f| switch (f) {
            \\        'i' => flags.ignore_case = true, 'm' => flags.multiline = true,
            \\        's' => flags.dot_all = true,     'U' => flags.unlimited = true,
            \\        else => {},
            \\    };
            \\    var c = _RC{ .pat = pattern, .alloc = alloc, .flags = flags };
            \\    const frag_opt = c.parseAlt() catch @panic("regex OOM");
            \\    const match_idx = c.addNode(.{ .kind = .match }) catch @panic("regex OOM");
            \\    if (frag_opt) |frag| {
            \\        c.patchFrag(frag, match_idx);
            \\        return .{ .nodes = c.nodes.toOwnedSlice(alloc) catch @panic("regex OOM"), .start = frag.start, .alloc = alloc, .flags = c.flags };
            \\    }
            \\    return .{ .nodes = c.nodes.toOwnedSlice(alloc) catch @panic("regex OOM"), .start = match_idx, .alloc = alloc, .flags = c.flags };
            \\}
            \\fn _regex_match(re: Regex, input: []const u8) bool {
            \\    const end = re.matchAt(input, 0, false) catch return false;
            \\    return end != null and end.? == input.len;
            \\}
            \\fn _regex_find(re: Regex, input: []const u8) []const u8 {
            \\    var i: usize = 0;
            \\    while (i <= input.len) : (i += 1) {
            \\        if (re.matchAt(input, i, re.flags.lazy_match) catch null) |e| return input[i..e];
            \\    }
            \\    return "";
            \\}
            \\fn _regex_find_all(re: Regex, input: []const u8) []const []const u8 {
            \\    var out: std.ArrayListUnmanaged([]const u8) = .{};
            \\    var i: usize = 0;
            \\    while (i < input.len) {
            \\        if (re.matchAt(input, i, re.flags.lazy_match) catch null) |e| {
            \\            out.append(std.heap.page_allocator, input[i..e]) catch @panic("OOM");
            \\            i = if (e > i) e else i + 1;
            \\        } else i += 1;
            \\    }
            \\    return out.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM");
            \\}
            \\fn _regex_replace(re: Regex, input: []const u8, sub: []const u8) []const u8 {
            \\    var out: std.ArrayListUnmanaged(u8) = .{};
            \\    var i: usize = 0;
            \\    while (i < input.len) {
            \\        if (re.matchAt(input, i, re.flags.lazy_match) catch null) |e| {
            \\            out.appendSlice(std.heap.page_allocator, sub) catch @panic("OOM");
            \\            i = if (e > i) e else i + 1;
            \\        } else {
            \\            out.append(std.heap.page_allocator, input[i]) catch @panic("OOM");
            \\            i += 1;
            \\        }
            \\    }
            \\    return out.toOwnedSlice(std.heap.page_allocator) catch @panic("OOM");
            \\}
            \\
        );
        // ── Regex capture-group extraction ─────────────────────────────────────
        try g.w.writeAll(
            \\const _MAX_SAVE_SLOTS: usize = 20; // 10 capture groups (open+close slots each)
            \\const _RegThread = struct { state: u32, saves: [_MAX_SAVE_SLOTS]usize };
            \\// Epsilon closure that threads per-state save vectors through the NFA.
            \\// First-wins: if a state is already in cur, later paths are ignored
            \\// (leftmost-greedy semantics).
            \\fn _re_eclosure_s(
            \\    re: *const Regex, cur: *std.ArrayListUnmanaged(_RegThread),
            \\    vis: []bool, alloc: std.mem.Allocator,
            \\    state: u32, saves: [_MAX_SAVE_SLOTS]usize, pos: usize, input: []const u8,
            \\) std.mem.Allocator.Error!void {
            \\    if (state == 0xFFFF_FFFF or state >= re.nodes.len) return;
            \\    if (vis[state]) return;
            \\    vis[state] = true;
            \\    const nd = &re.nodes[state];
            \\    switch (nd.kind) {
            \\        .split => {
            \\            try _re_eclosure_s(re, cur, vis, alloc, nd.out1, saves, pos, input);
            \\            try _re_eclosure_s(re, cur, vis, alloc, nd.out2, saves, pos, input);
            \\        },
            \\        .save => {
            \\            var ns = saves;
            \\            if (nd.slot < _MAX_SAVE_SLOTS) ns[nd.slot] = pos;
            \\            try _re_eclosure_s(re, cur, vis, alloc, nd.out1, ns, pos, input);
            \\        },
            \\        .bol => {
            \\            const ok = pos == 0 or (re.flags.multiline and pos > 0 and input[pos - 1] == '\n');
            \\            if (ok) try _re_eclosure_s(re, cur, vis, alloc, nd.out1, saves, pos, input);
            \\        },
            \\        .eol_a => {
            \\            const ok = pos == input.len or (re.flags.multiline and pos < input.len and input[pos] == '\n');
            \\            if (ok) try _re_eclosure_s(re, cur, vis, alloc, nd.out1, saves, pos, input);
            \\        },
            \\        .wb => {
            \\            const pw = pos > 0 and _rIsWord(input[pos - 1]);
            \\            const cw = pos < input.len and _rIsWord(input[pos]);
            \\            if ((pw != cw) != nd.neg) try _re_eclosure_s(re, cur, vis, alloc, nd.out1, saves, pos, input);
            \\        },
            \\        else => try cur.append(alloc, .{ .state = state, .saves = saves }),
            \\    }
            \\}
            \\fn _re_match_with_saves(re: *const Regex, input: []const u8, from: usize) ?[_MAX_SAVE_SLOTS]usize {
            \\    const alloc = std.heap.page_allocator;
            \\    const empty: [_MAX_SAVE_SLOTS]usize = [_]usize{0xFFFF_FFFF_FFFF_FFFF} ** _MAX_SAVE_SLOTS;
            \\    var cur: std.ArrayListUnmanaged(_RegThread) = .{};
            \\    defer cur.deinit(alloc);
            \\    var nxt: std.ArrayListUnmanaged(_RegThread) = .{};
            \\    defer nxt.deinit(alloc);
            \\    const vis = alloc.alloc(bool, re.nodes.len) catch return null;
            \\    defer alloc.free(vis);
            \\    @memset(vis, false);
            \\    _re_eclosure_s(re, &cur, vis, alloc, re.start, empty, from, input) catch return null;
            \\    var last: ?[_MAX_SAVE_SLOTS]usize = null;
            \\    for (cur.items) |t| { if (re.nodes[t.state].kind == .match) { last = t.saves; if (re.flags.lazy_match) return last; break; } }
            \\    var pos = from;
            \\    while (pos < input.len and cur.items.len > 0) : (pos += 1) {
            \\        const ch = input[pos]; nxt.clearRetainingCapacity(); @memset(vis, false);
            \\        for (cur.items) |t| {
            \\            const nd = &re.nodes[t.state];
            \\            const ok = switch (nd.kind) {
            \\                .lit => if (re.flags.ignore_case) std.ascii.toLower(nd.c) == std.ascii.toLower(ch) else nd.c == ch,
            \\                .dot => if (re.flags.dot_all) true else ch != '\n',
            \\                .cls => if (re.flags.ignore_case) _rClsMatch(nd, ch) or _rClsMatch(nd, std.ascii.toLower(ch)) or _rClsMatch(nd, std.ascii.toUpper(ch)) else _rClsMatch(nd, ch),
            \\                else => false,
            \\            };
            \\            if (ok) _re_eclosure_s(re, &nxt, vis, alloc, nd.out1, t.saves, pos + 1, input) catch {};
            \\        }
            \\        std.mem.swap(std.ArrayListUnmanaged(_RegThread), &cur, &nxt);
            \\        for (cur.items) |t| { if (re.nodes[t.state].kind == .match) { last = t.saves; if (re.flags.lazy_match) return last; break; } }
            \\    }
            \\    return last;
            \\}
            \\fn _regex_groups(re: Regex, input: []const u8) []const []const u8 {
            \\    const alloc = std.heap.page_allocator;
            \\    var start: usize = 0;
            \\    while (start <= input.len) : (start += 1) {
            \\        if (_re_match_with_saves(&re, input, start)) |saves| {
            \\            var out: std.ArrayListUnmanaged([]const u8) = .{};
            \\            var i: usize = 0;
            \\            while (i + 1 < _MAX_SAVE_SLOTS) : (i += 2) {
            \\                const s = saves[i]; const e = saves[i + 1];
            \\                if (s == 0xFFFF_FFFF_FFFF_FFFF) break;
            \\                if (e != 0xFFFF_FFFF_FFFF_FFFF and e >= s) out.append(alloc, input[s..e]) catch {};
            \\            }
            \\            return out.toOwnedSlice(alloc) catch &.{};
            \\        }
            \\    }
            \\    return &.{};
            \\}
            \\
        );

        // ── GUI: _GuiBackend fn-ptr isolation + GuiContext stable surface ──────
        try g.w.writeAll(
            \\// ─── GUI: backend isolation ──────────────────────────────────────────────────
            \\// _GuiBackend is an fn-ptr struct.  Swap `_gui_active_backend` to change
            \\// the renderer without touching user code or GuiContext.
            \\const _GuiBackend = struct {
            \\    initFn:        *const fn (title: []const u8, width: i64, height: i64) anyerror!void,
            \\    deinitFn:      *const fn () void,
            \\    newFrameFn:    *const fn () bool,
            \\    endFrameFn:    *const fn () void,
            \\    textFn:        *const fn (s: []const u8) void,
            \\    separatorFn:   *const fn () void,
            \\    sameLineFn:    *const fn () void,
            \\    spacingFn:     *const fn () void,
            \\    indentFn:      *const fn () void,
            \\    unindentFn:    *const fn () void,
            \\    buttonFn:      *const fn (label: []const u8) bool,
            \\    checkboxFn:    *const fn (label: []const u8, value: bool) bool,
            \\    sliderFn:      *const fn (label: []const u8, value: f64, min: f64, max: f64) f64,
            \\    inputFn:       *const fn (label: []const u8, value: []const u8) []const u8,
            \\    inputMultilineFn: *const fn (label: []const u8, value: []const u8, width: f64, height: f64) []const u8,
            \\    beginPanelFn:  *const fn (label: []const u8) bool,
            \\    endPanelFn:    *const fn () void,
            \\    beginWindowFn: *const fn (label: []const u8) bool,
            \\    endWindowFn:   *const fn () void,
            \\};
            \\const GuiContext = struct {
            \\    _b: *const _GuiBackend,
            \\    pub fn text(self: GuiContext, s: []const u8) void { self._b.textFn(s); }
            \\    pub fn separator(self: GuiContext) void { self._b.separatorFn(); }
            \\    pub fn sameLine(self: GuiContext) void { self._b.sameLineFn(); }
            \\    pub fn spacing(self: GuiContext) void { self._b.spacingFn(); }
            \\    pub fn indent(self: GuiContext) void { self._b.indentFn(); }
            \\    pub fn unindent(self: GuiContext) void { self._b.unindentFn(); }
            \\    pub fn button(self: GuiContext, label: []const u8) bool { return self._b.buttonFn(label); }
            \\    pub fn checkbox(self: GuiContext, label: []const u8, value: bool) bool { return self._b.checkboxFn(label, value); }
            \\    pub fn slider(self: GuiContext, label: []const u8, value: f64, min: f64, max: f64) f64 { return self._b.sliderFn(label, value, min, max); }
            \\    pub fn input(self: GuiContext, label: []const u8, value: []const u8) []const u8 { return self._b.inputFn(label, value); }
            \\    pub fn inputMultiline(self: GuiContext, label: []const u8, value: []const u8, width: f64, height: f64) []const u8 { return self._b.inputMultilineFn(label, value, width, height); }
            \\    pub fn panel(self: GuiContext, label: []const u8, callback: anytype) void {
            \\        if (self._b.beginPanelFn(label)) {
            \\            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            \\            self._b.endPanelFn();
            \\        }
            \\    }
            \\    pub fn window(self: GuiContext, label: []const u8, callback: anytype) void {
            \\        if (self._b.beginWindowFn(label)) {
            \\            if (comptime @typeInfo(@TypeOf(callback)) == .@"fn") callback(self) else callback.call(self);
            \\            self._b.endWindowFn();
            \\        }
            \\    }
            \\};
            \\fn _gui_run(title: []const u8, width: i64, height: i64, frame: anytype) void {
            \\    _gui_active_backend.initFn(title, width, height) catch @panic("gui init failed");
            \\    defer _gui_active_backend.deinitFn();
            \\    const _g = GuiContext{ ._b = &_gui_active_backend };
            \\    if (comptime @typeInfo(@TypeOf(frame)) == .@"fn") {
            \\        while (_gui_active_backend.newFrameFn()) {
            \\            frame(_g);
            \\            _gui_active_backend.endFrameFn();
            \\        }
            \\    } else {
            \\        var _mframe = frame;
            \\        while (_gui_active_backend.newFrameFn()) {
            \\            _mframe.call(_g);
            \\            _gui_active_backend.endFrameFn();
            \\        }
            \\    }
            \\}
            \\
        );
        // ── Backend-specific implementation ────────────────────────────────────
        switch (g.gui_backend) {
            .stub => try g.w.writeAll(
                \\// ─── Stub backend (single frame, prints to stderr) ───────────────────────────
                \\fn _stub_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    _ = title; _ = width; _ = height;
                \\}
                \\fn _stub_deinit() void {}
                \\var _stub_frame_count: u8 = 0;
                \\fn _stub_new_frame() bool {
                \\    if (_stub_frame_count >= 1) return false;
                \\    _stub_frame_count += 1;
                \\    return true;
                \\}
                \\fn _stub_end_frame() void {}
                \\fn _stub_text(s: []const u8) void { std.debug.print("[gui] text: {s}\n", .{s}); }
                \\fn _stub_separator() void { std.debug.print("[gui] ---\n", .{}); }
                \\fn _stub_same_line() void { std.debug.print("[gui] sameLine\n", .{}); }
                \\fn _stub_spacing() void { std.debug.print("[gui] spacing\n", .{}); }
                \\fn _stub_indent() void { std.debug.print("[gui] indent\n", .{}); }
                \\fn _stub_unindent() void { std.debug.print("[gui] unindent\n", .{}); }
                \\fn _stub_button(label: []const u8) bool {
                \\    std.debug.print("[gui] button: {s}\n", .{label});
                \\    return false;
                \\}
                \\fn _stub_checkbox(label: []const u8, value: bool) bool {
                \\    std.debug.print("[gui] checkbox: {s} = {}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    std.debug.print("[gui] slider: {s} = {d} [{d}, {d}]\n", .{ label, value, min, max });
                \\    return value;
                \\}
                \\fn _stub_input(label: []const u8, value: []const u8) []const u8 {
                \\    std.debug.print("[gui] input: {s} = {s}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_input_multiline(label: []const u8, value: []const u8, width: f64, height: f64) []const u8 {
                \\    std.debug.print("[gui] inputMultiline: {s} ({d}x{d})\n", .{ label, width, height });
                \\    return value;
                \\}
                \\fn _stub_begin_panel(label: []const u8) bool {
                \\    std.debug.print("[gui] panel: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_panel() void {}
                \\fn _stub_begin_window(label: []const u8) bool {
                \\    std.debug.print("[gui] window: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_window() void {}
                \\const _gui_stub_backend = _GuiBackend{
                \\    .initFn        = _stub_init,
                \\    .deinitFn      = _stub_deinit,
                \\    .newFrameFn    = _stub_new_frame,
                \\    .endFrameFn    = _stub_end_frame,
                \\    .textFn        = _stub_text,
                \\    .separatorFn   = _stub_separator,
                \\    .sameLineFn    = _stub_same_line,
                \\    .spacingFn     = _stub_spacing,
                \\    .indentFn      = _stub_indent,
                \\    .unindentFn    = _stub_unindent,
                \\    .buttonFn      = _stub_button,
                \\    .checkboxFn    = _stub_checkbox,
                \\    .sliderFn      = _stub_slider,
                \\    .inputFn       = _stub_input,
                \\    .inputMultilineFn = _stub_input_multiline,
                \\    .beginPanelFn  = _stub_begin_panel,
                \\    .endPanelFn    = _stub_end_panel,
                \\    .beginWindowFn = _stub_begin_window,
                \\    .endWindowFn   = _stub_end_window,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_stub_backend;
                \\
            ),
            // ── zgui GLFW+OpenGL3 backend ──────────────────────────────────────
            // Requires a `zig build` project (not bare `zig run`).
            // main.zig wires up a generated project dir when uses_gui is true.
            .glfw => try g.w.writeAll(
                \\// ─── zgui GLFW+OpenGL3 backend ──────────────────────────────────────────────
                \\const zgui    = @import("zgui");
                \\const zglfw   = @import("zglfw");
                \\const zopengl = @import("zopengl");
                \\var _gl_window: *zglfw.Window = undefined;
                \\fn _imgui_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    try zglfw.init();
                \\    errdefer zglfw.terminate();
                \\    zglfw.windowHint(.context_version_major, 3);
                \\    zglfw.windowHint(.context_version_minor, 3);
                \\    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
                \\    const _title_z = try _allocator.dupeZ(u8, title);
                \\    defer _allocator.free(_title_z);
                \\    _gl_window = try zglfw.createWindow(
                \\        @intCast(width), @intCast(height), _title_z, null, null,
                \\    );
                \\    errdefer _gl_window.destroy();
                \\    zglfw.makeContextCurrent(_gl_window);
                \\    zglfw.swapInterval(1);
                \\    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);
                \\    zgui.init(_allocator);
                \\    zgui.backend.init(_gl_window);
                \\}
                \\fn _imgui_deinit() void {
                \\    zgui.backend.deinit();
                \\    zgui.deinit();
                \\    _gl_window.destroy();
                \\    zglfw.terminate();
                \\}
                \\fn _imgui_new_frame() bool {
                \\    zglfw.pollEvents();
                \\    if (_gl_window.shouldClose()) return false;
                \\    const _fb = _gl_window.getFramebufferSize();
                \\    zgui.backend.newFrame(@intCast(_fb[0]), @intCast(_fb[1]));
                \\    // Auto-wrap all frame widgets in a fullscreen borderless window.
                \\    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
                \\    zgui.setNextWindowSize(.{ .w = @floatFromInt(_fb[0]), .h = @floatFromInt(_fb[1]) });
                \\    _ = zgui.begin("##_main", .{ .flags = .{
                \\        .no_title_bar = true, .no_resize = true,
                \\        .no_move = true,      .no_collapse = true,
                \\    }});
                \\    return true;
                \\}
                \\fn _imgui_end_frame() void {
                \\    zgui.end();
                \\    const _fb = _gl_window.getFramebufferSize();
                \\    zopengl.bindings.viewport(0, 0, _fb[0], _fb[1]);
                \\    zopengl.bindings.clearColor(0.1, 0.1, 0.1, 1.0);
                \\    zopengl.bindings.clear(zopengl.bindings.COLOR_BUFFER_BIT);
                \\    zgui.backend.draw();
                \\    _gl_window.swapBuffers();
                \\}
                \\fn _imgui_text(s: []const u8) void { zgui.textUnformatted(s); }
                \\fn _imgui_separator() void { zgui.separator(); }
                \\fn _imgui_same_line() void { zgui.sameLine(.{}); }
                \\fn _imgui_spacing() void { zgui.spacing(); }
                \\fn _imgui_indent() void { zgui.indent(.{}); }
                \\fn _imgui_unindent() void { zgui.unindent(.{}); }
                \\fn _imgui_button(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return false;
                \\    defer _allocator.free(_z);
                \\    return zgui.button(_z, .{});
                \\}
                \\fn _imgui_checkbox(label: []const u8, value: bool) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _v = value;
                \\    _ = zgui.checkbox(_z, .{ .v = &_v });
                \\    return _v;
                \\}
                \\fn _imgui_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _v: f32 = @floatCast(value);
                \\    _ = zgui.sliderFloat(_z, .{ .v = &_v, .min = @floatCast(min), .max = @floatCast(max) });
                \\    return @floatCast(_v);
                \\}
                \\fn _imgui_input(label: []const u8, value: []const u8) []const u8 {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _buf: [256:0]u8 = @splat(0);
                \\    const _n = @min(value.len, _buf.len - 1);
                \\    @memcpy(_buf[0.._n], value[0.._n]);
                \\    if (zgui.inputText(_z, .{ .buf = &_buf })) {
                \\        const _len = std.mem.indexOfScalar(u8, &_buf, 0) orelse _buf.len;
                \\        return _allocator.dupe(u8, _buf[0.._len]) catch value;
                \\    }
                \\    return value;
                \\}
                \\fn _imgui_input_multiline(label: []const u8, value: []const u8, width: f64, height: f64) []const u8 {
                \\    const _z = _allocator.dupeZ(u8, label) catch return value;
                \\    defer _allocator.free(_z);
                \\    var _buf: [65536:0]u8 = @splat(0);
                \\    const _n = @min(value.len, _buf.len - 1);
                \\    @memcpy(_buf[0.._n], value[0.._n]);
                \\    if (zgui.inputTextMultiline(_z, .{ .buf = &_buf, .w = @floatCast(width), .h = @floatCast(height) })) {
                \\        const _len = std.mem.indexOfScalar(u8, &_buf, 0) orelse _buf.len;
                \\        return _allocator.dupe(u8, _buf[0.._len]) catch value;
                \\    }
                \\    return value;
                \\}
                \\fn _imgui_begin_panel(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return true;
                \\    defer _allocator.free(_z);
                \\    return zgui.collapsingHeader(_z, .{});
                \\}
                \\fn _imgui_end_panel() void {}
                \\fn _imgui_begin_window(label: []const u8) bool {
                \\    const _z = _allocator.dupeZ(u8, label) catch return true;
                \\    defer _allocator.free(_z);
                \\    return zgui.begin(_z, .{});
                \\}
                \\fn _imgui_end_window() void { zgui.end(); }
                \\const _gui_imgui_backend = _GuiBackend{
                \\    .initFn        = _imgui_init,
                \\    .deinitFn      = _imgui_deinit,
                \\    .newFrameFn    = _imgui_new_frame,
                \\    .endFrameFn    = _imgui_end_frame,
                \\    .textFn        = _imgui_text,
                \\    .separatorFn   = _imgui_separator,
                \\    .sameLineFn    = _imgui_same_line,
                \\    .spacingFn     = _imgui_spacing,
                \\    .indentFn      = _imgui_indent,
                \\    .unindentFn    = _imgui_unindent,
                \\    .buttonFn      = _imgui_button,
                \\    .checkboxFn    = _imgui_checkbox,
                \\    .sliderFn      = _imgui_slider,
                \\    .inputFn       = _imgui_input,
                \\    .inputMultilineFn = _imgui_input_multiline,
                \\    .beginPanelFn  = _imgui_begin_panel,
                \\    .endPanelFn    = _imgui_end_panel,
                \\    .beginWindowFn = _imgui_begin_window,
                \\    .endWindowFn   = _imgui_end_window,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_imgui_backend;
                \\
            ),
            // sdl2 / dx12 not yet implemented — fall through to stub.
            .sdl2, .dx12 => try g.w.writeAll(
                \\// TODO: sdl2/dx12 GUI backend not yet implemented; using stub.
                \\fn _stub_init(title: []const u8, width: i64, height: i64) anyerror!void {
                \\    _ = title; _ = width; _ = height;
                \\}
                \\fn _stub_deinit() void {}
                \\var _stub_frame_count: u8 = 0;
                \\fn _stub_new_frame() bool {
                \\    if (_stub_frame_count >= 1) return false;
                \\    _stub_frame_count += 1;
                \\    return true;
                \\}
                \\fn _stub_end_frame() void {}
                \\fn _stub_text(s: []const u8) void { std.debug.print("[gui] text: {s}\n", .{s}); }
                \\fn _stub_separator() void { std.debug.print("[gui] ---\n", .{}); }
                \\fn _stub_same_line() void { std.debug.print("[gui] sameLine\n", .{}); }
                \\fn _stub_spacing() void { std.debug.print("[gui] spacing\n", .{}); }
                \\fn _stub_indent() void { std.debug.print("[gui] indent\n", .{}); }
                \\fn _stub_unindent() void { std.debug.print("[gui] unindent\n", .{}); }
                \\fn _stub_button(label: []const u8) bool {
                \\    std.debug.print("[gui] button: {s}\n", .{label});
                \\    return false;
                \\}
                \\fn _stub_checkbox(label: []const u8, value: bool) bool {
                \\    std.debug.print("[gui] checkbox: {s} = {}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_slider(label: []const u8, value: f64, min: f64, max: f64) f64 {
                \\    std.debug.print("[gui] slider: {s} = {d} [{d}, {d}]\n", .{ label, value, min, max });
                \\    return value;
                \\}
                \\fn _stub_input(label: []const u8, value: []const u8) []const u8 {
                \\    std.debug.print("[gui] input: {s} = {s}\n", .{ label, value });
                \\    return value;
                \\}
                \\fn _stub_input_multiline(label: []const u8, value: []const u8, width: f64, height: f64) []const u8 {
                \\    std.debug.print("[gui] inputMultiline: {s} ({d}x{d})\n", .{ label, width, height });
                \\    return value;
                \\}
                \\fn _stub_begin_panel(label: []const u8) bool {
                \\    std.debug.print("[gui] panel: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_panel() void {}
                \\fn _stub_begin_window(label: []const u8) bool {
                \\    std.debug.print("[gui] window: {s}\n", .{label});
                \\    return true;
                \\}
                \\fn _stub_end_window() void {}
                \\const _gui_stub_backend = _GuiBackend{
                \\    .initFn        = _stub_init,
                \\    .deinitFn      = _stub_deinit,
                \\    .newFrameFn    = _stub_new_frame,
                \\    .endFrameFn    = _stub_end_frame,
                \\    .textFn        = _stub_text,
                \\    .separatorFn   = _stub_separator,
                \\    .sameLineFn    = _stub_same_line,
                \\    .spacingFn     = _stub_spacing,
                \\    .indentFn      = _stub_indent,
                \\    .unindentFn    = _stub_unindent,
                \\    .buttonFn      = _stub_button,
                \\    .checkboxFn    = _stub_checkbox,
                \\    .sliderFn      = _stub_slider,
                \\    .inputFn       = _stub_input,
                \\    .inputMultilineFn = _stub_input_multiline,
                \\    .beginPanelFn  = _stub_begin_panel,
                \\    .endPanelFn    = _stub_end_panel,
                \\    .beginWindowFn = _stub_begin_window,
                \\    .endWindowFn   = _stub_end_window,
                \\};
                \\const _gui_active_backend: _GuiBackend = _gui_stub_backend;
                \\
            ),
        }

        // ── Hash stdlib ─────────────────────────────────────────────────────────
        // All hash functions return a hex-encoded string.
        try g.w.writeAll(
            \\fn _hex_encode(bytes: []const u8) []const u8 {
            \\    const _hx = "0123456789abcdef";
            \\    var out = _allocator.alloc(u8, bytes.len * 2) catch return "";
            \\    for (bytes, 0..) |b, i| { out[i*2] = _hx[b >> 4]; out[i*2+1] = _hx[b & 0xf]; }
            \\    return out;
            \\}
            \\fn _hash_sha256(data: []const u8) []const u8 {
            \\    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            \\    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
            \\    return _hex_encode(&out);
            \\}
            \\fn _hash_sha512(data: []const u8) []const u8 {
            \\    var out: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            \\    std.crypto.hash.sha2.Sha512.hash(data, &out, .{});
            \\    return _hex_encode(&out);
            \\}
            \\fn _hash_md5(data: []const u8) []const u8 {
            \\    var out: [std.crypto.hash.Md5.digest_length]u8 = undefined;
            \\    std.crypto.hash.Md5.hash(data, &out, .{});
            \\    return _hex_encode(&out);
            \\}
            \\fn _hash_blake3(data: []const u8) []const u8 {
            \\    var out: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            \\    std.crypto.hash.Blake3.hash(data, &out, .{});
            \\    return _hex_encode(&out);
            \\}
            \\fn _hash_hmac256(key: []const u8, data: []const u8) []const u8 {
            \\    var out: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
            \\    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
            \\    return _hex_encode(&out);
            \\}
            \\
        );
        // ── Random stdlib ───────────────────────────────────────────────────────
        // Xoshiro256 PRNG seeded from std.crypto.random on first use.
        try g.w.writeAll(
            \\var _rng_inst: std.Random.DefaultPrng = undefined;
            \\var _rng_ready: bool = false;
            \\fn _rng() std.Random {
            \\    if (!_rng_ready) {
            \\        var seed: u64 = 0;
            \\        std.crypto.random.bytes(std.mem.asBytes(&seed));
            \\        _rng_inst = std.Random.DefaultPrng.init(seed);
            \\        _rng_ready = true;
            \\    }
            \\    return _rng_inst.random();
            \\}
            \\fn _random_int(mn: i64, mx: i64) i64 { return _rng().intRangeAtMost(i64, mn, mx); }
            \\fn _random_float() f64               { return _rng().float(f64); }
            \\fn _random_bool() bool               { return _rng().boolean(); }
            \\fn _random_bytes(n: i64) []const u8 {
            \\    const len: usize = @intCast(if (n < 0) 0 else n);
            \\    const buf = _allocator.alloc(u8, len) catch return "";
            \\    _rng().bytes(buf);
            \\    return _hex_encode(buf);
            \\}
            \\fn _random_seed(s: i64) void {
            \\    _rng_inst = std.Random.DefaultPrng.init(@bitCast(s));
            \\    _rng_ready = true;
            \\}
            \\
        );
        // ── Arg stdlib ──────────────────────────────────────────────────────────
        // Parses argv into a simple flag/option/positional structure.
        try g.w.writeAll(
            \\const ArgResult = struct {
            \\    _raw: []const []const u8,
            \\    pub fn flag(self: ArgResult, long: []const u8, short: []const u8) bool {
            \\        for (self._raw) |a| { if (std.mem.eql(u8, a, long)) return true; if (std.mem.eql(u8, a, short)) return true; }
            \\        return false;
            \\    }
            \\    pub fn contains(self: ArgResult, name_: []const u8) bool {
            \\        for (self._raw) |a| { if (std.mem.eql(u8, a, name_)) return true; }
            \\        return false;
            \\    }
            \\    pub fn option(self: ArgResult, name_: []const u8, default_val: []const u8) []const u8 {
            \\        var i: usize = 0;
            \\        while (i + 1 < self._raw.len) : (i += 1) {
            \\            if (std.mem.eql(u8, self._raw[i], name_)) return self._raw[i + 1];
            \\        }
            \\        return default_val;
            \\    }
            \\    pub fn optionInt(self: ArgResult, name_: []const u8, default_val: i64) i64 {
            \\        const s = self.option(name_, "");
            \\        if (s.len == 0) return default_val;
            \\        return std.fmt.parseInt(i64, s, 10) catch default_val;
            \\    }
            \\    pub fn positional(self: ArgResult, idx: i64) ?[]const u8 {
            \\        var pos: usize = 0;
            \\        for (self._raw) |a| {
            \\            if (!std.mem.startsWith(u8, a, "-")) {
            \\                if (pos == @as(usize, @intCast(idx))) return a;
            \\                pos += 1;
            \\            }
            \\        }
            \\        return null;
            \\    }
            \\    pub fn usage(_: ArgResult) []const u8 { return "Usage: program [options]"; }
            \\};
            \\fn _arg_parse() ArgResult {
            \\    const _argv = std.process.argsAlloc(_allocator) catch return ArgResult{ ._raw = &.{} };
            \\    const _raw_slice = if (_argv.len > 1) _argv[1..] else _argv[0..0];
            \\    var _out = _allocator.alloc([]const u8, _raw_slice.len) catch return ArgResult{ ._raw = &.{} };
            \\    for (_raw_slice, 0..) |a, i| _out[i] = a;
            \\    return ArgResult{ ._raw = _out };
            \\}
            \\
        );
        // ── Terminal stdlib ─────────────────────────────────────────────────────
        // ANSI color output; falls back to plain print when not a TTY.
        try g.w.writeAll(
            \\fn _term_is_tty() bool {
            \\    const cfg = std.io.tty.detectConfig(std.fs.File.stdout());
            \\    return cfg != .no_color;
            \\}
            \\fn _term_width() i64 { return 80; }
            \\fn _term_height() i64 { return 24; }
            \\fn _term_ansi(color: []const u8) []const u8 {
            \\    if (std.mem.eql(u8, color, "red"))     return "\x1b[31m";
            \\    if (std.mem.eql(u8, color, "green"))   return "\x1b[32m";
            \\    if (std.mem.eql(u8, color, "yellow"))  return "\x1b[33m";
            \\    if (std.mem.eql(u8, color, "blue"))    return "\x1b[34m";
            \\    if (std.mem.eql(u8, color, "magenta")) return "\x1b[35m";
            \\    if (std.mem.eql(u8, color, "cyan"))    return "\x1b[36m";
            \\    if (std.mem.eql(u8, color, "white"))   return "\x1b[37m";
            \\    if (std.mem.eql(u8, color, "dim"))     return "\x1b[2m";
            \\    if (std.mem.eql(u8, color, "bold"))    return "\x1b[1m";
            \\    return "";
            \\}
            \\fn _term_print(msg: []const u8, color: []const u8, newline: bool) void {
            \\    const _f = std.fs.File.stdout();
            \\    if (_term_is_tty() and color.len > 0) {
            \\        _f.deprecatedWriter().print("{s}{s}\x1b[0m", .{ _term_ansi(color), msg }) catch {};
            \\    } else {
            \\        _f.deprecatedWriter().writeAll(msg) catch {};
            \\    }
            \\    if (newline) _f.deprecatedWriter().writeByte('\n') catch {};
            \\}
            \\
        );
        // ── Log stdlib ──────────────────────────────────────────────────────────
        // Leveled logging: debug(0) < info(1) < warn(2) < err(3).
        try g.w.writeAll(
            \\var _log_level: u8 = 1;        // default: info
            \\var _log_timestamps: bool = true;
            \\var _log_to_stderr: bool = true;
            \\fn _log_ts() []const u8 {
            \\    const sec = @divFloor(std.time.milliTimestamp(), 1000);
            \\    const s = sec - 62135596800; // offset from Unix epoch to .NET epoch (unused here)
            \\    _ = s;
            \\    return std.fmt.allocPrint(_allocator, "{d}", .{sec}) catch "?";
            \\}
            \\fn _log_emit(level_str: []const u8, level_num: u8, msg: []const u8) void {
            \\    if (level_num < _log_level) return;
            \\    const _lw = if (_log_to_stderr) std.fs.File.stderr().deprecatedWriter() else std.fs.File.stdout().deprecatedWriter();
            \\    if (_log_timestamps) {
            \\        _lw.print("[{s:<5} {s}] {s}\n", .{ level_str, _log_ts(), msg }) catch {};
            \\    } else {
            \\        _lw.print("[{s:<5}] {s}\n", .{ level_str, msg }) catch {};
            \\    }
            \\}
            \\fn _log_debug(msg: []const u8) void { _log_emit("DEBUG", 0, msg); }
            \\fn _log_info(msg: []const u8) void  { _log_emit("INFO",  1, msg); }
            \\fn _log_warn(msg: []const u8) void  { _log_emit("WARN",  2, msg); }
            \\fn _log_err(msg: []const u8) void   { _log_emit("ERR",   3, msg); }
            \\fn _log_set_level(l: u8) void { _log_level = l; }
            \\fn _log_set_output_stderr(v: bool) void { _log_to_stderr = v; }
            \\fn _log_timestamp(v: bool) void { _log_timestamps = v; }
            \\
        );
        // ── Uri stdlib ──────────────────────────────────────────────────────────
        // Parses a URI string into scheme/host/path/query/port components.
        try g.w.writeAll(
            \\const UriResult = struct {
            \\    scheme: []const u8,
            \\    host:   []const u8,
            \\    path:   []const u8,
            \\    query:  []const u8,
            \\    port:   i64,
            \\};
            \\fn _uri_parse(url: []const u8) UriResult {
            \\    const _u = std.Uri.parse(url) catch return UriResult{ .scheme="", .host="", .path="", .query="", .port=0 };
            \\    const _host: []const u8 = if (_u.host) |h| switch (h) {
            \\        .raw => |r| r, .percent_encoded => |p| p,
            \\    } else "";
            \\    const _path: []const u8 = switch (_u.path) {
            \\        .raw => |r| r, .percent_encoded => |p| p,
            \\    };
            \\    const _query: []const u8 = if (_u.query) |q| switch (q) {
            \\        .raw => |r| r, .percent_encoded => |p| p,
            \\    } else "";
            \\    return UriResult{
            \\        .scheme = _u.scheme,
            \\        .host   = _host,
            \\        .path   = _path,
            \\        .query  = _query,
            \\        .port   = if (_u.port) |p| @intCast(p) else 0,
            \\    };
            \\}
            \\
        );
        // ── Compress stdlib ─────────────────────────────────────────────────────
        // gzip is stubbed (std.compress.flate.Compress not yet implemented in Zig 0.15.2).
        // gunzip uses std.compress.flate.Decompress; returns null on failure.
        try g.w.writeAll(
            \\fn _compress_gzip(_: []const u8) []const u8 { return ""; }
            \\fn _compress_gunzip(data: []const u8) ?[]const u8 {
            \\    var _in = std.Io.Reader.fixed(data);
            \\    var _window: [std.compress.flate.max_window_len]u8 = undefined;
            \\    var _decomp = std.compress.flate.Decompress.init(&_in, .gzip, &_window);
            \\    return _decomp.reader.allocRemaining(_allocator, .unlimited) catch null;
            \\}
            \\
        );
        // ── Mime stdlib ─────────────────────────────────────────────────────────
        // Static extension ↔ MIME type lookup tables.
        try g.w.writeAll(
            \\fn _mime_from_ext(ext: []const u8) []const u8 {
            \\    const _map = [_]struct { []const u8, []const u8 }{
            \\        .{ ".html",  "text/html" },          .{ ".htm",   "text/html" },
            \\        .{ ".css",   "text/css" },
            \\        .{ ".js",    "text/javascript" },    .{ ".mjs",   "text/javascript" },
            \\        .{ ".ts",    "text/typescript" },
            \\        .{ ".json",  "application/json" },
            \\        .{ ".xml",   "application/xml" },
            \\        .{ ".txt",   "text/plain" },
            \\        .{ ".csv",   "text/csv" },
            \\        .{ ".md",    "text/markdown" },
            \\        .{ ".png",   "image/png" },
            \\        .{ ".jpg",   "image/jpeg" },         .{ ".jpeg",  "image/jpeg" },
            \\        .{ ".gif",   "image/gif" },
            \\        .{ ".svg",   "image/svg+xml" },
            \\        .{ ".ico",   "image/x-icon" },
            \\        .{ ".webp",  "image/webp" },
            \\        .{ ".pdf",   "application/pdf" },
            \\        .{ ".zip",   "application/zip" },
            \\        .{ ".gz",    "application/gzip" },
            \\        .{ ".tar",   "application/x-tar" },
            \\        .{ ".mp3",   "audio/mpeg" },
            \\        .{ ".mp4",   "video/mp4" },
            \\        .{ ".wav",   "audio/wav" },
            \\        .{ ".ogg",   "audio/ogg" },
            \\        .{ ".webm",  "video/webm" },
            \\        .{ ".wasm",  "application/wasm" },
            \\        .{ ".ttf",   "font/ttf" },
            \\        .{ ".woff",  "font/woff" },
            \\        .{ ".woff2", "font/woff2" },
            \\    };
            \\    for (_map) |e| if (std.mem.eql(u8, e[0], ext)) return e[1];
            \\    return "application/octet-stream";
            \\}
            \\fn _mime_to_ext(mime: []const u8) []const u8 {
            \\    const _map = [_]struct { []const u8, []const u8 }{
            \\        .{ "text/html",        ".html" },
            \\        .{ "text/css",         ".css"  },
            \\        .{ "text/javascript",  ".js"   },
            \\        .{ "text/plain",       ".txt"  },
            \\        .{ "text/csv",         ".csv"  },
            \\        .{ "text/markdown",    ".md"   },
            \\        .{ "application/json", ".json" },
            \\        .{ "application/xml",  ".xml"  },
            \\        .{ "application/pdf",  ".pdf"  },
            \\        .{ "application/zip",  ".zip"  },
            \\        .{ "application/gzip", ".gz"   },
            \\        .{ "application/wasm", ".wasm" },
            \\        .{ "image/png",        ".png"  },
            \\        .{ "image/jpeg",       ".jpg"  },
            \\        .{ "image/gif",        ".gif"  },
            \\        .{ "image/svg+xml",    ".svg"  },
            \\        .{ "image/webp",       ".webp" },
            \\        .{ "audio/mpeg",       ".mp3"  },
            \\        .{ "audio/wav",        ".wav"  },
            \\        .{ "video/mp4",        ".mp4"  },
            \\    };
            \\    for (_map) |e| if (std.mem.eql(u8, e[0], mime)) return e[1];
            \\    return "";
            \\}
            \\
        );
        // ── Timer stdlib ────────────────────────────────────────────────────────
        // High-resolution elapsed time backed by std.time.nanoTimestamp().
        try g.w.writeAll(
            \\const TimerHandle = struct {
            \\    _start_ns: i128,
            \\    pub fn elapsed(self: *const TimerHandle) f64 {
            \\        const _ns: i128 = std.time.nanoTimestamp() - self._start_ns;
            \\        return @as(f64, @floatFromInt(_ns)) / 1_000_000.0;
            \\    }
            \\    pub fn elapsedMicros(self: *const TimerHandle) i64 {
            \\        const _ns: i128 = std.time.nanoTimestamp() - self._start_ns;
            \\        return @intCast(@divFloor(_ns, 1000));
            \\    }
            \\    pub fn reset(self: *TimerHandle) void {
            \\        self._start_ns = std.time.nanoTimestamp();
            \\    }
            \\};
            \\fn _timer_start() TimerHandle { return .{ ._start_ns = std.time.nanoTimestamp() }; }
            \\
        );
        for (module.decls) |decl| try g.genTopDecl(decl);

        // Emit a top-level `pub fn main()` thunk if any class has a
        // `shared def main`.  Zig's startup code looks for `root.main`.
        if (try findMainClass(module.decls, g.alloc, "")) |class_name| {
            defer g.alloc.free(class_name);
            // If the main method throws, wrap in a catch block so ZebraError
            // is displayed as a clean user-facing message rather than Zig's
            // "error: ZebraError" with a backtrace.
            const main_throws = findMainMethod(module.decls) != null and blk: {
                const m = findMainMethod(module.decls).?;
                break :blk m.throws or (m.body != null and bodyHasRaise(m.body.?, g.tc));
            };
            // Build allocator-init calls for all Zebra-dep `use` modules so that
            // library code that calls allocating functions (string interp, etc.)
            // shares the root module's arena allocator.
            var alloc_init_buf: std.ArrayListUnmanaged(u8) = .{};
            defer alloc_init_buf.deinit(g.alloc);
            for (module.decls) |decl| {
                const u = switch (decl) { .use => |u| u, else => continue };
                // Skip native (Zig/C) imports — they don't have `_initAllocator`.
                if (g.native_uses) |nu| if (nu.get(u.path) != null) continue;
                // Compute import path (dots → slashes).
                const imp_path = try std.mem.replaceOwned(u8, g.alloc, u.path, ".", "/");
                defer g.alloc.free(imp_path);
                try alloc_init_buf.writer(g.alloc).print(
                    "    @import(\"{s}.zig\")._initAllocator(_allocator);\n", .{imp_path});
            }
            const alloc_init = alloc_init_buf.items;

            if (main_throws) {
                try g.w.print(
                    "pub fn main() void {{\n" ++
                    "    _allocator = _arena.allocator();\n" ++
                    "    defer _arena.deinit();\n" ++
                    "{s}" ++
                    "    {s}.main() catch |_err| {{\n" ++
                    "        if (_err == error.ZebraError) {{\n" ++
                    "            std.debug.print(\"Error: {{s}}\\n\", .{{_error_ctx.message}});\n" ++
                    "        }} else {{\n" ++
                    "            std.debug.print(\"Error: {{}}\\n\", .{{_err}});\n" ++
                    "        }}\n" ++
                    "        std.process.exit(1);\n" ++
                    "    }};\n" ++
                    "}}\n",
                    .{ alloc_init, class_name },
                );
            } else {
                try g.w.print(
                    "pub fn main() void {{\n" ++
                    "    _allocator = _arena.allocator();\n" ++
                    "    defer _arena.deinit();\n" ++
                    "{s}" ++
                    "    {s}.main();\n" ++
                    "}}\n",
                    .{ alloc_init, class_name },
                );
            }
        }
    }

    fn genTopDecl(g: Generator, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .use       => |n| try g.genUse(n),
            .namespace => |n| try g.genNamespace(n),
            .class     => |n| try g.genClass(n),
            .interface => |n| try g.genInterface(n),
            .struct_   => |n| try g.genStruct(n),
            .mixin     => {},   // never emitted standalone; inlined at `adds` sites
            .enum_     => |n| try g.genEnum(n),
            .extend    => |n| try g.genExtend(n),
            .method    => |n| try g.genMethod(n),
            .property  => |n| try g.genProperty(n),
            .var_      => |n| try g.genTopVar(n),
            .init      => {},   // top-level constructor makes no sense
            .union_    => |n| try g.genUnion(n),
            .sig_      => |n| try g.genSig(n),
        }
    }

    // ── sig ───────────────────────────────────────────────────────────────────

    fn genSig(g: Generator, n: *Ast.DeclSig) anyerror!void {
        // Emit: `const Name = *const fn(T1, T2) R;`
        // This makes `Name` a usable Zig type alias for the function pointer type.
        try g.writeIndent();
        try g.w.print("const {s} = *const fn(", .{n.name});
        for (n.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");
        if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");
        try g.w.writeAll(";\n");
    }

    // ── use ───────────────────────────────────────────────────────────────────

    fn genUse(g: Generator, n: *Ast.DeclUse) anyerror!void {
        try g.writeIndent();
        // Alias = last segment of dotted path:  "Math.Utils" → "Utils"
        const last_dot = std.mem.lastIndexOf(u8, n.path, ".");
        const alias = if (last_dot) |d| n.path[d + 1..] else n.path;
        // Import path: replace '.' with '/' and use forward slashes throughout.
        // Zig @import accepts forward slashes on all platforms.
        const import_rel = try std.mem.replaceOwned(u8, g.alloc, n.path, ".", "/");
        defer g.alloc.free(import_rel);

        // Check if this dep is a native Zig or C file.
        const native_kind: ?NativeUse = if (g.native_uses) |nu| nu.get(n.path) else null;

        if (native_kind) |kind| switch (kind) {
            .zig => {
                // Native Zig file: import the whole module without unwrapping a
                // single class.  The user accesses its exports as `Alias.Foo`.
                try g.w.print("const {s} = @import(\"{s}.zig\");\n", .{ alias, import_rel });
            },
            .c_with_header => {
                // C file + matching header: expose via cImport so Zebra code
                // can call C functions as `Alias.some_fn(...)`.
                try g.w.print("const {s} = @cImport(@cInclude(\"{s}.h\"));\n", .{ alias, import_rel });
            },
            .c_no_header => {
                // C file without a header: compiled as a translation unit.
                // Declare needed symbols via zig"extern fn ..." in Zebra source.
                try g.w.print("// {s}: C source compiled inline (use zig\"extern fn...\" for declarations)\n", .{alias});
            },
        } else {
            // Zebra dep: if the module exports EXACTLY ONE non-union type whose name
            // matches the alias, unwrap it so `Alias.method()` works without double
            // qualification.  Union types (discriminated-union variants) are excluded
            // from the count because they are always accessed as `Module.UnionName.variant`.
            // Multi-type modules (e.g. Token: TokenKind(union) + Token + Keywords) must
            // be imported whole so qualified refs like `Token.TokenKind` resolve correctly.
            const has_sole_same_named_type = blk: {
                const imp = g.imported_modules orelse break :blk false;
                const iface = imp.get(alias) orelse break :blk false;
                // Count only non-union types (value == false).
                var non_union_count: usize = 0;
                var it = iface.types.valueIterator();
                while (it.next()) |is_union| { if (!is_union.*) non_union_count += 1; }
                if (non_union_count != 1) break :blk false;
                // The sole non-union type must be named after the alias.
                const is_union_ptr = iface.types.getPtr(alias) orelse break :blk false;
                break :blk !is_union_ptr.*;
            };
            if (has_sole_same_named_type) {
                try g.w.print("const {s} = @import(\"{s}.zig\").{s};\n", .{ alias, import_rel, alias });
            } else {
                // Multi-type module or module whose primary type has a different name —
                // import the whole file so `Alias.TypeName.method()` works.
                try g.w.print("const {s} = @import(\"{s}.zig\");\n", .{ alias, import_rel });
            }
            // Selective imports: `use Mod exposing Name1, Name2`
            // Emit `const Name = Alias.Name;` for each exposed name that doesn't
            // conflict with the module alias.  Track exposed union names so that
            // `Name.variant(v)` → `Name{ .variant = v }` works in genCall.
            if (n.exposing.len > 0) {
                const iface_opt = if (g.imported_modules) |im| im.get(alias) else null;
                for (n.exposing) |exp_name| {
                    if (!std.mem.eql(u8, exp_name, alias)) {
                        try g.writeIndent();
                        try g.w.print("const {s} = {s}.{s};\n", .{ exp_name, alias, exp_name });
                    }
                    // Track exposed union/class names for correct construction emit.
                    if (iface_opt) |iface| {
                        if (iface.types.getPtr(exp_name)) |is_union_ptr| {
                            if (is_union_ptr.*) {
                                try g.exposed_unions.put(exp_name, alias);
                            } else {
                                try g.exposed_classes.put(exp_name, {});
                            }
                        }
                    }
                }
            }
        }
    }

    // ── namespace ─────────────────────────────────────────────────────────────

    fn genNamespace(g: Generator, n: *Ast.DeclNamespace) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});
        const ig = g.indented();
        for (n.decls) |decl| try ig.genTopDecl(decl);
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── class ─────────────────────────────────────────────────────────────────

    // ── C export helpers ──────────────────────────────────────────────────────

    /// True if `tr` maps to a plain C primitive (no slices, generics, optionals).
    fn isCExportable(tr: Ast.TypeRef) bool {
        return switch (tr) {
            .void_  => true,
            .named  => |n| std.StaticStringMap(void).initComptime(&.{
                .{ "int",     {} }, .{ "uint",    {} }, .{ "float",   {} },
                .{ "bool",    {} }, .{ "char",    {} },
                .{ "int8",    {} }, .{ "int16",   {} }, .{ "int32",   {} }, .{ "int64",   {} },
                .{ "uint8",   {} }, .{ "uint16",  {} }, .{ "uint32",  {} }, .{ "uint64",  {} },
                .{ "float32", {} }, .{ "float64", {} },
            }).has(n.name),
            else    => false,
        };
    }

    /// True if a `shared def` method can be exported with C linkage.
    /// Requirements: shared, no throws, body present, all param/return types
    /// are C-compatible primitives.
    fn isMethodCExportable(n: *const Ast.DeclMethod) bool {
        if (!n.mods.shared) return false;
        if (n.throws) return false;
        if (n.body == null) return false;
        for (n.params) |p| {
            const tr = p.type_ orelse return false;
            if (!isCExportable(tr)) return false;
        }
        if (n.return_type) |rt| if (!isCExportable(rt)) return false;
        return true;
    }

    /// Emit file-scope `export fn OwnerName_methodName(...)` wrappers for all
    /// eligible shared methods in `members`.  Updates `has_exports_ptr` when any
    /// wrapper is emitted.
    fn genExportWrappers(g: Generator, owner_name: []const u8, members: []const Ast.Decl) anyerror!void {
        if (!g.emit_exports) return;
        for (members) |decl| {
            const n = switch (decl) { .method => |m| m, else => continue };
            if (!isMethodCExportable(n)) continue;

            const returns_void = n.return_type == null or n.return_type.? == .void_;
            try g.w.print("export fn {s}_{s}(", .{ owner_name, n.name });
            for (n.params, 0..) |p, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.print("{s}: ", .{p.name});
                try g.genType(p.type_.?);
            }
            try g.w.writeAll(") ");
            if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");
            try g.w.print(" {{ {s}{s}.{s}(", .{
                if (returns_void) "" else "return ",
                owner_name,
                n.name,
            });
            for (n.params, 0..) |p, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.writeAll(p.name);
            }
            try g.w.writeAll("); }\n");
            if (g.has_exports_ptr) |p| p.* = true;
        }
    }

    /// Emit a generic class as a Zig comptime function.
    ///
    /// `class Stack(T)` →
    ///   pub fn Stack(comptime T: type) type { return struct { … }; }
    ///   const _ttag_Stack: u64 = <hash>;
    ///
    /// Inside the returned struct:
    ///   - `init(…)` returns `@This()` and uses `var self: @This() = undefined`
    ///   - instance methods use `self: *@This()`
    ///   - `_type_tag` defaults to `_ttag_Stack` (module-scope const, always accessible)
    fn genGenericClass(g: Generator, n: *Ast.DeclClass) anyerror!void {
        try g.writeIndent();
        // Emit comptime function signature: pub fn Stack(comptime T: type, ...) type {
        try g.w.print("pub fn {s}(", .{n.name});
        for (n.type_params, 0..) |tp, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.print("comptime {s}: type", .{tp.name});
        }
        try g.w.writeAll(") type {\n");

        const fg = g.indented();
        try fg.writeIndent();
        try fg.w.writeAll("return struct {\n");

        // Inner generator: owner = class name, is_generic = true
        const ig = fg.indented().withOwner(n.name).withGeneric(n);

        // ① Type-tag field (references module-scope _ttag_ClassName constant).
        try ig.writeIndent();
        try ig.w.print("_type_tag: u64 = _ttag_{s},\n", .{n.name});

        // ② Regular members (fields, methods, init).
        for (n.members) |decl| try ig.genMember(decl);

        // ③ Synthetic default init if no explicit cue init.
        {
            var has_init = false;
            for (n.members) |m| { if (m == .init) { has_init = true; break; } }
            if (!has_init) {
                try ig.writeIndent();
                try ig.w.writeAll("pub fn init() @This() {\n");
                const dig = ig.indented();
                try dig.writeIndent();
                try dig.w.writeAll("var self: @This() = undefined;\n");
                try dig.writeIndent();
                try dig.w.print("self._type_tag = _ttag_{s};\n", .{n.name});
                try dig.writeIndent();
                try dig.w.writeAll("return self;\n");
                try ig.writeIndent();
                try ig.w.writeAll("}\n\n");
            }
        }

        try fg.writeIndent();
        try fg.w.writeAll("};\n");
        try g.writeIndent();
        try g.w.writeAll("}\n\n");

        // Type-tag constant — same as for non-generic classes: low 32 bits = class hash.
        // High 32 bits stay 0 until Phase 3 (is Stack(int) checks).
        try g.w.print("const _ttag_{s}: u64 = {d};\n\n", .{ n.name, @as(u64, zbr_hash_str(n.name)) });
    }

    fn genClass(g: Generator, n: *Ast.DeclClass) anyerror!void {
        if (n.type_params.len > 0) return g.genGenericClass(n);
        const cg = g.withClass(n);

        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});

        const ig = cg.indented();

        // ① Runtime type-tag field — enables `expr is TypeName` and
        //    `expr is TypeName(T)` checks.  Layout: bits[31:0] = class hash,
        //    bits[63:32] = type-arg combined hash (0 for non-generic classes).
        //    The constant `_ttag_ClassName` is emitted after the struct.
        try ig.writeIndent();
        try ig.w.print("_type_tag: u64 = _ttag_{s},\n", .{n.name});

        // ② Inline mixin members before class members (fields first in Zig
        //    struct layout).
        for (n.adds) |tr| {
            const mname = typeRefSimpleName(tr) orelse continue;
            if (g.mixins.get(mname)) |mx| {
                try ig.writeIndent();
                try ig.w.print("// mixin: {s}\n", .{mname});
                for (mx.members) |decl| try ig.genMember(decl);
            }
        }

        // ② Regular class members.
        for (n.members) |decl| try ig.genMember(decl);

        // ③ Synthetic default init — emitted when no explicit `cue init` is present.
        //    Without this, a class constructed via `ClassName{}` relies on the field
        //    default for `_type_tag`, which is fragile.  With this, every class
        //    always has a clearly-defined `init()` path that explicitly stamps the
        //    type-tag field regardless of how the struct was allocated.
        {
            var has_init = false;
            for (n.members) |m| {
                if (m == .init) { has_init = true; break; }
            }
            if (!has_init) {
                outer: for (n.adds) |tr| {
                    const mname = typeRefSimpleName(tr) orelse continue;
                    if (g.mixins.get(mname)) |mx| {
                        for (mx.members) |m| {
                            if (m == .init) { has_init = true; break :outer; }
                        }
                    }
                }
            }
            if (!has_init) {
                try ig.writeIndent();
                try ig.w.print("pub fn init() {s} {{\n", .{n.name});
                const dig = ig.indented();
                try dig.writeIndent();
                try dig.w.print("var self: {s} = undefined;\n", .{n.name});
                try dig.writeIndent();
                try dig.w.print("self._type_tag = _ttag_{s};\n", .{n.name});
                try dig.writeIndent();
                try dig.w.writeAll("return self;\n");
                try ig.writeIndent();
                try ig.w.writeAll("}\n\n");
            }
        }

        // ④ Interface conformance checks.
        //    `class Foo implements IBar` → `comptime { IBar(@This()); }`
        if (n.implements.len > 0) {
            try ig.w.writeAll("\n");
            try ig.writeIndent();
            try ig.w.writeAll("comptime {\n");
            const cig = ig.indented();
            for (n.implements) |tr| {
                const iname = typeRefSimpleName(tr) orelse continue;
                try cig.writeIndent();
                try cig.w.print("{s}(@This());\n", .{iname});
            }
            try ig.writeIndent();
            try ig.w.writeAll("}\n");
        }

        try g.writeIndent();
        try g.w.writeAll("};\n\n");

        // ④ Tier-1 reflection: emit per-class const arrays for field names and types.
        //    Linker dead-strips these if nothing references them (zero cost when unused).
        {
            var field_names = std.ArrayListUnmanaged([]const u8){};
            defer field_names.deinit(g.alloc);
            var field_types = std.ArrayListUnmanaged([]const u8){};

            for (n.members) |decl| {
                const v = switch (decl) { .var_ => |v| v, else => continue };
                if (v.mods.shared) continue;
                try field_names.append(g.alloc, v.name);
                const ts: []const u8 = if (v.type_) |tr|
                    try typeRefStr(tr, g.alloc)
                else
                    try g.alloc.dupe(u8, "unknown");
                try field_types.append(g.alloc, ts);
            }
            defer { for (field_types.items) |s| g.alloc.free(s); field_types.deinit(g.alloc); }

            // Type-tag constant — class hash in the low 32 bits, type-arg hash
            // in the high 32 bits (always 0 for non-generic classes).
            // The u64 layout means `is Dog` checks `._type_tag == _ttag_Dog`
            // with no masking needed for non-generic types.
            try g.w.print("const _ttag_{s}: u64 = {d};\n", .{ n.name, @as(u64, zbr_hash_str(n.name)) });
            try g.w.print("const _reflect_{s}_name: []const u8 = \"{s}\";\n", .{ n.name, n.name });

            try g.w.print("const _reflect_{s}_fields: []const []const u8 = &.{{", .{n.name});
            for (field_names.items, 0..) |nm, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.print("\"{s}\"", .{nm});
            }
            try g.w.writeAll("};\n");

            try g.w.print("const _reflect_{s}_field_types: []const []const u8 = &.{{", .{n.name});
            for (field_types.items, 0..) |ts, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.w.print("\"{s}\"", .{ts});
            }
            try g.w.writeAll("};\n\n");
        }

        try g.genExportWrappers(n.name, n.members);
    }

    // ── Member dispatch ───────────────────────────────────────────────────────

    fn genMember(g: Generator, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .var_     => |n| try g.genFieldDecl(n),
            .method   => |n| try g.genMethod(n),
            .property => |n| try g.genProperty(n),
            .init     => |n| try g.genInit(n),
            else      => {},
        }
    }

    // ── Field declaration ─────────────────────────────────────────────────────

    fn genFieldDecl(g: Generator, n: *Ast.DeclVar) anyerror!void {
        try g.writeIndent();
        if (n.mods.shared) {
            // `shared var` → Zig namespace-level declaration inside the struct.
            // Accessed as StructName.field, not instance.field.
            const kw: []const u8 = if (n.mods.readonly or n.is_const) "const" else "var";
            // Stdlib constructor shorthand: `shared var x as List(T) = List()` or HashMap variant.
            // Must emit `std.ArrayList(T){}` / `std.StringHashMap(T).init(_allocator)`, not `List()`.
            if (n.init) |e| {
                if (n.type_) |tr| {
                    if (tr == .generic) {
                        const gtr = tr.generic;
                        if (e.* == .call and e.call.args.len == 0 and
                            e.call.callee.* == .ident and
                            std.mem.eql(u8, e.call.callee.ident.name, gtr.name))
                        {
                            try g.w.writeAll("pub ");
                            try g.w.writeAll(kw);
                            try g.w.writeAll(" ");
                            try g.w.writeAll(n.name);
                            try g.w.writeAll(": ");
                            try g.genType(tr);
                            try g.w.writeAll(" = ");
                            try g.genStdlibInit(gtr);
                            try g.w.writeAll(";\n");
                            return;
                        }
                    }
                }
            }
            try g.w.writeAll("pub ");
            try g.w.writeAll(kw);
            try g.w.writeAll(" ");
            try g.w.writeAll(n.name);
            if (n.type_) |tr| { try g.w.writeAll(": "); try g.genType(tr); }
            if (n.init) |e| { try g.w.writeAll(" = "); try g.genExpr(e); }
            else try g.w.writeAll(" = undefined");
            try g.w.writeAll(";\n");
        } else {
            try g.w.writeAll(n.name);
            try g.w.writeAll(": ");
            if (n.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
            if (n.init) |e| { try g.w.writeAll(" = "); try g.genExpr(e); }
            else try g.w.writeAll(" = undefined");
            try g.w.writeAll(",\n");
        }
    }

    // ── interface ─────────────────────────────────────────────────────────────

    fn genInterface(g: Generator, n: *Ast.DeclInterface) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub fn {s}(comptime T: type) void {{\n", .{n.name});

        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.writeAll("comptime {\n");

        const iig = ig.indented();
        for (n.members) |m| {
            const req_name: ?[]const u8 = switch (m) {
                .method   => |meth| meth.name,
                .property => |prop| prop.name,
                else      => null,
            };
            if (req_name) |mname| {
                try iig.writeIndent();
                try iig.w.print(
                    "if (!@hasDecl(T, \"{s}\")) @compileError(" ++
                    "\"type \" ++ @typeName(T) ++ \" does not implement {s}.{s}\");\n",
                    .{ mname, n.name, mname },
                );
            }
        }

        try ig.writeIndent();
        try ig.w.writeAll("}\n");
        try g.writeIndent();
        try g.w.writeAll("}\n\n");
    }

    // ── struct ────────────────────────────────────────────────────────────────

    fn genStruct(g: Generator, n: *Ast.DeclStruct) anyerror!void {
        const sg = g.withStruct(n);
        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});
        const ig = sg.indented();
        for (n.members) |decl| try ig.genMember(decl);
        if (n.implements.len > 0) {
            try ig.w.writeAll("\n");
            try ig.writeIndent();
            try ig.w.writeAll("comptime {\n");
            const cig = ig.indented();
            for (n.implements) |tr| {
                const iname = typeRefSimpleName(tr) orelse continue;
                try cig.writeIndent();
                try cig.w.print("{s}(@This());\n", .{iname});
            }
            try ig.writeIndent();
            try ig.w.writeAll("}\n");
        }
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
        try g.genExportWrappers(n.name, n.members);
    }

    // ── enum ──────────────────────────────────────────────────────────────────

    fn genEnum(g: Generator, n: *Ast.DeclEnum) anyerror!void {
        try g.writeIndent();
        try g.w.print("pub const {s} = enum", .{n.name});
        if (n.base) |base| {
            try g.w.writeAll("(");
            try g.genType(base);
            try g.w.writeAll(")");
        }
        try g.w.writeAll(" {\n");
        const ig = g.indented();
        for (n.members) |m| {
            try ig.writeIndent();
            try ig.w.writeAll(m.name);
            if (m.value) |v| {
                try ig.w.writeAll(" = ");
                try ig.genExpr(v);
            }
            try ig.w.writeAll(",\n");
        }
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── union ─────────────────────────────────────────────────────────────────

    fn genUnion(g: Generator, n: *Ast.DeclUnion) anyerror!void {
        // Emit a Zig tagged union: pub const Name = union(enum) { ... };
        // Top-level unions are always pub so cross-module users (via `use Module`) can
        // reference them as `Module.UnionName`.
        try g.writeIndent();
        try g.w.print("pub const {s} = union(enum) {{\n", .{n.name});
        const ig = g.indented();
        for (n.variants) |v| {
            try ig.writeIndent();
            if (v.payload) |pl| {
                try ig.w.print("{s}: ", .{v.name});
                try ig.genType(pl);
                try ig.w.writeAll(",\n");
            } else {
                try ig.w.print("{s},\n", .{v.name});
            }
        }
        try g.writeIndent();
        try g.w.writeAll("};\n\n");
    }

    // ── extend ────────────────────────────────────────────────────────────────

    fn genExtend(g: Generator, n: *Ast.DeclExtend) anyerror!void {
        const tname = typeRefSimpleName(n.target) orelse "Unknown";
        try g.writeIndent();
        try g.w.print("// extend {s}\n", .{tname});
        for (n.members) |decl| switch (decl) {
            .method => |m| try g.genExtMethod(tname, m),
            else    => {},
        };
        try g.w.writeAll("\n");
    }

    /// Emit a standalone Zig function for an extension method.
    ///
    /// `extend String\n    def words as List(str)` →
    /// `fn _ext_String_words(self: []const u8) !std.ArrayList([]const u8) { ... }`
    fn genExtMethod(g: Generator, tname: []const u8, m: *Ast.DeclMethod) anyerror!void {
        const mg = g.asMethod();
        // Compute the Zebra type of `self` so stdlib method calls on `this` dispatch correctly.
        const self_kind: TypeChecker.Type = blk: {
            const sk = Builtins.scalarKind(tname);
            break :blk switch (sk) {
                .int, .int_n  => .int,
                .uint, .uint_n => .uint,
                .float, .float_n => .float,
                .bool         => .bool,
                .char         => .char,
                .string       => .string,
                .void_        => .void_,
                .unknown      => .unknown,
            };
        };
        // The owner for `self.field` injection inside the body is still `tname`.
        const eg = mg.withOwner(tname).withExtSelf(self_kind);

        try g.writeIndent();
        try g.w.print("fn _ext_{s}_{s}(self: ", .{tname, m.name});
        // Self type: Zig value type for builtins, struct name for user types.
        const zig_self = Builtins.zigTypeName(tname);
        if (std.mem.eql(u8, zig_self, tname)) {
            // User-defined type — pass by value so we don't need & at call site.
            try g.w.writeAll(tname);
        } else {
            try g.w.writeAll(zig_self);
        }
        if (m.params.len > 0) try g.w.writeAll(", ");
        for (m.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");

        const needs_error = m.throws or (m.body != null and bodyHasRaise(m.body.?, g.tc));
        if (needs_error) try g.w.writeAll("anyerror!");
        if (m.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");

        if (m.body) |body| {
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            var mut_set = try scanMutations(body, g.alloc, g.tc);
            defer mut_set.deinit();
            var ret_set = try analyzeEscapes(body, g.alloc);
            defer ret_set.deinit();
            var cv_map = std.StringHashMap(void).init(g.alloc);
            defer cv_map.deinit();
            const bg = eg.indented().withMutated(&mut_set).withClosureVars(&cv_map).withReturnedNames(&ret_set);
            try g.w.writeAll(" {\n");
            if (!refs.uses_self) try bg.line("_ = self;");
            for (m.params) |p| {
                if (!refs.param_names.contains(p.name)) {
                    try bg.writeIndent();
                    try bg.w.print("_ = {s};\n", .{p.name});
                }
            }
            try bg.genStmts(body);
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        } else {
            try g.w.writeAll(" { unreachable; // abstract\n}\n\n");
        }
    }

    // ── Top-level var / const ─────────────────────────────────────────────────

    fn genTopVar(g: Generator, n: *Ast.DeclVar) anyerror!void {
        try g.writeIndent();
        const kw: []const u8 = if (n.is_const) "const" else "var";
        try g.w.print("pub {s} {s}", .{ kw, n.name });
        if (n.type_) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        }
        if (n.init) |e| {
            try g.w.writeAll(" = ");
            try g.genExpr(e);
        }
        try g.w.writeAll(";\n\n");
    }

    // ── method ────────────────────────────────────────────────────────────────

    // ── TCO detection ─────────────────────────────────────────────────────────

    /// Returns true if `v` is a tail-recursive call to `method_name`.
    ///
    /// Accepted patterns:
    ///   Instance methods: `method(args)` (bare call — Zebra natural style)
    ///   Shared methods:   `Owner.method(args)` (explicit class prefix)
    fn isTcoExpr(v: *const Ast.Expr, method_name: []const u8, owner: []const u8, shared: bool) bool {
        if (v.* != .call) return false;
        const callee = v.call.callee;
        if (shared) {
            // `Owner.method(args)` — explicit class-qualified call for shared methods.
            if (callee.* != .member) return false;
            const mem = callee.member;
            if (!std.mem.eql(u8, mem.member, method_name)) return false;
            if (mem.object.* != .ident) return false;
            return std.mem.eql(u8, mem.object.ident.name, owner);
        } else {
            // Bare `method(args)` — instance method calling itself.
            if (callee.* != .ident) return false;
            return std.mem.eql(u8, callee.ident.name, method_name);
        }
    }

    /// Recursively scans `stmts` for any `return` whose value is a direct tail
    /// call to `method_name` (see `isTcoExpr`).  Returns true on first match.
    /// Does NOT recurse into loop bodies — a `return` inside a loop breaks the
    /// loop, not the function, so it is never a function-level tail call.
    fn scanTco(stmts: []const Ast.Stmt, method_name: []const u8, owner: []const u8, shared: bool) bool {
        for (stmts) |stmt| switch (stmt) {
            .return_ => |s| {
                if (s.value) |v| if (isTcoExpr(v, method_name, owner, shared)) return true;
            },
            .if_ => |s| {
                if (scanTco(s.then_body, method_name, owner, shared)) return true;
                if (s.else_body) |eb| if (scanTco(eb, method_name, owner, shared)) return true;
            },
            .branch => |s| {
                for (s.on) |on| if (scanTco(on.body, method_name, owner, shared)) return true;
                if (s.else_) |eb| if (scanTco(eb, method_name, owner, shared)) return true;
            },
            else => {},
        };
        return false;
    }

    fn genMethod(g: Generator, n: *Ast.DeclMethod) anyerror!void {
        var mg = g.asMethod();

        try g.writeIndent();
        try g.w.print("pub fn {s}(", .{n.name});

        // Instance methods inside a type get `self: *Owner`.
        // `shared` methods (type-level, not instance) omit self.
        const has_self = g.owner.len > 0 and !n.mods.shared;

        // Pre-check: does this method have any tail-recursive calls?
        // If so, we use the loop-transformation (TCO) path.
        const is_tco = if (n.body) |body| n.params.len > 0 and
            scanTco(body, n.name, g.owner, n.mods.shared) else false;

        if (has_self) {
            // Generic class methods use *@This() (the struct is anonymous inside the comptime fn).
            if (g.is_generic) {
                try g.w.writeAll("self: *@This()");
            } else {
                try g.w.print("self: *{s}", .{g.owner});
            }
            if (n.params.len > 0) try g.w.writeAll(", ");
        }

        // In TCO mode params are renamed to `_p_<name>` so we can shadow them
        // with mutable `var <name> = _p_<name>;` locals inside the while loop.
        for (n.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            if (is_tco) try g.w.print("_p_{s}", .{p.name}) else try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");

        // Emit anyerror! if explicitly annotated OR if the body contains raise/try.
        const needs_error = n.throws or
            (n.body != null and bodyHasRaise(n.body.?, g.tc));
        mg.current_method_throws = needs_error;
        if (needs_error) try g.w.writeAll("anyerror!");
        if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");

        if (n.body) |body| {
            // Pre-scan 1: which params / self are actually referenced?
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            // Pre-scan 2: which locals are mutated? (var vs const)
            var mut_set = try scanMutations(body, g.alloc, g.tc);
            defer mut_set.deinit();
            // Pre-scan 3: escape analysis — which string locals are returned?
            // Suppresses `defer _allocator.free` for strings whose ownership
            // transfers to the caller. Does NOT affect List/HashMap (no deinit emitted).
            var ret_set = try analyzeEscapes(body, g.alloc);
            defer ret_set.deinit();
            // Mutable map of closure-var names (populated lazily during genStmts)
            var cv_map = std.StringHashMap(void).init(g.alloc);
            defer cv_map.deinit();

            try g.w.writeAll(" {\n");

            if (is_tco) {
                // TCO preamble: mutable shadow copies of params + `while (true)`.
                // The body generator uses one extra indent level for the loop body.
                const ig = mg.indented();
                for (n.params) |p| {
                    try ig.writeIndent();
                    try ig.w.print("var {s} = _p_{s};\n", .{ p.name, p.name });
                }
                try ig.writeIndent();
                try ig.w.writeAll("while (true) {\n");

                // Collect param names slice (lifetime: until end of this block).
                var tco_pnames: std.ArrayListUnmanaged([]const u8) = .{};
                defer tco_pnames.deinit(g.alloc);
                for (n.params) |p| try tco_pnames.append(g.alloc, p.name);

                const bg = ig.indented()
                    .withMutated(&mut_set).withClosureVars(&cv_map).withReturnedNames(&ret_set)
                    .withTco(n.name, tco_pnames.items, n.mods.shared);
                // No param suppression needed — all params are used via `var p = _p_p;`.
                if (has_self and !refs.uses_self) try bg.line("_ = self;");
                try bg.genStmts(body);

                // Close the while loop.
                try ig.writeIndent();
                try ig.w.writeAll("}\n");
            } else {
                const bg = mg.indented().withMutated(&mut_set).withClosureVars(&cv_map).withReturnedNames(&ret_set);
                // Emit `_ = x;` only for params that are NOT referenced in the body.
                if (has_self and !refs.uses_self) try bg.line("_ = self;");
                for (n.params) |p| {
                    if (!refs.param_names.contains(p.name)) {
                        try bg.writeIndent();
                        try bg.w.print("_ = {s};\n", .{p.name});
                    }
                }
                try bg.genStmts(body);
            }

            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        } else {
            // Abstract method — emit a stub body.
            try g.w.writeAll(" {\n");
            try mg.indented().line("unreachable; // abstract");
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        }
    }

    // ── property ──────────────────────────────────────────────────────────────

    fn genProperty(g: Generator, n: *Ast.DeclProperty) anyerror!void {
        const pg = g.asMethod();

        // Getter — named after the property itself.
        if (n.getter) |body| {
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            var mut_set = try scanMutations(body, g.alloc, g.tc);
            defer mut_set.deinit();
            var cv_map = std.StringHashMap(void).init(g.alloc);
            defer cv_map.deinit();
            const pbg = pg.indented().withMutated(&mut_set).withClosureVars(&cv_map);
            try g.writeIndent();
            try g.w.print("pub fn {s}(", .{n.name});
            if (g.owner.len > 0) try g.w.print("self: *const {s}", .{g.owner});
            try g.w.writeAll(") ");
            if (n.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
            try g.w.writeAll(" {\n");
            if (g.owner.len > 0 and !refs.uses_self) try pbg.line("_ = self;");
            try pbg.genStmts(body);
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        }

        // Setter — prefixed with `set_`.
        if (n.setter) |body| {
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            var mut_set = try scanMutations(body, g.alloc, g.tc);
            defer mut_set.deinit();
            var cv_map2 = std.StringHashMap(void).init(g.alloc);
            defer cv_map2.deinit();
            const pbg = pg.indented().withMutated(&mut_set).withClosureVars(&cv_map2);
            try g.writeIndent();
            try g.w.print("pub fn set_{s}(", .{n.name});
            if (g.owner.len > 0) {
                try g.w.print("self: *{s}, ", .{g.owner});
            }
            try g.w.writeAll("value: ");
            if (n.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
            try g.w.writeAll(") void {\n");
            if (g.owner.len > 0 and !refs.uses_self) try pbg.line("_ = self;");
            if (!refs.param_names.contains("value")) try pbg.line("_ = value;");
            try pbg.genStmts(body);
            try g.writeIndent();
            try g.w.writeAll("}\n\n");
        }
    }

    // ── constructor ───────────────────────────────────────────────────────────

    fn genInit(g: Generator, n: *Ast.DeclInit) anyerror!void {
        const mg = g.asMethod();
        try g.writeIndent();
        try g.w.writeAll("pub fn init(");
        for (n.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        // Generic class init returns @This() (the anonymous struct from the comptime fn).
        // Non-generic init returns the named owner type.
        const self_type_name = if (g.is_generic) "@This()" else g.owner;
        try g.w.print(") {s} {{\n", .{self_type_name});
        const body = n.body orelse &[_]Ast.Stmt{};
        var refs = try collectRefs(body, g.resolve, g.alloc);
        defer refs.deinit();
        var mut_set = try scanMutations(body, g.alloc, g.tc);
        defer mut_set.deinit();
        var cv_map = std.StringHashMap(void).init(g.alloc);
        defer cv_map.deinit();
        const bg = mg.indented().withMutated(&mut_set).withClosureVars(&cv_map);
        try bg.writeIndent();
        try bg.w.print("var self: {s} = undefined;\n", .{self_type_name});
        // Initialise the type-ID field so `expr is TypeName` works correctly.
        // Structs do NOT have a _type_tag field — skip for those.
        if (!g.is_struct_owner) {
            try bg.writeIndent();
            try bg.w.print("self._type_tag = _ttag_{s};\n", .{g.owner});
        }
        for (n.params) |p| {
            if (!refs.param_names.contains(p.name)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{p.name});
            }
        }
        try bg.genStmts(body);
        try bg.writeIndent();
        try bg.w.writeAll("return self;\n");
        try g.writeIndent();
        try g.w.writeAll("}\n\n");
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn genStmts(g: Generator, stmts: []const Ast.Stmt) anyerror!void {
        for (stmts) |stmt| try g.genStmt(stmt);
    }

    /// Extract the source span from any Stmt variant.
    /// Returns null for void-payload variants (pass, break_, continue_, contract).
    fn stmtSpan(stmt: Ast.Stmt) ?Ast.Span {
        return switch (stmt) {
            .var_          => |n| n.span,
            .assign        => |s| s.span,
            .return_       => |s| s.span,
            .if_           => |s| s.span,
            .while_        => |s| s.span,
            .for_in        => |s| s.span,
            .for_num       => |s| s.span,
            .branch        => |s| s.span,
            .print         => |s| s.span,
            .assert        => |s| s.span,
            .yield         => |s| s.span,
            .expr          => |e| exprSpan(e),
            .defer_        => |s| s.span,
            .with          => |s| s.span,
            .var_except    => |s| s.span,
            .assign_except => |s| s.span,
            .raise         => |s| s.span,
            .try_catch     => |s| s.span,
            .guard         => |s| s.span,
            .destruct      => |s| s.span,
            .arena_scope   => |s| s.span,
            .pass, .break_, .continue_, .contract => null,
        };
    }

    /// Extract the source span from any Expr variant.
    fn exprSpan(e: *const Ast.Expr) ?Ast.Span {
        return switch (e.*) {
            .int_lit       => |x| x.span,
            .float_lit     => |x| x.span,
            .bool_lit      => |x| x.span,
            .char_lit      => |x| x.span,
            .string_lit    => |x| x.span,
            .string_interp => |x| x.span,
            .nil           => |s| s,
            .this          => |s| s,
            .ident         => |x| x.span,
            .zig_lit       => |x| x.span,
            .member        => |x| x.span,
            .call          => |x| x.span,
            .index         => |x| x.span,
            .slice         => |x| x.span,
            .binary        => |x| x.span,
            .unary         => |x| x.span,
            .cast          => |x| x.span,
            .to_nilable    => |x| x.span,
            .to_non_nil    => |x| x.span,
            .is_nil        => |x| x.span,
            .orelse_       => |x| x.span,
            .catch_        => |x| x.span,
            .if_expr       => |x| x.span,
            .lambda        => |x| x.span,
            .list_lit      => |x| x.span,
            .dict_lit      => |x| x.span,
            .array_lit     => |x| x.span,
            .all_any       => |x| x.span,
            .old           => |x| x.span,
            .try_          => |x| x.span,
            .tuple_lit     => |x| x.span,
            .type_check    => |x| x.span,
        };
    }

    fn genStmt(g: Generator, stmt: Ast.Stmt) anyerror!void {
        // Emit source-map marker so Zig compiler errors can be remapped
        // to the originating Zebra file and line by main.zig.
        if (g.source_file.len > 0) {
            if (stmtSpan(stmt)) |sp| {
                try g.w.print("// zbr:{s}:{d}\n", .{ g.source_file, sp.line });
            }
        }
        switch (stmt) {
            .var_      => |n| try g.genLocalVar(n),
            .assign    => |s| try g.genAssign(s),
            .return_   => |s| try g.genReturn(s),
            .if_       => |s| try g.genIf(s),
            .while_    => |s| try g.genWhile(s),
            .for_in    => |s| try g.genForIn(s),
            .for_num   => |s| try g.genForNum(s),
            .branch    => |s| try g.genBranch(s),
            .print     => |s| try g.genPrint(s),
            .assert    => |s| try g.genAssert(s),
            .yield     => |s| {
                try g.writeIndent();
                try g.w.writeAll("// yield ");
                try g.genExpr(s.value);
                try g.w.writeAll(";\n");
            },
            .expr      => |e| {
                // GUI widget calls with allocating string args need block-scoped temps.
                if (try g.genGuiWidgetStmt(e)) return;
                try g.writeIndent();
                try g.genExpr(e);
                // Inside a try block, a call to a `throws` method must have its
                // error captured and redirected to the block's tracking variable.
                if (e.* == .call and g.try_block_label != null and
                    exprCallIsThrows(e.call, g.resolve, g.imported_modules, g.owner_members))
                {
                    const ev  = g.try_err_var.?;
                    const lbl = g.try_block_label.?;
                    try g.w.print(" catch |_e| {{ {s} = _e; break :{s}; }}", .{ev, lbl});
                }
                // zig"stmt;" already ends with ';' — don't append another one.
                // genZigLit emits text[4..len-1] (strips zig"..."), so check that slice.
                const already_semi = blk: {
                    if (e.* != .zig_lit) break :blk false;
                    const raw = e.zig_lit.text;
                    if (raw.len < 5) break :blk false;
                    const content = std.mem.trimRight(u8, raw[4 .. raw.len - 1], " \t\r\n");
                    break :blk content.len > 0 and content[content.len - 1] == ';';
                };
                if (!already_semi) try g.w.writeAll(";");
                try g.w.writeAll("\n");
            },
            .pass      => try g.line("// pass"),
            .break_    => try g.line("break;"),
            .continue_ => try g.line("continue;"),
            .defer_    => |s| try g.genDefer(s),
            .contract  => {}, // contracts not emitted (runtime verification out of scope)
            .with        => |s| try g.genWith(s),
            .arena_scope => |s| try g.genArenaScope(s),
            .var_except    => |s| try g.genVarExcept(s),
            .assign_except => |s| try g.genAssignExcept(s),
            .raise         => |s| try g.genRaise(s),
            .try_catch     => |s| try g.genTryCatch(s),
            .guard         => |s| try g.genGuard(s),
            .destruct      => |s| try g.genDestruct(s),
        }
    }

    fn genDestruct(g: Generator, s: *Ast.StmtDestruct) anyerror!void {
        // Use pointer address as a unique suffix to avoid name collisions when
        // multiple destructurings appear in the same scope.
        const uid = @intFromPtr(s) & 0xFFFF;
        try g.writeIndent();
        try g.w.print("const _dt_{x} = ", .{uid});
        try g.genExpr(s.init);
        try g.w.writeAll(";\n");
        switch (s.kind) {
            .tuple => {
                // var (x, y) = expr  →  const x = _dt_N.@"0"; const y = _dt_N.@"1";
                for (s.names, 0..) |name, i| {
                    try g.writeIndent();
                    try g.w.print("const {s} = _dt_{x}.@\"{d}\";\n", .{ name, uid, i });
                }
            },
            .struct_ => {
                // var {name, age} = expr  →  const name = _dt_N.name; const age = _dt_N.age;
                for (s.names) |name| {
                    try g.writeIndent();
                    try g.w.print("const {s} = _dt_{x}.{s};\n", .{ name, uid, name });
                }
            },
        }
    }

    fn genLocalVar(g: Generator, n: *Ast.DeclVar) anyerror!void {
        try g.writeIndent();
        // Use `const` unless the variable is actually reassigned somewhere in
        // the body (Zig treats `var` that is never mutated as a compile error).
        const is_mutated = if (g.mutated) |m| m.contains(n.name) else false;
        // User-defined type instances and cross-module instances must be `var`
        // even when not reassigned, because their methods take `*Self` receivers.
        // Zig rejects calling a `*Self` method on a `*const Self`.
        const tc_init_type: TypeChecker.Type = blk: {
            if (n.init) |init| if (g.tc) |tc| break :blk tc.expr_types.get(init) orelse .unknown;
            break :blk .unknown;
        };
        // Cross-module instances are handled by scanMutationsInExpr (which conservatively
        // marks any receiver of a method call as mutated when TC type is .cross_module).
        // timer_handle is opaque with always-mutable state — force var unconditionally.
        const needs_var_for_methods = (tc_init_type == .timer_handle);
        const kw: []const u8 = if (n.is_const or (!is_mutated and !needs_var_for_methods)) "const" else "var";

        // StringBuilder constructor: `var sb as StringBuilder = StringBuilder()`
        if (n.init) |e| {
            if (n.type_) |tr| {
                if (tr == .named and std.mem.eql(u8, tr.named.name, "StringBuilder")) {
                    if (e.* == .call and e.call.args.len == 0 and
                        e.call.callee.* == .ident and
                        std.mem.eql(u8, e.call.callee.ident.name, "StringBuilder"))
                    {
                        // Always var: ArrayList.appendSlice takes *Self.
                        try g.w.print("var {s} = std.ArrayList(u8){{}};\n", .{n.name});
                        try g.writeIndent();
                        try g.w.print("defer {s}.deinit(_allocator);\n", .{n.name});
                        return;
                    }
                }
            }
        }
        // Stdlib constructor: `var x as List(T) = List()` or `HashMap(K,V) = HashMap()`
        if (n.init) |e| {
            if (n.type_) |tr| {
                if (tr == .generic) {
                    const gtr = tr.generic;
                    // Check if init is a zero-arg call to the same type name
                    if (e.* == .call and e.call.args.len == 0 and
                        e.call.callee.* == .ident and
                        std.mem.eql(u8, e.call.callee.ident.name, gtr.name))
                    {
                        try g.w.writeAll(kw);
                        try g.w.writeAll(" ");
                        try g.w.writeAll(n.name);
                        try g.w.writeAll(" = ");
                        try g.genStdlibInit(gtr);
                        try g.w.writeAll(";\n");
                        // No defer deinit: all Zebra programs use an arena allocator.
                        // Individual deinit calls are unnecessary (the arena frees everything
                        // at once) and harmful: Allocator.free poisons the buffer with 0xAA
                        // before rawFree, corrupting any struct that still holds a pointer to
                        // the same buffer (e.g. a List passed into a PBinary constructor).
                        return;
                    }
                }
            }
        }

        // Lambda with a capture block — emit as a struct instance, not a fn ptr.
        // Register the name so call sites use `name.call(args)`.
        if (n.init) |e| {
            if (e.* == .lambda and e.lambda.capture.len > 0) {
                if (g.closure_vars) |cv| try cv.put(n.name, {});
                // The struct variable itself uses the normal const/var analysis.
                // Mutable captures are handled via `self: *@This()` in the call method,
                // and _gui_run/_http_serve make a `var _mframe = frame` copy internally.
                try g.w.writeAll(kw);
                try g.w.writeAll(" ");
                try g.w.writeAll(n.name);
                try g.w.writeAll(" = ");
                try g.genCaptureClosureStruct(e.lambda);
                try g.w.writeAll(";\n");
                return;
            }
        }

        // Mutable fn-ref vars: Zig requires `*const fn(P) R` type — you cannot have
        // a `var` of bare function type.  Emit `var name: @TypeOf(&func) = &func;`.
        if (std.mem.eql(u8, kw, "var") and tc_init_type == .fn_ref) {
            if (n.init) |e| {
                if (e.* == .ident) {
                    const fname = e.ident.name;
                    try g.w.print("var {s}: @TypeOf(&{s}) = &{s};\n", .{ n.name, fname, fname });
                    return;
                }
            }
        }

        try g.w.writeAll(kw);
        try g.w.writeAll(" ");
        try g.w.writeAll(n.name);
        if (n.type_) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        } else if (std.mem.eql(u8, kw, "var")) {
            // Mutable var without explicit type: emit TC-inferred type annotation
            // to avoid "comptime_int / *const [N:0]u8 / comptime_float must be
            // const" errors in Zig and to prevent slice-vs-array type mismatches.
            if (n.init) |e| {
                if (g.tc) |tc| {
                    const t = tc.expr_types.get(e) orelse .unknown;
                    if (try tcTypeAnnotation(t, g.alloc)) |ann| {
                        defer g.alloc.free(ann);
                        try g.w.writeAll(": ");
                        try g.w.writeAll(ann);
                    }
                }
            }
        }
        if (n.init) |e| {
            try g.w.writeAll(" = ");
            // fn_ref init into a sig-typed var: `var pred as CharPred = isAlpha`
            // → emit `&isAlpha` so Zig gets a function pointer.
            if (tc_init_type == .fn_ref and n.type_ != null) {
                try g.w.writeAll("&");
            }
            try g.genExpr(e);
            // Inside a try/catch block, if the initializer is a call to a `throws` method
            // (including cross-module calls like `Lexer.tokenize(...)`), redirect the error
            // to the block's tracking variable so the catch clause fires.
            if (e.* == .call and g.try_block_label != null and
                exprCallIsThrows(e.call, g.resolve, g.imported_modules, g.owner_members))
            {
                const ev  = g.try_err_var.?;
                const lbl = g.try_block_label.?;
                try g.w.print(" catch |_e| {{ {s} = _e; break :{s}; }}", .{ ev, lbl });
            }
        } else {
            // For List(T) / HashMap(K,V) declared with no init expression, emit an
            // empty initializer instead of `undefined`.  `undefined` produces a
            // crash on the first `add`/`put` call because the ArrayList backing
            // pointer is garbage.  This is the "var decls as List(PNode)" pattern
            // used throughout the self-hosting parser.
            const is_empty_list_or_map: bool = blk: {
                if (n.type_) |tr| {
                    if (tr == .generic) {
                        const gn = tr.generic.name;
                        break :blk std.mem.eql(u8, gn, "List") or std.mem.eql(u8, gn, "HashMap");
                    }
                }
                break :blk false;
            };
            if (is_empty_list_or_map) {
                try g.w.writeAll(" = ");
                try g.genStdlibInit(n.type_.?.generic);
            } else {
                try g.w.writeAll(" = undefined");
            }
        }
        try g.w.writeAll(";\n");
        // List/HashMap vars initialized from non-constructor exprs (e.g. File.readLines,
        // No defer deinit for List/HashMap: the arena allocator owns all memory and
        // frees everything at program exit. Individual deinit calls are harmful because
        // Allocator.free poisons the freed buffer with 0xAA via @memset before calling
        // rawFree — corrupting any struct that still holds a pointer to the same buffer.
        // Allocated string vars (concat, format) need explicit free —
        // unless the variable is returned from this function (caller takes ownership).
        if (n.init) |e| {
            const is_returned = if (g.returned_names) |rn| rn.contains(n.name) else false;
            if (!is_returned and isAllocatingStringInit(e, g.tc)) {
                try g.writeIndent();
                try g.w.print("defer _allocator.free({s});\n", .{n.name});
            }
        }
    }

    /// True when `expr` is a call that allocates a heap-owned string.
    fn isAllocatingStringInit(e: *const Ast.Expr, tc_opt: ?*const TypeChecker.TypeCheckResult) bool {
        // String interpolation allocates via allocPrint.
        if (e.* == .string_interp) return true;
        if (e.* != .call) return false;
        const callee = e.call.callee;
        if (callee.* != .member) return false;
        const obj = callee.member.object;
        const m   = callee.member.member;
        // Methods that allocate a new string via _allocator.
        const str_allocating = std.StaticStringMap(void).initComptime(&.{
            .{ "concat",   {} }, .{ "format",   {} }, .{ "upper",    {} },
            .{ "lower",    {} }, .{ "replace",  {} }, .{ "repeat",   {} },
            .{ "toString", {} }, .{ "padLeft",  {} }, .{ "padRight", {} },
            .{ "center",   {} }, .{ "join",     {} }, .{ "reverse",  {} },
            .{ "toHex",    {} }, .{ "fromHex",  {} },
        });
        if (str_allocating.get(m) != null) {
            // Exclude regex/network method calls — they use page_allocator, not _allocator.
            if (tc_opt) |tc| {
                const recv = tc.expr_types.get(obj) orelse .unknown;
                if (recv == .regex or recv == .tcp_conn or recv == .udp_socket) return false;
            }
            return true;
        }
        // File.read allocates a string. File.readLines/listDir return a List — handled separately.
        if (obj.* == .ident and std.mem.eql(u8, obj.ident.name, "File")) {
            if (std.mem.eql(u8, m, "read")) return true;
        }
        // Shell.run allocates stdout+stderr via concat.
        if (obj.* == .ident and std.mem.eql(u8, obj.ident.name, "Shell")) {
            if (std.mem.eql(u8, m, "run")) return true;
        }
        // Extension method calls that return a string allocate via _allocator.
        if (tc_opt) |tc| {
            const obj_type = tc.expr_types.get(obj) orelse .unknown;
            const tname: ?[]const u8 = switch (obj_type) {
                .string => "String",
                .int    => "int",
                .uint   => "uint",
                .float  => "float",
                .bool   => "bool",
                .char   => "char",
                .named  => |sym| switch (sym.decl) {
                    .class     => |c| c.name,
                    .struct_   => |s| s.name,
                    .interface => |i| i.name,
                    else       => null,
                },
                else => null,
            };
            if (tname) |tn| {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, m})) |key| {
                    if (tc.ext_methods.get(key)) |ext_meth| {
                        if (ext_meth.return_type) |*rt| {
                            const rname = switch (rt.*) {
                                .named => |n| n.name,
                                else   => "",
                            };
                            if (Builtins.isStringTypeName(rname)) return true;
                        }
                    }
                } else |_| {}
            }
        }
        return false;
    }

    // ── Stdlib type initialisation ────────────────────────────────────────────

    /// Emit the Zig init expression for a stdlib generic type.
    ///   List(int)       → std.ArrayList(i64){}   (Zig 0.15: unmanaged, alloc per-op)
    ///   HashMap(str, T) → std.StringHashMap(T).init(_allocator)
    ///   HashMap(K, V)   → std.AutoHashMap(K, V).init(_allocator)
    fn genStdlibInit(g: Generator, gtr: Ast.GenericTypeRef) anyerror!void {
        if (std.mem.eql(u8, gtr.name, "List")) {
            // Zig 0.15 ArrayList is unmanaged: initialise with {}
            try g.genType(.{ .generic = gtr });
            try g.w.writeAll("{}");
        } else {
            try g.genType(.{ .generic = gtr });
            try g.w.writeAll(".init(_allocator)");
        }
    }

    // ── Stdlib method / property dispatch ────────────────────────────────────
    //
    // Returns true and emits code if `method` on a value of type `tr` is a
    // known stdlib operation.  Returns false and emits nothing otherwise.

    /// Emit `@as(i64, @intCast(<object>.items.len))`.
    /// Single canonical site for all List.len / List.count emissions so
    /// the usize→i64 cast is never forgotten.
    fn writeListLen(g: Generator, object: *const Ast.Expr) anyerror!void {
        try g.w.writeAll("@as(i64, @intCast(");
        try g.genExpr(object);
        try g.w.writeAll(".items.len))");
    }

    fn genStdlibMethod(
        g:      Generator,
        object: *const Ast.Expr,
        tr:     Ast.TypeRef,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        switch (tr) {
            .generic => |gtr| {
                if (std.mem.eql(u8, gtr.name, "List")) {
                    return g.genListMethod(object, method, args);
                }
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    const key_is_str = gtr.args.len >= 1 and isStringTypeRef(gtr.args[0]);
                    return g.genHashMapMethod(object, key_is_str, method, args);
                }
                if (std.mem.eql(u8, gtr.name, "Result")) {
                    return g.genResultMethod(object, method, args);
                }
            },
            .named => |n| {
                if (isStringTypeName(n.name)) return g.genStringMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "StringBuilder")) return g.genStringBuilderMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "char")) return g.genCharMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "TcpConn"))    return g.genTcpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "UdpSocket"))  return g.genUdpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "Regex"))      return g.genRegexMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "Gui"))        return g.genGuiWidgetMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "JsonValue"))  return g.genJsonMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "DateTime"))   return g.genDateTimeMethod(object, method, args);
                // toString() on int/float/bool — format as string.
                if (std.mem.eql(u8, method, "toString")) {
                    const fmt = if (std.mem.eql(u8, n.name, "float") or
                                    std.mem.eql(u8, n.name, "num")   or
                                    std.mem.eql(u8, n.name, "decimal")) "{d}" else "{}";
                    try g.w.print("(std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt});
                    try g.genExpr(object);
                    try g.w.writeAll("}) catch unreachable)");
                    return true;
                }
            },
            else => {
                // Unknown type — try toString via TC inferred type.
                if (std.mem.eql(u8, method, "toString")) {
                    const tc_type = if (g.tc) |tc| tc.expr_types.get(object) orelse .unknown else .unknown;
                    const fmt: []const u8 = switch (tc_type) {
                        .float => "{d}",
                        else   => "{}",
                    };
                    try g.w.print("(std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt});
                    try g.genExpr(object);
                    try g.w.writeAll("}) catch unreachable)");
                    return true;
                }
                // Unknown type — try List dispatch for known list method names.
                // This handles e.g. sys.args() which is inferred as .unknown but
                // holds a std.ArrayList at runtime.
                const list_methods = std.StaticStringMap(void).initComptime(&.{
                    .{ "add", {} }, .{ "at", {} }, .{ "remove", {} },
                    .{ "clear", {} }, .{ "contains", {} }, .{ "count", {} },
                    .{ "sort", {} }, .{ "sortBy", {} },
                });
                if (list_methods.get(method) != null) {
                    return g.genListMethod(object, method, args);
                }
            },
        }
        return false;
    }

    fn genStdlibProp(
        g:      Generator,
        object: *const Ast.Expr,
        tr:     Ast.TypeRef,
        prop:   []const u8,
    ) anyerror!bool {
        switch (tr) {
            .generic => |gtr| {
                if (std.mem.eql(u8, gtr.name, "List")) {
                    if (std.mem.eql(u8, prop, "len") or std.mem.eql(u8, prop, "count")) {
                        try g.writeListLen(object);
                        return true;
                    }
                }
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    if (std.mem.eql(u8, prop, "len") or std.mem.eql(u8, prop, "count")) {
                        try g.genExpr(object);
                        try g.w.writeAll(".count()");
                        return true;
                    }
                }
            },
            .named => |n| {
                if (isStringTypeName(n.name) and std.mem.eql(u8, prop, "len")) {
                    try g.genExpr(object);
                    try g.w.writeAll(".len");
                    return true;
                }
                if (std.mem.eql(u8, n.name, "DateTime")) {
                    const dt_fields = std.StaticStringMap([]const u8).initComptime(&.{
                        .{ "year", "year" }, .{ "month", "month" }, .{ "day", "day" },
                        .{ "hour", "hour" }, .{ "minute", "minute" }, .{ "second", "second" },
                    });
                    if (dt_fields.get(prop)) |field| {
                        try g.w.writeAll("_dt_to_gregorian(");
                        try g.genExpr(object);
                        try g.w.print(".epoch_ms).{s}", .{field});
                        return true;
                    }
                    if (std.mem.eql(u8, prop, "weekday")) {
                        try g.w.writeAll("_dt_weekday(");
                        try g.genExpr(object);
                        try g.w.writeAll(")");
                        return true;
                    }
                }
            },
            else => {
                // Unknown type — treat len/count as ArrayList .items.len fallback.
                if (std.mem.eql(u8, prop, "len") or std.mem.eql(u8, prop, "count")) {
                    try g.genExpr(object);
                    try g.w.writeAll(".items.len");
                    return true;
                }
            },
        }
        return false;
    }

    // ── File I/O static methods ───────────────────────────────────────────────

    /// Emit a static `File.*` call.
    ///
    ///   File.read(path)            → []u8  (allocates; call in throws context)
    ///   File.write(path, content)  → void
    ///   File.exists(path)          → bool  (no allocation, no error)
    ///   File.readLines(path)       → List(str) — convenience wrapper
    fn genFileCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "read")) {
            // File.read(path) → std.fs.cwd().readFileAlloc(_allocator, path, max)
            try g.w.writeAll("(std.fs.cwd().readFileAlloc(_allocator, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", std.math.maxInt(usize)) catch @panic(\"File.read error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "write")) {
            // File.write(path, content) → std.fs.cwd().writeFile(...)
            try g.w.writeAll("(std.fs.cwd().writeFile(.{ .sub_path = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .data = ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(" }) catch @panic(\"File.write error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "exists")) {
            // File.exists(path) → labelled block: access → true, else false
            try g.w.writeAll("(blk: { std.fs.cwd().access(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "readLines")) {
            // File.readLines(path) → read whole file and split on newlines into ArrayList
            // Emits a block that builds an ArrayList([]const u8).
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fl_content = std.fs.cwd().readFileAlloc(_allocator, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", std.math.maxInt(usize)) catch @panic(\"File.readLines error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _fl_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _fl_it = std.mem.splitScalar(u8, _fl_content, '\\n');\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_fl_it.next()) |_fl_line| {\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("_fl_list.append(_allocator, _fl_line) catch unreachable;\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _fl_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "append")) {
            // File.append(path, content) → append content; creates file if absent.
            // openFile with read_write; fall back to createFile if not found.
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fa_path = ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _fa_file = std.fs.cwd().openFile(_fa_path, .{ .mode = .read_write })\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("catch std.fs.cwd().createFile(_fa_path, .{}) catch @panic(\"File.append error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _fa_file.close();\n");
            try bg.writeIndent();
            try bg.w.writeAll("_ = _fa_file.seekFromEnd(0) catch @panic(\"File.append seek error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("_fa_file.writeAll(");
            if (args.len >= 2) try bg.genExpr(args[1].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(") catch @panic(\"File.append write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk {};\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "delete")) {
            // File.delete(path) → delete file (ignores not-found)
            try g.w.writeAll("(std.fs.cwd().deleteFile(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_fd_err| { if (_fd_err != error.FileNotFound) @panic(\"File.delete error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "rename")) {
            // File.rename(oldPath, newPath) → rename/move within cwd.
            // std.fs.Dir.rename(old, new) — both relative to the same Dir.
            try g.w.writeAll("(std.fs.cwd().rename(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"File.rename error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "copy")) {
            // File.copy(src, dst) → copy file contents
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _fc_data = std.fs.cwd().readFileAlloc(_allocator, ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", std.math.maxInt(usize)) catch @panic(\"File.copy read error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("std.fs.cwd().writeFile(.{ .sub_path = ");
            if (args.len >= 2) try bg.genExpr(args[1].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(", .data = _fc_data }) catch @panic(\"File.copy write error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk {};\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "listDir")) {
            // File.listDir(path) → ArrayList([]const u8) of entry names in directory.
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_dir = std.fs.cwd().openDir(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"\n");
            try bg.w.writeAll(", .{ .iterate = true }) catch @panic(\"File.listDir error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _ld_dir.close();\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _ld_iter = _ld_dir.iterate();\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_ld_iter.next() catch null) |_ld_entry| {\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("_ld_list.append(_allocator, _allocator.dupe(u8, _ld_entry.name) catch @panic(\"OOM\")) catch @panic(\"OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _ld_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Dir static methods ────────────────────────────────────────────────────
    //
    //   Dir.create(path)        → void (creates; no-op if exists)
    //   Dir.createAll(path)     → void (creates all intermediate dirs)
    //   Dir.delete(path)        → void (removes empty dir; ignores not-found)
    //   Dir.deleteAll(path)     → void (removes dir tree recursively)
    //   Dir.exists(path)        → bool
    //   Dir.list(path)          → List(str)  (entry names)
    fn genDirCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "create")) {
            try g.w.writeAll("(std.fs.cwd().makeDir(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_dc_err| { if (_dc_err != error.PathAlreadyExists) @panic(\"Dir.create error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "createAll")) {
            try g.w.writeAll("(std.fs.cwd().makePath(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.createAll error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "delete")) {
            try g.w.writeAll("(std.fs.cwd().deleteDir(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch |_dd_err| { if (_dd_err != error.FileNotFound) @panic(\"Dir.delete error\"); })");
            return true;
        }
        if (std.mem.eql(u8, method, "deleteAll")) {
            try g.w.writeAll("(std.fs.cwd().deleteTree(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"Dir.deleteAll error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "exists")) {
            // Open the directory to check; access() only works for files.
            try g.w.writeAll("(blk: { var _de_d = std.fs.cwd().openDir(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", .{}) catch break :blk false; _de_d.close(); break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "list")) {
            // Dir.list(path) → ArrayList([]const u8) of entry names
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_dir = std.fs.cwd().openDir(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\".\"\n");
            try bg.w.writeAll(", .{ .iterate = true }) catch @panic(\"Dir.list error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("defer _dl_dir.close();\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _dl_iter = _dl_dir.iterate();\n");
            try bg.writeIndent();
            try bg.w.writeAll("while (_dl_iter.next() catch null) |_dl_entry| {\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("_dl_list.append(_allocator, _allocator.dupe(u8, _dl_entry.name) catch @panic(\"OOM\")) catch @panic(\"OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("}\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _dl_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Path static methods ───────────────────────────────────────────────────
    //
    //   Path.join(a, b)     → str   (join two path segments)
    //   Path.basename(path) → str   (last component, no trailing separator)
    //   Path.dirname(path)  → str   (parent directory)
    //   Path.ext(path)      → str   (file extension including dot, or "" if none)
    //   Path.stem(path)     → str   (basename without extension)
    //   Path.isAbsolute(path) → bool
    fn genPathCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "join")) {
            // Path.join(a, b) — use std.fs.path.join
            try g.w.writeAll("(std.fs.path.join(_allocator, &.{");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            if (args.len >= 2) { try g.w.writeAll(", "); try g.genExpr(args[1].value); }
            if (args.len >= 3) { try g.w.writeAll(", "); try g.genExpr(args[2].value); }
            try g.w.writeAll("}) catch @panic(\"Path.join error\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "basename")) {
            try g.w.writeAll("(std.fs.path.basename(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "dirname")) {
            // dirname returns ?[]const u8; unwrap to "" if root.
            try g.w.writeAll("(std.fs.path.dirname(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") orelse \"\")");
            return true;
        }
        if (std.mem.eql(u8, method, "ext")) {
            try g.w.writeAll("(std.fs.path.extension(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "stem")) {
            // stem = basename without extension
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _ps_base = std.fs.path.basename(");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(");\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _ps_ext = std.fs.path.extension(_ps_base);\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _ps_base[0 .. _ps_base.len - _ps_ext.len];\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "isAbsolute")) {
            try g.w.writeAll("(std.fs.path.isAbsolute(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("))");
            return true;
        }
        return false;
    }

    // ── sys static methods ────────────────────────────────────────────────────

    /// Emit a static `sys.*` call.
    ///
    ///   sys.args()          → ArrayList([]const u8) of command-line args (alloc'd)
    ///   sys.exit(code)      → std.process.exit(code)  — noreturn
    // ── Math static methods ───────────────────────────────────────────────────
    //
    // All trig/exp/log/rounding functions coerce to f64 via @as(f64, arg).
    // abs/min/max/clamp use Zig builtins and work on any numeric type.
    // Constants (Math.PI etc.) are handled in genExpr .member, not here.
    fn genMathCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        // Helper: emit a single-arg f64 std.math call
        const one = struct {
            fn emit(gg: Generator, fname: []const u8, as_: []const Ast.Arg) anyerror!void {
                try gg.w.writeAll("std.math.");
                try gg.w.writeAll(fname);
                try gg.w.writeAll("(@as(f64, ");
                if (as_.len >= 1) try gg.genExpr(as_[0].value) else try gg.w.writeAll("0");
                try gg.w.writeAll("))");
            }
        }.emit;

        if (std.mem.eql(u8, method, "sin"))   { try one(g, "sin",   args); return true; }
        if (std.mem.eql(u8, method, "cos"))   { try one(g, "cos",   args); return true; }
        if (std.mem.eql(u8, method, "tan"))   { try one(g, "tan",   args); return true; }
        if (std.mem.eql(u8, method, "asin"))  { try one(g, "asin",  args); return true; }
        if (std.mem.eql(u8, method, "acos"))  { try one(g, "acos",  args); return true; }
        if (std.mem.eql(u8, method, "atan"))  { try one(g, "atan",  args); return true; }
        if (std.mem.eql(u8, method, "sqrt"))  { try one(g, "sqrt",  args); return true; }
        if (std.mem.eql(u8, method, "exp"))   { try one(g, "exp",   args); return true; }
        if (std.mem.eql(u8, method, "floor")) { try one(g, "floor", args); return true; }
        if (std.mem.eql(u8, method, "ceil"))  { try one(g, "ceil",  args); return true; }
        if (std.mem.eql(u8, method, "round")) { try one(g, "round", args); return true; }
        if (std.mem.eql(u8, method, "trunc")) { try one(g, "trunc", args); return true; }
        if (std.mem.eql(u8, method, "log2"))  { try one(g, "log2",  args); return true; }
        if (std.mem.eql(u8, method, "log10")) { try one(g, "log10", args); return true; }
        if (std.mem.eql(u8, method, "isNaN")) { try one(g, "isNan", args); return true; }
        if (std.mem.eql(u8, method, "isInf")) { try one(g, "isInf", args); return true; }
        if (std.mem.eql(u8, method, "log")) {
            // natural log: std.math.log(f64, e, x)
            try g.w.writeAll("std.math.log(f64, std.math.e, @as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "atan2")) {
            try g.w.writeAll("std.math.atan2(@as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        if (std.mem.eql(u8, method, "pow")) {
            try g.w.writeAll("std.math.pow(f64, @as(f64, ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("), @as(f64, ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll("))");
            return true;
        }
        // abs / min / max / clamp use builtins (work on int and float)
        if (std.mem.eql(u8, method, "abs")) {
            try g.w.writeAll("@abs(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "min")) {
            try g.w.writeAll("@min(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "max")) {
            try g.w.writeAll("@max(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        if (std.mem.eql(u8, method, "clamp")) {
            try g.w.writeAll("std.math.clamp(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("0");
            try g.w.writeByte(')');
            return true;
        }
        return false;
    }

    ///   sys.err(msg)        → write msg to stderr (no newline)
    ///   sys.errln(msg)      → write msg + newline to stderr
    ///   sys.getenv(name)    → ?[]const u8 via std.posix.getenv
    fn genSysCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "args")) {
            // sys.args() → build an ArrayList from argsAlloc result
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _sa_raw = std.process.argsAlloc(_allocator) catch @panic(\"sys.args OOM\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("var _sa_list = std.ArrayList([]const u8){};\n");
            try bg.writeIndent();
            try bg.w.writeAll("for (_sa_raw) |_sa_arg| _sa_list.append(_allocator, _sa_arg) catch unreachable;\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk _sa_list;\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "exit")) {
            try g.w.writeAll("std.process.exit(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "err")) {
            try g.w.writeAll("std.debug.print(\"{s}\", .{");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "errln")) {
            try g.w.writeAll("std.debug.print(\"{s}\\n\", .{");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll("})");
            return true;
        }
        if (std.mem.eql(u8, method, "getenv")) {
            try g.w.writeAll("std.posix.getenv(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "run")) {
            // sys.run(argv as List(str)) → _SysRunResult
            try g.w.writeAll("_sys_run(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Shell static methods ──────────────────────────────────────────────────

    /// Emit a static `Shell.*` call.
    // ── Json static methods ──────────────────────────────────────────────────

    // ── DateTime static + instance methods ───────────────────────────────────

    fn genDateTimeCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "now")) {
            try g.w.writeAll("_dt_now()");
            return true;
        }
        if (std.mem.eql(u8, method, "fromEpoch")) {
            try g.w.writeAll("_DateTime{ .epoch_ms = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "of")) {
            try g.w.writeAll("_dt_from_gregorian(");
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            // Fill missing hour/minute/second with 0
            const provided = args.len;
            if (provided < 4) try g.w.writeAll(", 0");
            if (provided < 5) try g.w.writeAll(", 0");
            if (provided < 6) try g.w.writeAll(", 0");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genDateTimeMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        // Arithmetic — return new _DateTime
        const arith_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "addDays",    "_dt_add_days" },
            .{ "addHours",   "_dt_add_hours" },
            .{ "addMinutes", "_dt_add_minutes" },
            .{ "addSeconds", "_dt_add_seconds" },
            .{ "addMonths",  "_dt_add_months" },
            .{ "addYears",   "_dt_add_years" },
        });
        if (arith_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        // Comparison
        if (std.mem.eql(u8, method, "before")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms < ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        if (std.mem.eql(u8, method, "after")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms > ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        if (std.mem.eql(u8, method, "equals")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms == ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        // Interval
        if (std.mem.eql(u8, method, "daysBetween")) {
            try g.w.writeAll("_dt_days_between(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "secondsBetween")) {
            try g.w.writeAll("_dt_seconds_between(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_dt_now()");
            try g.w.writeAll(")");
            return true;
        }
        // Serialization
        if (std.mem.eql(u8, method, "toEpoch")) {
            try g.genExpr(object);
            try g.w.writeAll(".epoch_ms");
            return true;
        }
        if (std.mem.eql(u8, method, "toIso8601")) {
            try g.w.writeAll("_dt_to_iso8601(");
            try g.genExpr(object);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "format")) {
            try g.w.writeAll("_dt_format(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        // Calendar view
        if (std.mem.eql(u8, method, "inCalendar")) {
            try g.w.writeAll("_dt_in_calendar(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("Calendar.Gregorian");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genJsonCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_json_parse(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"{}\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "stringify")) {
            try g.w.writeAll("_json_stringify(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("_json_object()");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "object")) {
            try g.w.writeAll("_json_object()");
            return true;
        }
        if (std.mem.eql(u8, method, "array")) {
            try g.w.writeAll("_json_array()");
            return true;
        }
        return false;
    }

    // ── Hash static calls ────────────────────────────────────────────────────
    fn genHashCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const fn_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "sha256",  "_hash_sha256"  },
            .{ "sha512",  "_hash_sha512"  },
            .{ "md5",     "_hash_md5"     },
            .{ "blake3",  "_hash_blake3"  },
        });
        if (fn_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "hmac256")) {
            try g.w.writeAll("_hash_hmac256(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Random static calls ──────────────────────────────────────────────────
    fn genRandomCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "randInt")) {
            try g.w.writeAll("_random_int(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("100");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "randFloat")) { try g.w.writeAll("_random_float()");  return true; }
        if (std.mem.eql(u8, method, "randBool"))  { try g.w.writeAll("_random_bool()");   return true; }
        if (std.mem.eql(u8, method, "bytes")) {
            try g.w.writeAll("_random_bytes(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("16");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "seed")) {
            try g.w.writeAll("_random_seed(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        // choice(list) — emit inline index expression
        if (std.mem.eql(u8, method, "choice")) {
            if (args.len >= 1) {
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items[_rng().uintLessThan(usize, ");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items.len)]");
            }
            return true;
        }
        // shuffle(list) — emit inline call
        if (std.mem.eql(u8, method, "shuffle")) {
            if (args.len >= 1) {
                try g.w.writeAll("(if (");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items.len > 0) _rng().shuffle(@TypeOf(");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items[0]), ");
                try g.genExpr(args[0].value);
                try g.w.writeAll(".items))");
            }
            return true;
        }
        return false;
    }

    // ── Arg static calls ─────────────────────────────────────────────────────
    fn genArgCall(g: Generator, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_arg_parse()");
            return true;
        }
        return false;
    }

    // ── ArgResult instance method calls ─────────────────────────────────────
    fn genArgResultMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const pass_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "flag", {} }, .{ "contains", {} }, .{ "option", {} },
            .{ "optionInt", {} }, .{ "positional", {} }, .{ "usage", {} },
        });
        if (pass_methods.get(method) != null) {
            // Emit obj.method(args) — these are struct pub fns, so pass-through works directly.
            try g.genExpr(obj);
            try g.w.print(".{s}(", .{method});
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Terminal static calls ─────────────────────────────────────────────────
    fn genTerminalCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "isTty"))  { try g.w.writeAll("_term_is_tty()");  return true; }
        if (std.mem.eql(u8, method, "width"))  { try g.w.writeAll("_term_width()");   return true; }
        if (std.mem.eql(u8, method, "height")) { try g.w.writeAll("_term_height()");  return true; }
        // write(msg, color) and writeln(msg, color) → _term_print(msg, color, newline)
        const is_println = std.mem.eql(u8, method, "writeln");
        if (is_println or std.mem.eql(u8, method, "write")) {
            try g.w.writeAll("_term_print(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(if (is_println) ", true)" else ", false)");
            return true;
        }
        return false;
    }

    // ── Log static calls ─────────────────────────────────────────────────────
    fn genLogCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const level_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "debug", "_log_debug" },
            .{ "info",  "_log_info"  },
            .{ "warn",  "_log_warn"  },
            .{ "err",   "_log_err"   },
        });
        if (level_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setLevel")) {
            // Accepts a string: "debug"/"info"/"warn"/"err"
            try g.w.writeAll("_log_set_level(");
            if (args.len >= 1) {
                // Inline the level number from the string literal if possible
                const arg = args[0].value;
                if (arg.* == .string_lit) {
                    // Strip surrounding quotes from the raw text.
                    const raw = arg.string_lit.text;
                    const lv = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                    if (std.mem.eql(u8, lv, "debug"))      try g.w.writeAll("0")
                    else if (std.mem.eql(u8, lv, "info"))  try g.w.writeAll("1")
                    else if (std.mem.eql(u8, lv, "warn"))  try g.w.writeAll("2")
                    else if (std.mem.eql(u8, lv, "err"))   try g.w.writeAll("3")
                    else try g.genExpr(arg);
                } else try g.genExpr(arg);
            } else try g.w.writeAll("1");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "setOutput")) {
            // Accepts "stderr" or "stdout"
            try g.w.writeAll("_log_set_output_stderr(");
            if (args.len >= 1) {
                const arg = args[0].value;
                const raw2 = if (arg.* == .string_lit) arg.string_lit.text else "";
                const lv2  = if (raw2.len >= 2) raw2[1 .. raw2.len - 1] else raw2;
                if (arg.* == .string_lit and std.mem.eql(u8, lv2, "stdout"))
                    try g.w.writeAll("false")
                else
                    try g.w.writeAll("true");
            } else try g.w.writeAll("true");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "timestamp")) {
            try g.w.writeAll("_log_timestamp(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("true");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Uri static calls ─────────────────────────────────────────────────────
    fn genUriCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_uri_parse(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Compress static calls ────────────────────────────────────────────────
    fn genCompressCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "gzip")) {
            try g.w.writeAll("_compress_gzip(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "gunzip")) {
            try g.w.writeAll("_compress_gunzip(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Mime static calls ────────────────────────────────────────────────────
    fn genMimeCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "fromExt")) {
            try g.w.writeAll("_mime_from_ext(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "toExt")) {
            try g.w.writeAll("_mime_to_ext(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Timer static calls ───────────────────────────────────────────────────
    fn genTimerCall(g: Generator, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "start")) {
            try g.w.writeAll("_timer_start()");
            return true;
        }
        return false;
    }

    // ── TimerHandle instance method calls ────────────────────────────────────
    fn genTimerResultMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, _: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "elapsed")) {
            try g.genExpr(obj);
            try g.w.writeAll(".elapsed()");
            return true;
        }
        if (std.mem.eql(u8, method, "elapsedMicros")) {
            try g.genExpr(obj);
            try g.w.writeAll(".elapsedMicros()");
            return true;
        }
        if (std.mem.eql(u8, method, "reset")) {
            try g.genExpr(obj);
            try g.w.writeAll(".reset()");
            return true;
        }
        return false;
    }

    // ── JsonValue instance methods ───────────────────────────────────────────

    fn genJsonMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        // Read-only accessors: emit _json_get_*(v, key)
        const read_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "getStr",   "_json_get_str"   },
            .{ "getInt",   "_json_get_int"   },
            .{ "getFloat", "_json_get_float" },
            .{ "getBool",  "_json_get_bool"  },
            .{ "getObj",   "_json_get_obj"   },
            .{ "getList",  "_json_get_list"  },
        });
        if (read_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(");
            try g.genExpr(object);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        // Predicate methods: emit _json_is_*(v)
        if (std.mem.eql(u8, method, "isNull")) {
            try g.w.writeAll("_json_is_null("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "isObject")) {
            try g.w.writeAll("_json_is_object("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "isArray")) {
            try g.w.writeAll("_json_is_array("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        // Stringify: emit _json_stringify(v)
        if (std.mem.eql(u8, method, "stringify")) {
            try g.w.writeAll("_json_stringify("); try g.genExpr(object); try g.w.writeAll(")"); return true;
        }
        // Mutating methods on object: emit _json_put_*(v_ptr, key, val)
        const put_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "put",      "_json_put_str"   },
            .{ "putInt",   "_json_put_int"   },
            .{ "putFloat", "_json_put_float" },
            .{ "putBool",  "_json_put_bool"  },
        });
        if (put_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(&");
            try g.genExpr(object);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return true;
        }
        // Mutating methods on array: emit _json_arr_*(v_ptr, val)
        const arr_map = std.StaticStringMap([]const u8).initComptime(&.{
            .{ "append",      "_json_arr_str"   },
            .{ "appendInt",   "_json_arr_int"   },
            .{ "appendFloat", "_json_arr_float" },
            .{ "appendBool",  "_json_arr_bool"  },
        });
        if (arr_map.get(method)) |fn_name| {
            try g.w.writeAll(fn_name);
            try g.w.writeAll("(&");
            try g.genExpr(object);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    ///
    ///   Shell.run(cmd)  → []u8  stdout+stderr combined; cross-platform (cmd/sh)
    fn genShellCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "run")) {
            try g.w.writeAll("(blk: {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.writeAll("const _sh_cmd = ");
            if (args.len >= 1) try bg.genExpr(args[0].value) else try bg.w.writeAll("\"\"");
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _sh_argv = if (comptime builtin.os.tag == .windows)\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("@as([]const []const u8, &[_][]const u8{ \"cmd\", \"/c\", _sh_cmd })\n");
            try bg.writeIndent();
            try bg.w.writeAll("else\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll("@as([]const []const u8, &[_][]const u8{ \"sh\", \"-c\", _sh_cmd });\n");
            try bg.writeIndent();
            try bg.w.writeAll("const _sh_res = std.process.Child.run(.{\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll(".allocator = _allocator,\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll(".argv = _sh_argv,\n");
            try bg.indented().writeIndent();
            try bg.indented().w.writeAll(".max_output_bytes = 1024 * 1024,\n");
            try bg.writeIndent();
            try bg.w.writeAll("}) catch @panic(\"Shell.run error\");\n");
            try bg.writeIndent();
            try bg.w.writeAll("break :blk std.mem.concat(_allocator, u8, &[_][]const u8{ _sh_res.stdout, _sh_res.stderr }) catch @panic(\"OOM\");\n");
            try g.writeIndent();
            try g.w.writeAll("})");
            return true;
        }
        return false;
    }

    // ── Http static methods ───────────────────────────────────────────────────

    /// Emit a static `Http.*` call.
    ///
    ///   Http.get(url)           → _HttpResponse via _http_get(url)
    ///   Http.post(url, payload) → _HttpResponse via _http_post(url, payload)
    fn genHttpCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "get")) {
            try g.w.writeAll("_http_get(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "post")) {
            try g.w.writeAll("_http_post(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "serve")) {
            try g.w.writeAll("_http_serve(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("8080");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "json")) {
            try g.w.writeAll("_http_json_get(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "postJson")) {
            try g.w.writeAll("_http_json_post(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── HttpResponse factory methods ─────────────────────────────────────────

    fn genHttpResponseFactory(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "ok")) {
            try g.w.writeAll("HttpResponse{ .status = 200, .text = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "notFound")) {
            try g.w.writeAll("HttpResponse{ .status = 404, .text = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"Not Found\"");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "err")) {
            try g.w.writeAll("HttpResponse{ .status = 500, .text = ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"Internal Server Error\"");
            try g.w.writeAll(" }");
            return true;
        }
        if (std.mem.eql(u8, method, "new")) {
            try g.w.writeAll("HttpResponse{ .status = @intCast(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("200");
            try g.w.writeAll("), .text = ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(" }");
            return true;
        }
        return false;
    }

    // ── HttpResponse instance methods ─────────────────────────────────────────

    fn genHttpResponseMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "withHeader")) {
            try g.w.writeAll("_http_with_header(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Csv static + instance methods ────────────────────────────────────────

    fn genCsvCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "parse")) {
            try g.w.writeAll("_csv_parse(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "parseFile")) {
            try g.w.writeAll("_csv_parse_file(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genCsvMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "rowCount")) {
            try g.w.writeAll("_csv_row_count("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "colCount")) {
            try g.w.writeAll("_csv_col_count("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "header")) {
            try g.w.writeAll("_csv_header("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "row")) {
            try g.w.writeAll("_csv_row(");
            try g.genExpr(obj); try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "rows")) {
            try g.w.writeAll("_csv_rows("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "dataRows")) {
            try g.w.writeAll("_csv_data_rows("); try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "get")) {
            try g.w.writeAll("_csv_get(");
            try g.genExpr(obj); try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")"); return true;
        }
        return false;
    }

    fn genCsvWriterMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "writeRow")) {
            try g.w.writeAll("_csv_write_row(&");
            try g.genExpr(obj); try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")"); return true;
        }
        if (std.mem.eql(u8, method, "build")) {
            try g.w.writeAll("_csv_build(&");
            try g.genExpr(obj); try g.w.writeAll(")"); return true;
        }
        return false;
    }

    // ── Tcp static + instance methods ────────────────────────────────────────

    fn genTcpCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "connect")) {
            try g.w.writeAll("_tcp_connect(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genTcpMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "write")) {
            try g.w.writeAll("_tcp_write(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "read")) {
            try g.w.writeAll("_tcp_read(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "readLine")) {
            try g.w.writeAll("_tcp_read_line(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "readBytes")) {
            try g.w.writeAll("_tcp_read_bytes(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("1024");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.w.writeAll("_tcp_close(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Udp static + instance methods ────────────────────────────────────────

    fn genUdpCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "socket")) {
            _ = args;
            try g.w.writeAll("_udp_socket()");
            return true;
        }
        return false;
    }

    // ── Net static methods ────────────────────────────────────────────────────

    fn genNetCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "resolve")) {
            try g.w.writeAll("_net_resolve(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeByte(')');
            return true;
        }
        return false;
    }

    // ── Regex static + instance methods ─────────────────────────────────────

    fn genRegexCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "compile")) {
            try g.w.writeAll("_regex_compile(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    fn genRegexMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "match")) {
            try g.w.writeAll("_regex_match(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "find")) {
            try g.w.writeAll("_regex_find(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "findAll")) {
            try g.w.writeAll("_regex_find_all(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "replace")) {
            try g.w.writeAll("_regex_replace(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "groups")) {
            try g.w.writeAll("_regex_groups(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── Gui static + widget methods ──────────────────────────────────────────

    /// Gui.run(title, width, height, callback) → _gui_run(...)
    fn genGuiCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "run")) {
            if (g.uses_gui_ptr) |p| p.* = true;
            try g.w.writeAll("_gui_run(");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"App\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("800");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("600");
            try g.w.writeAll(", ");
            if (args.len >= 4) try g.genExpr(args[3].value) else try g.w.writeAll("undefined");
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    /// g.text(s), g.button(label), etc. — pass through directly to GuiContext methods.
    /// Used for expression context (return values like button, checkbox, slider, input).
    /// For void-returning statement calls with allocating string args, use genGuiWidgetStmt.
    fn genGuiWidgetMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const known = std.StaticStringMap(void).initComptime(&.{
            .{ "text",      {} }, .{ "separator", {} }, .{ "sameLine",  {} },
            .{ "spacing",   {} }, .{ "indent",    {} }, .{ "unindent",  {} },
            .{ "button",    {} }, .{ "checkbox",  {} }, .{ "slider",         {} },
            .{ "input",     {} }, .{ "inputMultiline", {} },
            .{ "panel",     {} }, .{ "window",    {} },
        });
        if (known.get(method) == null) return false;
        try g.genExpr(obj);
        try g.w.print(".{s}(", .{method});
        for (args, 0..) |a, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.genExpr(a.value);
        }
        try g.w.writeAll(")");
        return true;
    }

    /// Statement-level GUI widget call handler. Wraps allocating string args in temp
    /// vars with defer-free to prevent GPA leaks. Returns true if emitted.
    fn genGuiWidgetStmt(g: Generator, e: *const Ast.Expr) anyerror!bool {
        if (e.* != .call) return false;
        const call = e.call;
        if (call.callee.* != .member) return false;
        const mem = call.callee.member;
        // Determine if receiver is a gui_context typed value.
        const obj_tc = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
        const is_gui = obj_tc == .gui_context or
            (g.getExprDeclaredType(mem.object) != null and blk: {
                const tr = g.getExprDeclaredType(mem.object).?;
                break :blk tr == .named and std.mem.eql(u8, tr.named.name, "Gui");
            });
        if (!is_gui) return false;
        const void_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "text", {} }, .{ "separator", {} }, .{ "sameLine", {} },
            .{ "spacing", {} }, .{ "indent", {} }, .{ "unindent", {} },
            .{ "panel", {} }, .{ "window", {} },
        });
        if (void_methods.get(mem.member) == null) return false;
        // Check if any arg is allocating.
        var any_alloc = false;
        for (call.args) |a| {
            if (a.value.* == .string_interp or isAllocatingStringInit(a.value, g.tc)) {
                any_alloc = true; break;
            }
        }
        if (!any_alloc) return false;
        // Emit a block with temp vars.
        try g.writeIndent();
        try g.w.writeAll("{\n");
        const bg = g.indented();
        var tmp_names = std.ArrayList(?[]const u8){};
        try tmp_names.ensureTotalCapacity(g.alloc, call.args.len);
        defer {
            for (tmp_names.items) |tn| if (tn) |n| g.alloc.free(n);
            tmp_names.deinit(g.alloc);
        }
        for (call.args, 0..) |a, i| {
            if (a.value.* == .string_interp or isAllocatingStringInit(a.value, g.tc)) {
                const tname = try std.fmt.allocPrint(g.alloc, "_gw{d}", .{i});
                try tmp_names.append(g.alloc, tname);
                try bg.writeIndent();
                try bg.w.print("const {s} = ", .{tname});
                try bg.genExpr(a.value);
                try bg.w.writeAll(";\n");
                try bg.writeIndent();
                try bg.w.print("defer _allocator.free({s});\n", .{tname});
            } else {
                try tmp_names.append(g.alloc, null);
            }
        }
        try bg.writeIndent();
        try bg.genExpr(mem.object);
        try bg.w.print(".{s}(", .{mem.member});
        for (call.args, 0..) |_, i| {
            if (i > 0) try bg.w.writeAll(", ");
            if (tmp_names.items[i]) |tn| {
                try bg.w.writeAll(tn);
            } else {
                try bg.genExpr(call.args[i].value);
            }
        }
        try bg.w.writeAll(");\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
        return true;
    }

    fn genUdpMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "send")) {
            try g.w.writeAll("_udp_send(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(", ");
            if (args.len >= 2) try g.genExpr(args[1].value) else try g.w.writeAll("0");
            try g.w.writeAll(", ");
            if (args.len >= 3) try g.genExpr(args[2].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "recv")) {
            try g.w.writeAll("_udp_recv(");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len >= 1) try g.genExpr(args[0].value) else try g.w.writeAll("4096");
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "close")) {
            try g.w.writeAll("_udp_close(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        return false;
    }

    // ── String-slice methods ([]const []const u8, e.g. Net.resolve result) ──────

    fn genStrSliceMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "count")) {
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(obj);
            try g.w.writeAll(".len))");
            return true;
        }
        if (std.mem.eql(u8, method, "at")) {
            try g.genExpr(obj);
            try g.w.writeAll("[@as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll("))]");
            return true;
        }
        return false;
    }

    /// Emit code for `Reflect.className(obj)`, `Reflect.fieldNames(obj)`,
    /// `Reflect.fieldTypes(obj)`.  Resolves the class name from the TC-inferred
    /// type of the argument and emits a reference to the corresponding
    /// `_reflect_<ClassName>_*` const generated alongside the class struct.
    fn genReflectCall(g: Generator, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (args.len != 1) return false;
        const arg = args[0].value;
        const arg_type = if (g.tc) |tc| tc.expr_types.get(arg) orelse .unknown else .unknown;
        const class_name: []const u8 = switch (arg_type) {
            .named => |sym| switch (sym.decl) {
                .class   => |c| c.name,
                .struct_ => |s| s.name,
                else     => return false,
            },
            else => return false,
        };
        if (std.mem.eql(u8, method, "className")) {
            try g.w.print("_reflect_{s}_name", .{class_name});
            return true;
        }
        if (std.mem.eql(u8, method, "fieldNames")) {
            try g.w.print("_reflect_{s}_fields[0..]", .{class_name});
            return true;
        }
        if (std.mem.eql(u8, method, "fieldTypes")) {
            try g.w.print("_reflect_{s}_field_types[0..]", .{class_name});
            return true;
        }
        return false;
    }

    // ── List methods ──────────────────────────────────────────────────────────

    fn genListMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "add")) {
            // list.add(x) → list.append(_allocator, x) catch unreachable  (Zig 0.15)
            try g.genExpr(obj);
            try g.w.writeAll(".append(_allocator, ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") catch unreachable");
            return true;
        }
        if (std.mem.eql(u8, method, "at")) {
            // list.at(i) → list.items[i]   (use 'at' since 'get' is a keyword)
            // Index is i64 in Zebra; Zig requires usize for slice indexing.
            try g.genExpr(obj);
            try g.w.writeAll(".items[@as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll("))]");
            return true;
        }
        if (std.mem.eql(u8, method, "remove")) {
            // list.remove(i) → _ = list.orderedRemove(@as(usize, @intCast(i)))
            // Index is i64 in Zebra; orderedRemove takes usize.
            try g.w.writeAll("_ = ");
            try g.genExpr(obj);
            try g.w.writeAll(".orderedRemove(@as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "clear")) {
            try g.genExpr(obj);
            try g.w.writeAll(".clearRetainingCapacity()");
            return true;
        }
        if (std.mem.eql(u8, method, "contains")) {
            // list.contains(x) → std.mem.indexOfScalar(T, list.items, x) != null
            try g.w.writeAll("(std.mem.indexOfScalar(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items[0]), ");
            try g.genExpr(obj);
            try g.w.writeAll(".items, ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") != null)");
            return true;
        }
        if (std.mem.eql(u8, method, "count")) {
            try g.writeListLen(obj);
            return true;
        }
        if (std.mem.eql(u8, method, "sort")) {
            // list.sort() — natural ascending sort (numeric: a < b, strings: lexicographic)
            try g.w.writeAll("_zebra_sort_natural(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items[0]), ");
            try g.genExpr(obj);
            try g.w.writeAll(".items)");
            return true;
        }
        if (std.mem.eql(u8, method, "sortBy")) {
            // list.sortBy(fn(a, b) => bool) — user-supplied comparator
            // The lambda generates as `struct { fn call(...) bool {...} }.call`,
            // a comptime-known function, passed as `comptime cmp` to _zebra_sort_by.
            if (args.len == 0) return false;
            try g.w.writeAll("_zebra_sort_by(@TypeOf(");
            try g.genExpr(obj);
            try g.w.writeAll(".items[0]), ");
            try g.genExpr(args[0].value);
            try g.w.writeAll(", ");
            try g.genExpr(obj);
            try g.w.writeAll(".items)");
            return true;
        }
        return false;
    }

    // ── HashMap methods ───────────────────────────────────────────────────────

    fn genHashMapMethod(g: Generator, obj: *const Ast.Expr, key_is_str: bool, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "put")) {
            // map.put(k, v) — note: 'set' is a keyword, use 'put'
            // For string-keyed maps, dupe the key so the map owns it (caller's string
            // may be freed by defer _allocator.free after this call).
            try g.genExpr(obj);
            try g.w.writeAll(".put(");
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                if (i == 0 and key_is_str) {
                    try g.w.writeAll("(_allocator.dupe(u8, ");
                    try g.genExpr(a.value);
                    try g.w.writeAll(") catch @panic(\"OOM\"))");
                } else {
                    try g.genExpr(a.value);
                }
            }
            try g.w.writeAll(") catch unreachable");
            return true;
        }
        if (std.mem.eql(u8, method, "fetch")) {
            // map.fetch(k) — note: 'get' is a keyword, use 'fetch'
            // Returns the value or undefined if missing.
            try g.w.writeAll("(");
            try g.genExpr(obj);
            try g.w.writeAll(".get(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") orelse undefined)");
            return true;
        }
        if (std.mem.eql(u8, method, "contains")) {
            // map.contains(k) — note: 'has' is a keyword, use 'contains'
            try g.genExpr(obj);
            try g.w.writeAll(".contains(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "remove")) {
            try g.w.writeAll("_ = ");
            try g.genExpr(obj);
            try g.w.writeAll(".remove(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "count")) {
            // HashMap.count() returns usize; cast to i64 to match Zebra's int type.
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(obj);
            try g.w.writeAll(".count()))");
            return true;
        }
        return false;
    }

    // ── Result(T, E) methods ──────────────────────────────────────────────────

    fn genResultMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        const known = std.StaticStringMap(void).initComptime(&.{
            .{ "isOk", {} }, .{ "isErr", {} }, .{ "unwrap", {} },
            .{ "unwrapOr", {} }, .{ "okValue", {} }, .{ "errValue", {} },
            .{ "map", {} }, .{ "flatMap", {} },
        });
        if (!known.has(method)) return false;
        try g.genExpr(obj);
        try g.w.writeByte('.');
        try g.w.writeAll(method);
        try g.w.writeByte('(');
        for (args, 0..) |a, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.genExpr(a.value);
        }
        try g.w.writeByte(')');
        return true;
    }

    // ── String methods ────────────────────────────────────────────────────────

    fn genStringMethod(g: Generator, obj: *const Ast.Expr, method: []const u8, args: []const Ast.Arg) anyerror!bool {
        if (std.mem.eql(u8, method, "contains")) {
            try g.w.writeAll("(std.mem.indexOf(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(") != null)");
            return true;
        }
        if (std.mem.eql(u8, method, "startsWith")) {
            try g.w.writeAll("std.mem.startsWith(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "endsWith")) {
            try g.w.writeAll("std.mem.endsWith(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "trim")) {
            try g.w.writeAll("std.mem.trim(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "trimLeft")) {
            try g.w.writeAll("std.mem.trimLeft(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "trimRight")) {
            try g.w.writeAll("std.mem.trimRight(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", &std.ascii.whitespace)");
            return true;
        }
        if (std.mem.eql(u8, method, "isEmpty")) {
            try g.w.writeAll("(");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0)");
            return true;
        }
        if (std.mem.eql(u8, method, "count")) {
            // str.count(substr) → count non-overlapping occurrences; cast to i64.
            try g.w.writeAll("@as(i64, @intCast(std.mem.count(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "join")) {
            // sep.join(list) → std.mem.join(_allocator, sep, list.items)
            try g.w.writeAll("(std.mem.join(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("&.{}");
            try g.w.writeAll(".items) catch @panic(\"OOM\"))");
            return true;
        }
        if (std.mem.eql(u8, method, "lines")) {
            // s.lines() → splitScalar iterator on '\n'; used in for-in via genForInLines
            try g.w.writeAll("std.mem.splitScalar(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", '\\n')");
            return true;
        }
        if (std.mem.eql(u8, method, "reverse")) {
            // str.reverse() → allocate copy and reverse it
            try g.w.writeAll("(blk: { const _rbuf = _allocator.alloc(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(".len) catch @panic(\"OOM\"); @memcpy(_rbuf, ");
            try g.genExpr(obj);
            try g.w.writeAll("); std.mem.reverse(u8, _rbuf); break :blk _rbuf; })");
            return true;
        }
        if (std.mem.eql(u8, method, "toHex")) {
            // str.toHex() → lower-case hex encoding; one byte → two hex digits
            try g.w.writeAll("(blk: { const _hx_s = ");
            try g.genExpr(obj);
            try g.w.writeAll("; const _hx_buf = _allocator.alloc(u8, _hx_s.len * 2) catch @panic(\"OOM\"); ");
            try g.w.writeAll("for (_hx_s, 0..) |_hx_b, _hx_i| { _ = std.fmt.bufPrint(_hx_buf[_hx_i * 2 .. _hx_i * 2 + 2], \"{x:0>2}\", .{_hx_b}) catch unreachable; } ");
            try g.w.writeAll("break :blk _hx_buf; })");
            return true;
        }
        if (std.mem.eql(u8, method, "fromHex")) {
            // str.fromHex() → decode hex string to bytes; returns ?str (null on bad input)
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len % 2 != 0) break :blk @as(?[]const u8, null); ");
            try g.w.writeAll("const _hbuf = _allocator.alloc(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(".len / 2) catch @panic(\"OOM\"); ");
            try g.w.writeAll("std.fmt.hexToBytes(_hbuf, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch { _allocator.free(_hbuf); break :blk @as(?[]const u8, null); }; ");
            try g.w.writeAll("break :blk @as(?[]const u8, _hbuf); })");
            return true;
        }
        if (std.mem.eql(u8, method, "isAlpha")) {
            // str.isAlpha() → all bytes are ASCII alphabetic (ASCII-aware)
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0) break :blk false; for (");
            try g.genExpr(obj);
            try g.w.writeAll(") |_ac| { if (!std.ascii.isAlphabetic(_ac)) break :blk false; } break :blk true; })");
            return true;
        }
        if (std.mem.eql(u8, method, "isNumeric")) {
            // str.isNumeric() → all bytes are ASCII digits (ASCII-aware)
            try g.w.writeAll("(blk: { if (");
            try g.genExpr(obj);
            try g.w.writeAll(".len == 0) break :blk false; for (");
            try g.genExpr(obj);
            try g.w.writeAll(") |_nc| { if (!std.ascii.isDigit(_nc)) break :blk false; } break :blk true; })");
            return true;
        }
        // ── UTF-8 / Unicode methods ───────────────────────────────────────────
        if (std.mem.eql(u8, method, "isValidUtf8")) {
            try g.w.writeAll("std.unicode.utf8ValidateSlice(");
            try g.genExpr(obj);
            try g.w.writeAll(")");
            return true;
        }
        if (std.mem.eql(u8, method, "codePointCount")) {
            // Returns the number of Unicode codepoints (not bytes).
            // Cast to i64 to match Zebra's int type.
            try g.w.writeAll("@as(i64, @intCast(std.unicode.utf8CountCodepoints(");
            try g.genExpr(obj);
            try g.w.writeAll(") catch 0))");
            return true;
        }
        if (std.mem.eql(u8, method, "chars")) {
            // chars() as a standalone expression returns the string unchanged.
            // Actual codepoint iteration is handled in genForIn → genForInChars.
            try g.genExpr(obj);
            return true;
        }
        if (std.mem.eql(u8, method, "concat")) {
            try g.w.writeAll("(std.mem.concat(_allocator, u8, &.{ ");
            try g.genExpr(obj);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(" }) catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "toInt")) {
            try g.w.writeAll("(std.fmt.parseInt(i64, ");
            try g.genExpr(obj);
            try g.w.writeAll(", 10) catch 0)");
            return true;
        }
        if (std.mem.eql(u8, method, "toFloat")) {
            try g.w.writeAll("(std.fmt.parseFloat(f64, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch 0.0)");
            return true;
        }
        if (std.mem.eql(u8, method, "format")) {
            // str.format(val) — delegates to std.fmt.allocPrint
            try g.w.writeAll("(std.fmt.allocPrint(_allocator, ");
            try g.genExpr(obj);
            for (args) |a| {
                try g.w.writeAll(", .{ ");
                try g.genExpr(a.value);
                try g.w.writeAll(" }");
            }
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "upper")) {
            // str.upper() → std.ascii.allocUpperString(_allocator, str) catch unreachable
            try g.w.writeAll("(std.ascii.allocUpperString(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "lower")) {
            // str.lower() → std.ascii.allocLowerString(_allocator, str) catch unreachable
            try g.w.writeAll("(std.ascii.allocLowerString(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "indexOf")) {
            // str.indexOf(sub) → index as i64, or -1 if not found
            try g.w.writeAll("(if (std.mem.indexOf(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(")) |_i| @as(i64, @intCast(_i)) else @as(i64, -1))");
            return true;
        }
        if (std.mem.eql(u8, method, "replace")) {
            // str.replace(old, new) → std.mem.replaceOwned(u8, _allocator, str, old, new)
            try g.w.writeAll("(std.mem.replaceOwned(u8, _allocator, ");
            try g.genExpr(obj);
            for (args) |a| {
                try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(") catch unreachable)");
            return true;
        }
        if (std.mem.eql(u8, method, "repeat")) {
            // str.repeat(n) → allocate n concatenated copies
            try g.w.writeAll("(blk: { var _rep = std.ArrayList([]const u8){}; ");
            try g.w.writeAll("defer _rep.deinit(_allocator); ");
            try g.w.writeAll("var _ri: i64 = 0; while (_ri < ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(") : (_ri += 1) _rep.append(_allocator, ");
            try g.genExpr(obj);
            try g.w.writeAll(") catch unreachable; ");
            try g.w.writeAll("break :blk std.mem.concat(_allocator, u8, _rep.items) catch unreachable; })");
            return true;
        }
        if (std.mem.eql(u8, method, "split")) {
            // str.split(delim) → returns a splitSequence iterator; use in for loops
            try g.w.writeAll("std.mem.splitSequence(u8, ");
            try g.genExpr(obj);
            try g.w.writeAll(", ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\" \"");
            try g.w.writeAll(")");
            return true;
        }
        // ── Padding / alignment methods ──────────────────────────────────────
        if (std.mem.eql(u8, method, "padLeft")) {
            // str.padLeft(n [, fill]) → right-align in width n
            try g.w.writeAll("_pad_left(");
            try g.genExpr(obj);
            try g.w.writeAll(", @as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), ");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("' '");
            try g.w.writeAll(", _allocator)");
            return true;
        }
        if (std.mem.eql(u8, method, "padRight")) {
            // str.padRight(n [, fill]) → left-align in width n
            try g.w.writeAll("_pad_right(");
            try g.genExpr(obj);
            try g.w.writeAll(", @as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), ");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("' '");
            try g.w.writeAll(", _allocator)");
            return true;
        }
        if (std.mem.eql(u8, method, "center")) {
            // str.center(n [, fill]) → center in width n
            try g.w.writeAll("_pad_center(");
            try g.genExpr(obj);
            try g.w.writeAll(", @as(usize, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll(")), ");
            if (args.len > 1) try g.genExpr(args[1].value) else try g.w.writeAll("' '");
            try g.w.writeAll(", _allocator)");
            return true;
        }
        // ── bytes() — iterate raw bytes of a string ───────────────────────────
        // Used in `for b in s.bytes()` → `for (s) |b|` in Zig (b is u8).
        // Note: chars() is reserved for future Unicode codepoint iteration.
        if (std.mem.eql(u8, method, "bytes")) {
            try g.genExpr(obj);
            return true;
        }
        return false;
    }

    /// Emit a struct-instance literal for a lambda that has a `capture` block.
    /// The result is a value of an anonymous struct type; call sites use `.call()`.
    fn genCaptureClosureStruct(g: Generator, e: *Ast.ExprLambda) anyerror!void {
        // Collect capture field names so body idents use `self.name`
        var field_names = std.ArrayList([]const u8){};
        defer field_names.deinit(g.alloc);
        for (e.capture) |cv| try field_names.append(g.alloc, cv.name);

        // Determine if any capture field is mutated in the body.
        // If so, `call` must take `self: *@This()` so assignments are visible to the caller.
        const body_stmts: []const Ast.Stmt = switch (e.body) {
            .stmts => |ss| ss,
            .expr  => &.{},
        };
        var body_mutations = try scanMutations(body_stmts, g.alloc, g.tc);
        defer body_mutations.deinit();
        var any_capture_mutated = false;
        for (e.capture) |cv| {
            if (body_mutations.contains(cv.name)) { any_capture_mutated = true; break; }
        }

        try g.w.writeAll("struct {\n");
        const fg = g.indented();

        // Emit capture fields
        for (e.capture) |cv| {
            try fg.writeIndent();
            try fg.w.writeAll(cv.name);
            try fg.w.writeAll(": ");
            if (cv.type_) |tr| {
                try fg.genType(tr);
            } else if (cv.init) |init| {
                // No explicit type — use @TypeOf(init_expr) so Zig can infer
                // the field type from the initialiser at the struct definition site.
                try fg.w.writeAll("@TypeOf(");
                try fg.genExpr(init);
                try fg.w.writeAll(")");
            } else {
                try fg.w.writeAll("anytype");
            }
            try fg.w.writeAll(",\n");
        }

        // Emit call method — mutable self if any capture field is assigned.
        try fg.writeIndent();
        if (any_capture_mutated) {
            try fg.w.writeAll("fn call(self: *@This()");
        } else {
            try fg.w.writeAll("fn call(self: @This()");
        }
        for (e.params) |p| {
            try fg.w.writeAll(", ");
            try fg.w.writeAll(p.name);
            try fg.w.writeAll(": ");
            if (p.type_) |tr| try fg.genType(tr) else try fg.w.writeAll("anytype");
        }
        try fg.w.writeAll(") ");
        if (e.return_type) |rt| {
            try fg.genType(rt);
        } else {
            switch (e.body) {
                .expr => |ex| {
                    try fg.w.writeAll("@TypeOf(");
                    try fg.genExpr(ex);
                    try fg.w.writeAll(")");
                },
                .stmts => try fg.w.writeAll("void"),
            }
        }
        try fg.w.writeAll(" {\n");

        // Body: idents matching capture names resolve to self.name
        // Escape analysis so deferred frees are skipped for vars whose ownership transfers out.
        var ret_set_capture = try analyzeEscapes(
            if (e.body == .stmts) e.body.stmts else &.{}, g.alloc);
        defer ret_set_capture.deinit();
        const base_bg = fg.indented().withCaptureFields(field_names.items);
        const bg = if (e.body == .stmts) base_bg.withReturnedNames(&ret_set_capture) else base_bg;
        switch (e.body) {
            .expr => |ex| {
                try bg.writeIndent();
                try bg.w.writeAll("return ");
                try bg.genExpr(ex);
                try bg.w.writeAll(";\n");
            },
            .stmts => |ss| {
                try bg.genStmts(ss);
            },
        }
        try fg.writeIndent();
        try fg.w.writeAll("}\n");
        try g.writeIndent();
        try g.w.writeAll("}{ ");
        for (e.capture) |cv| {
            try g.w.writeAll(".");
            try g.w.writeAll(cv.name);
            try g.w.writeAll(" = ");
            if (cv.init) |init| try g.genExpr(init) else try g.w.writeAll("undefined");
            try g.w.writeAll(", ");
        }
        try g.w.writeAll("}");
    }

    fn genAssign(g: Generator, s: *Ast.StmtAssign) anyerror!void {
        try g.writeIndent();
        switch (s.op) {
            .slashslash_eq => {
                // x //= y  →  x = @divTrunc(x, y)
                try g.genExpr(s.target);
                try g.w.writeAll(" = @divTrunc(");
                try g.genExpr(s.target);
                try g.w.writeAll(", ");
                try g.genExpr(s.value);
                try g.w.writeAll(")");
            },
            .starstar_eq => {
                // x **= y  →  x = std.math.pow(f64, x, y)
                try g.genExpr(s.target);
                try g.w.writeAll(" = std.math.pow(f64, ");
                try g.genExpr(s.target);
                try g.w.writeAll(", ");
                try g.genExpr(s.value);
                try g.w.writeAll(")");
            },
            .question_eq => {
                // x ?= y  →  x = x orelse y
                try g.genExpr(s.target);
                try g.w.writeAll(" = ");
                try g.genExpr(s.target);
                try g.w.writeAll(" orelse ");
                try g.genExpr(s.value);
            },
            else => {
                // Self-referential recursive field assignment:
                // If target is a member access whose type is `?*T` and the value
                // is of type `T` (bare struct), wrap the value in an arena alloc
                // so Zig gets the pointer it requires.
                const needs_box = blk: {
                    if (s.op != .assign) break :blk false;
                    if (s.target.* != .member) break :blk false;
                    const tc = g.tc orelse break :blk false;
                    const lhs_t = tc.expr_types.get(s.target) orelse break :blk false;
                    const rhs_t = tc.expr_types.get(s.value) orelse break :blk false;
                    if (lhs_t != .optional) break :blk false;
                    if (lhs_t.optional.* != .named) break :blk false;
                    if (rhs_t != .named) break :blk false;
                    break :blk lhs_t.optional.named == rhs_t.named;
                };
                // `^T` heap-indirection field assignment:
                // If the field's declared type is `^T` or `^T?`, and the RHS is a
                // plain `T` value (not nil), we must heap-allocate so Zig gets a `*T`.
                const ref_box_type_name: ?[]const u8 = blk: {
                    if (s.op != .assign) break :blk null;
                    // Skip if RHS is nil — no allocation needed for null assignment.
                    if (s.value.* == .nil) break :blk null;
                    // Resolve the TypeRef for the target field.  We handle two cases:
                    //
                    //   1. `field = x` or `self.field = x` — look up in owner_class.
                    //   2. `a.b.field = x` (nested member) — look up `field` in the
                    //      declared type of the intermediate object `a.b`.
                    const field_tr_opt: ?Ast.TypeRef = blk2: {
                        switch (s.target.*) {
                            .ident => |id| {
                                break :blk2 g.resolveFieldTypeRef(id.name);
                            },
                            .member => |mem| {
                                if (mem.object.* == .ident) {
                                    // `self.field = x` or `localVar.field = x`:
                                    // First try the owner class (covers `self.field`).
                                    if (g.resolveFieldTypeRef(mem.member)) |tr| break :blk2 tr;
                                    // Fall back: look up via TC type of the object
                                    // (covers `localVar.field` where localVar is
                                    // a different class).
                                    if (g.tc) |tc| {
                                        const obj_t = tc.expr_types.get(mem.object) orelse break :blk2 null;
                                        const sym = switch (obj_t) {
                                            .named => |s2| s2,
                                            else  => break :blk2 null,
                                        };
                                        if (sym.own_scope) |scope| {
                                            if (scope.lookupLocal(mem.member)) |field_sym| {
                                                if (field_sym.decl == .var_) {
                                                    if (field_sym.decl.var_.type_) |*tr|
                                                        break :blk2 tr.*;
                                                }
                                            }
                                        }
                                    }
                                    break :blk2 null;
                                }
                                // Nested `a.b.field = x` — look up `field` in a.b's TC type.
                                if (g.tc) |tc| {
                                    const parent_t = tc.expr_types.get(mem.object) orelse break :blk2 null;
                                    const sym = switch (parent_t) {
                                        .named => |s2| s2,
                                        else  => break :blk2 null,
                                    };
                                    if (sym.own_scope) |scope| {
                                        if (scope.lookupLocal(mem.member)) |field_sym| {
                                            if (field_sym.decl == .var_) {
                                                if (field_sym.decl.var_.type_) |*tr|
                                                    break :blk2 tr.*;
                                            }
                                        }
                                    }
                                }
                                break :blk2 null;
                            },
                            else => break :blk2 null,
                        }
                    };
                    const field_tr = field_tr_opt orelse break :blk null;
                    if (field_tr != .ref_to) break :blk null;
                    // The inner TypeRef must resolve to a named type for codegen.
                    // Handle both `^T` and `^T?` (nilable optional pointer).
                    const inner = field_tr.ref_to;
                    break :blk switch (inner.*) {
                        .named   => |n| n.name,
                        .nilable => |ni| switch (ni.*) {
                            .named => |n| n.name,
                            else   => null,
                        },
                        else     => null,
                    };
                };
                if (needs_box) {
                    // Emit: { const _rp = _allocator.create(T) catch @panic("OOM"); _rp.* = value; target = _rp; }
                    // Block statement — no trailing semicolon (it is added by the else branch below).
                    const rhs_t = g.tc.?.expr_types.get(s.value).?;
                    const class_name = switch (rhs_t.named.decl) {
                        .class   => |c|  c.name,
                        .struct_ => |ss| ss.name,
                        else     => "",
                    };
                    try g.w.writeAll("{ const _rp = _allocator.create(");
                    try g.w.writeAll(class_name);
                    try g.w.writeAll(") catch @panic(\"OOM\"); _rp.* = ");
                    try g.genExpr(s.value);
                    try g.w.writeAll("; ");
                    try g.genExpr(s.target);
                    try g.w.writeAll(" = _rp; }\n");
                    return; // skip trailing ;\n — block statement has no semicolon in Zig
                } else if (ref_box_type_name) |type_name| {
                    // Emit: { const _rp = _allocator.create(T) catch @panic("OOM"); _rp.* = value; target = _rp; }
                    try g.w.writeAll("{ const _rp = _allocator.create(");
                    try g.w.writeAll(type_name);
                    try g.w.writeAll(") catch @panic(\"OOM\"); _rp.* = ");
                    try g.genExpr(s.value);
                    try g.w.writeAll("; ");
                    try g.genExpr(s.target);
                    try g.w.writeAll(" = _rp; }\n");
                    return;
                } else {
                    try g.genExpr(s.target);
                    try g.w.writeAll(" ");
                    try g.w.writeAll(assignOpStr(s.op));
                    try g.w.writeAll(" ");
                    // fn-ref reassignment: `pred = isDigit` → `pred = &isDigit`
                    // Mutable fn-ref vars have type `*const fn(P) R`; bare function
                    // names are function values, so we need `&` to take a pointer.
                    const fn_ref_emitted: bool = fn_emit: {
                        if (s.op != .assign) break :fn_emit false;
                        if (s.value.* != .ident) break :fn_emit false;
                        const tc = g.tc orelse break :fn_emit false;
                        const rhs_t = tc.expr_types.get(s.value) orelse break :fn_emit false;
                        if (rhs_t != .fn_ref) break :fn_emit false;
                        try g.w.writeAll("&");
                        try g.genExpr(s.value);
                        break :fn_emit true;
                    };
                    if (fn_ref_emitted) {
                        try g.w.writeAll(";\n");
                        return;
                    }
                    // In class bodies (generic or concrete), resolve the declared generic
                    // field type from the LHS so any zero-arg constructor `T()` emits
                    // `std.ArrayList(T){}` / `T(Arg).init()` correctly.
                    // Works for List, HashMap, and user-defined generics alike.
                    const generic_emitted: bool = emit: {
                        if (s.op != .assign) break :emit false;
                        if (s.value.* != .call) break :emit false;
                        const rhs_call = s.value.call;
                        if (rhs_call.callee.* != .ident) break :emit false;
                        if (rhs_call.args.len != 0) break :emit false;
                        // Resolve field name from target: bare ident (in method body) or
                        // explicit `self.field` member access (rare in Zebra, but supported).
                        const field_name: []const u8 = switch (s.target.*) {
                            .ident  => |id| id.name,
                            .member => |mem| blk: {
                                if (mem.object.* != .ident) break :emit false;
                                if (!std.mem.eql(u8, mem.object.ident.name, "self")) break :emit false;
                                break :blk mem.member;
                            },
                            else => break :emit false,
                        };
                        const gtr = g.resolveFieldGenericTypeRef(field_name) orelse break :emit false;
                        // RHS callee must name the same generic type as the field declaration.
                        if (!std.mem.eql(u8, rhs_call.callee.ident.name, gtr.name)) break :emit false;
                        try g.genStdlibInit(gtr);
                        break :emit true;
                    };
                    if (!generic_emitted) try g.genExpr(s.value);
                }
            },
        }
        try g.w.writeAll(";\n");
    }

    fn genReturn(g: Generator, s: *Ast.StmtReturn) anyerror!void {
        // TCO path: `return self.method(args)` inside a TCO-transformed method.
        // Instead of a real return, assign new arg values to the mutable param
        // copies and `continue` the enclosing `while (true)` loop.
        if (g.tco_method_name.len > 0) {
            if (s.value) |v| {
                if (isTcoExpr(v, g.tco_method_name, g.owner, g.tco_shared)) {
                    const args = v.call.args;
                    const n_update = @min(args.len, g.tco_params.len);
                    // Evaluate new args into temps first (avoids aliasing when a
                    // param appears on both sides, e.g. `return self.f(b, a)`).
                    try g.writeIndent();
                    try g.w.writeAll("{");
                    for (args[0..n_update], 0..) |arg, i| {
                        try g.w.print(" const _tco{d} = ", .{i});
                        try g.genExpr(arg.value);
                        try g.w.writeAll(";");
                    }
                    for (0..n_update) |i| {
                        try g.w.print(" {s} = _tco{d};", .{ g.tco_params[i], i });
                    }
                    try g.w.writeAll(" }\n");
                    try g.writeIndent();
                    try g.w.writeAll("continue;\n");
                    return;
                }
            }
        }
        try g.writeIndent();
        if (s.value) |v| {
            // If the return value is an allocating call whose receiver is also
            // an allocating expression, hoist the receiver into a scoped temp
            // so it can be defer-freed after the outer call completes.
            if (v.* == .call and v.call.callee.* == .member) {
                const mem_call = v.call.callee.member;
                if (isAllocatingStringInit(mem_call.object, g.tc)) {
                    try g.w.writeAll("{\n");
                    const ig = g.indented();
                    try ig.writeIndent();
                    try ig.w.writeAll("const _ret_recv = ");
                    try ig.genExpr(mem_call.object);
                    try ig.w.writeAll(";\n");
                    try ig.writeIndent();
                    try ig.w.writeAll("defer _allocator.free(_ret_recv);\n");
                    try ig.writeIndent();
                    try ig.w.writeAll("return ");
                    var sg = ig;
                    sg.expr_subst = .{ .orig = mem_call.object, .name = "_ret_recv" };
                    try sg.genExpr(v);
                    try ig.w.writeAll(";\n");
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                    return;
                }
            }
            try g.w.writeAll("return ");
            try g.genExpr(v);
            try g.w.writeAll(";\n");
        } else {
            try g.w.writeAll("return;\n");
        }
    }

    fn genIf(g: Generator, s: *Ast.StmtIf) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("if (");
        try g.genExpr(s.cond);
        try g.w.writeAll(") {\n");
        // Nil narrowing: if cond is `x != nil`, unwrap x with .? inside then_body.
        const narrow_then = nilNarrowVar(s.cond, true);
        const narrow_else = nilNarrowVar(s.cond, false);
        var nn_set = std.StringHashMap(void).init(g.alloc);
        defer nn_set.deinit();
        if (narrow_then) |name| try nn_set.put(name, {});
        const then_g = if (narrow_then != null) g.indented().withNilNarrowed(&nn_set) else g.indented();
        try then_g.genStmts(s.then_body);
        try g.writeIndent();
        try g.w.writeAll("}");
        for (s.else_ifs) |ei| {
            try g.w.writeAll(" else if (");
            try g.genExpr(ei.cond);
            try g.w.writeAll(") {\n");
            try g.indented().genStmts(ei.body);
            try g.writeIndent();
            try g.w.writeAll("}");
        }
        if (s.else_body) |eb| {
            try g.w.writeAll(" else {\n");
            var nn_else_set = std.StringHashMap(void).init(g.alloc);
            defer nn_else_set.deinit();
            if (narrow_else) |name| try nn_else_set.put(name, {});
            const else_g = if (narrow_else != null) g.indented().withNilNarrowed(&nn_else_set) else g.indented();
            try else_g.genStmts(eb);
            try g.writeIndent();
            try g.w.writeAll("}");
        }
        try g.w.writeAll("\n");
    }

    fn genWhile(g: Generator, s: *Ast.StmtWhile) anyerror!void {
        try g.writeIndent();
        if (s.bind) |bind| {
            // `while var c = expr, guard` → while (true) { const c = expr; if (!guard) break; body }
            try g.w.writeAll("while (true) {\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = ", .{bind.name});
            try bg.genExpr(bind.init);
            try bg.w.writeAll(";\n");
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(s.cond);
            try bg.w.writeAll(")) break;\n");
            try bg.genStmts(s.body);
            try g.writeIndent();
            try g.w.writeAll("}\n");
            return;
        }
        try g.w.writeAll("while (");
        try g.genExpr(s.cond);
        try g.w.writeAll(") {\n");
        const bg = g.indented();
        try bg.genStmts(s.body);
        if (s.post_body) |pb| {
            // Zig has no built-in post-body; emit as a trailing comment block.
            try bg.line("// post:");
            try bg.genStmts(pb);
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    // ── Char methods (ASCII-aware; full Unicode case/category deferred) ───────

    fn genCharMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        _ = args;
        // All char predicates cast to u8 for std.ascii — valid for ASCII range (0..127).
        // Non-ASCII codepoints will return false for isAlpha/isDigit/isWhitespace.
        if (std.mem.eql(u8, method, "isAlpha")) {
            try g.w.writeAll("std.ascii.isAlphabetic(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isDigit")) {
            try g.w.writeAll("std.ascii.isDigit(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isWhitespace")) {
            try g.w.writeAll("std.ascii.isWhitespace(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isUpper")) {
            try g.w.writeAll("std.ascii.isUpper(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "isLower")) {
            try g.w.writeAll("std.ascii.isLower(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll(")))");
            return true;
        }
        if (std.mem.eql(u8, method, "toUpper")) {
            try g.w.writeAll("@as(u21, std.ascii.toUpper(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll("))))");
            return true;
        }
        if (std.mem.eql(u8, method, "toLower")) {
            try g.w.writeAll("@as(u21, std.ascii.toLower(@as(u8, @truncate(");
            try g.genExpr(object);
            try g.w.writeAll("))))");
            return true;
        }
        if (std.mem.eql(u8, method, "toString")) {
            // Encode unicode codepoint (u21) to its UTF-8 byte sequence.
            // Stack-encode into a 4-byte buffer, then dupe to allocator memory.
            try g.w.writeAll("(blk: { var _cpbuf: [4]u8 = undefined; const _cplen = std.unicode.utf8Encode(");
            try g.genExpr(object);
            try g.w.writeAll(", &_cpbuf) catch 1; const _cpout = _allocator.dupe(u8, _cpbuf[0.._cplen]) catch @panic(\"OOM\"); break :blk @as([]const u8, _cpout); })");
            return true;
        }
        return false;
    }

    // ── StringBuilder methods ─────────────────────────────────────────────────

    fn genStringBuilderMethod(
        g:      Generator,
        object: *const Ast.Expr,
        method: []const u8,
        args:   []const Ast.Arg,
    ) anyerror!bool {
        if (std.mem.eql(u8, method, "append")) {
            // sb.append(s) → sb.appendSlice(_allocator, s) catch @panic("OOM")
            try g.genExpr(object);
            try g.w.writeAll(".appendSlice(_allocator, ");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("\"\"");
            try g.w.writeAll(") catch @panic(\"OOM\")");
            return true;
        }
        if (std.mem.eql(u8, method, "appendChar")) {
            // sb.appendChar(c) → sb.append(_allocator, @as(u8, @intCast(c))) catch @panic("OOM")
            try g.genExpr(object);
            try g.w.writeAll(".append(_allocator, @as(u8, @intCast(");
            if (args.len > 0) try g.genExpr(args[0].value) else try g.w.writeAll("0");
            try g.w.writeAll("))) catch @panic(\"OOM\")");
            return true;
        }
        if (std.mem.eql(u8, method, "build")) {
            // sb.build() → sb.items  (non-allocating slice into the buffer)
            try g.genExpr(object);
            try g.w.writeAll(".items");
            return true;
        }
        if (std.mem.eql(u8, method, "clear")) {
            // sb.clear() → sb.clearRetainingCapacity()
            try g.genExpr(object);
            try g.w.writeAll(".clearRetainingCapacity()");
            return true;
        }
        if (std.mem.eql(u8, method, "len")) {
            // sb.len() → sb.items.len
            try g.genExpr(object);
            try g.w.writeAll(".items.len");
            return true;
        }
        return false;
    }

    fn genForIn(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        // for c in str.chars() — Unicode codepoint iteration via Utf8Iterator
        if (g.isCharsCallOnString(s.iter)) return g.genForInChars(s);

        // for x in str.split(delim) — emit while loop over splitSequence iterator
        if (g.isSplitCallOnString(s.iter)) return g.genForInSplit(s);

        // Detect stdlib container types for special iteration patterns.
        if (g.getExprDeclaredType(s.iter)) |tr| {
            if (tr == .generic) {
                if (std.mem.eql(u8, tr.generic.name, "HashMap"))
                    return g.genForInHashMap(s);
                if (std.mem.eql(u8, tr.generic.name, "List"))
                    return g.genForInList(s);
            }
        }
        // Also check list_loop_vars — vars introduced as values in HashMap(K, List(T)) loops.
        if (s.iter.* == .ident) {
            if (g.list_loop_vars) |llv| {
                if (llv.contains(s.iter.ident.name))
                    return g.genForInList(s);
            }
        }
        // for col in hdr where hdr has TC-type csv_row (result of csv.header()/csv.row())
        if (s.iter.* == .ident) {
            const obj_tc = if (g.tc) |tc| tc.expr_types.get(s.iter) orelse .unknown else .unknown;
            if (obj_tc == .csv_row) return g.genForInList(s);
        }
        // for row in csv.rows() / csv.dataRows() / csv.header() / csv.row(n)
        // Capture the returned ArrayList before iterating — avoids use-after-free on temporaries.
        if (s.iter.* == .call) {
            if (s.iter.call.callee.* == .member) {
                const m = s.iter.call.callee.member;
                const obj_tc = if (g.tc) |tc| tc.expr_types.get(m.object) orelse .unknown else .unknown;
                if (obj_tc == .csv_table and (
                    std.mem.eql(u8, m.member, "rows")     or
                    std.mem.eql(u8, m.member, "dataRows") or
                    std.mem.eql(u8, m.member, "header")   or
                    std.mem.eql(u8, m.member, "row")))
                {
                    return g.genForInCsvRows(s);
                }
            }
        }

        // Fallback for struct field accesses (e.g. `m.decls` where `m` is a
        // branch-binding payload from a cross-module union).  The TC cannot
        // infer the type through catch_binding symbols, but in Zebra struct
        // fields that are iterable are always `List(T)` → `std.ArrayListUnmanaged`
        // and therefore need `.items`.  Call-expressions and ident-only cases
        // are already handled above; a bare member access here is always a List.
        if (s.iter.* == .member) return g.genForInList(s);

        // Default: standard Zig for-loop over a slice / range.
        try g.writeIndent();
        try g.w.writeAll("for (");
        try g.genExpr(s.iter);
        try g.w.writeAll(") |");
        for (s.vars, 0..) |v, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(v);
        }
        try g.w.writeAll("| {\n");
        const bg = g.indented();
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for x in list` — auto-deref to `.items` so bare List vars work without `.items`.
    fn genForInList(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("for (");
        try g.genExpr(s.iter);
        try g.w.writeAll(".items) |");
        for (s.vars, 0..) |v, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.writeAll(v);
        }
        try g.w.writeAll("| {\n");
        const bg = g.indented();
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for k, v in map` or `for k in map` — Zig HashMap iterator pattern.
    fn genForInHashMap(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const first_var = if (s.vars.len > 0) s.vars[0] else "_k";
        const iter_var   = try std.fmt.allocPrint(g.alloc, "_it_{s}",  .{first_var});
        defer g.alloc.free(iter_var);

        try g.writeIndent();
        if (s.vars.len >= 2) {
            // Two-variable form: unpack key and value from iterator entry.
            const entry_var = try std.fmt.allocPrint(g.alloc, "_e_{s}", .{first_var});
            defer g.alloc.free(entry_var);

            // If the HashMap's value type is List(T), mark the value variable
            // so that nested `for elem in v` loops dispatch to genForInList.
            var val_list_vars = std.StringHashMap(void).init(g.alloc);
            defer val_list_vars.deinit();
            var body_gen = g;
            if (g.getExprDeclaredType(s.iter)) |tr| {
                if (tr == .generic and
                    std.mem.eql(u8, tr.generic.name, "HashMap") and
                    tr.generic.args.len >= 2)
                {
                    const val_tr = tr.generic.args[1];
                    if (val_tr == .generic and
                        std.mem.eql(u8, val_tr.generic.name, "List"))
                    {
                        try val_list_vars.put(s.vars[1], {});
                        body_gen.list_loop_vars = &val_list_vars;
                    }
                }
            }

            try g.w.print("var {s} = ", .{iter_var});
            try g.genExpr(s.iter);
            try g.w.writeAll(".iterator();\n");
            try g.writeIndent();
            try g.w.print("while ({s}.next()) |{s}| {{\n", .{iter_var, entry_var});
            const bg = body_gen.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.key_ptr.*;\n",   .{s.vars[0], entry_var});
            if (!nameUsedInStmts(s.vars[0], s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{s.vars[0]});
            }
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.value_ptr.*;\n", .{s.vars[1], entry_var});
            if (!nameUsedInStmts(s.vars[1], s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{s.vars[1]});
            }
            if (s.where) |w| {
                try bg.writeIndent();
                try bg.w.writeAll("if (!(");
                try bg.genExpr(w);
                try bg.w.writeAll(")) continue;\n");
            }
            try bg.genStmts(s.body);
        } else {
            // Single-variable form: iterate keys only.
            const kptr_var = try std.fmt.allocPrint(g.alloc, "_kp_{s}", .{first_var});
            defer g.alloc.free(kptr_var);

            try g.w.print("var {s} = ", .{iter_var});
            try g.genExpr(s.iter);
            try g.w.writeAll(".keyIterator();\n");
            try g.writeIndent();
            try g.w.print("while ({s}.next()) |{s}| {{\n", .{iter_var, kptr_var});
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = {s}.*;\n", .{first_var, kptr_var});
            if (!nameUsedInStmts(first_var, s.body)) {
                try bg.writeIndent();
                try bg.w.print("_ = {s};\n", .{first_var});
            }
            if (s.where) |w| {
                try bg.writeIndent();
                try bg.w.writeAll("if (!(");
                try bg.genExpr(w);
                try bg.w.writeAll(")) continue;\n");
            }
            try bg.genStmts(s.body);
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for row in csv.rows()` / `for col in csv.header()` etc.
    /// The callee returns an ArrayList; we capture it first to avoid use-after-free on the temporary,
    /// then iterate `.items`.
    fn genForInCsvRows(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const var_name = if (s.vars.len > 0) s.vars[0] else "_row";
        const iter_var = try std.fmt.allocPrint(g.alloc, "_it_{s}", .{var_name});
        defer g.alloc.free(iter_var);

        // Wrap in a block so the `_it_*` const is scoped — prevents redeclaration
        // errors when the same loop-variable name is used in multiple CSV for-in loops.
        try g.writeIndent();
        try g.w.writeAll("{\n");
        const bg = g.indented();
        try bg.writeIndent();
        try bg.w.print("const {s} = ", .{iter_var});
        try bg.genExpr(s.iter);
        try bg.w.writeAll(";\n");
        try bg.writeIndent();
        try bg.w.print("for ({s}.items) |{s}| {{\n", .{iter_var, var_name});
        const bg2 = bg.indented();
        if (s.where) |w| {
            try bg2.writeIndent();
            try bg2.w.writeAll("if (!(");
            try bg2.genExpr(w);
            try bg2.w.writeAll(")) continue;\n");
        }
        try bg2.genStmts(s.body);
        try bg.writeIndent();
        try bg.w.writeAll("}\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `for x in str.split(delim)` / `for x in str.lines()` — while-loop pattern.
    fn genForInSplit(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const var_name = if (s.vars.len > 0) s.vars[0] else "_part";
        const iter_var = try std.fmt.allocPrint(g.alloc, "_it_{s}", .{var_name});
        defer g.alloc.free(iter_var);

        const recv   = s.iter.call.callee.member.object;
        const method = s.iter.call.callee.member.member;
        const s_args = s.iter.call.args;
        const is_lines = std.mem.eql(u8, method, "lines");

        try g.writeIndent();
        if (is_lines) {
            // lines() splits on '\n' using the scalar splitter (no allocation)
            try g.w.print("var {s} = std.mem.splitScalar(u8, ", .{iter_var});
            try g.genExpr(recv);
            try g.w.writeAll(", '\\n');\n");
        } else {
            try g.w.print("var {s} = std.mem.splitSequence(u8, ", .{iter_var});
            try g.genExpr(recv);
            try g.w.writeAll(", ");
            if (s_args.len > 0) try g.genExpr(s_args[0].value) else try g.w.writeAll("\" \"");
            try g.w.writeAll(");\n");
        }
        try g.writeIndent();
        try g.w.print("while ({s}.next()) |{s}| {{\n", .{iter_var, var_name});
        const bg = g.indented();
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// True when `expr` is a call to `str.chars()` on a string — codepoint iteration.
    fn isCharsCallOnString(g: Generator, expr: *const Ast.Expr) bool {
        if (expr.* != .call) return false;
        const callee = expr.call.callee;
        if (callee.* != .member) return false;
        if (!std.mem.eql(u8, callee.member.member, "chars")) return false;
        if (g.getExprDeclaredType(callee.member.object)) |tr| {
            return tr == .named and isStringTypeName(tr.named.name);
        }
        if (g.tc) |tc| {
            const obj_type = tc.expr_types.get(callee.member.object) orelse return false;
            return obj_type == .string;
        }
        return false;
    }

    /// `for c in str.chars()` — iterate Unicode codepoints via Utf8View.
    /// Emits a while loop using `std.unicode.Utf8View.initUnchecked().iterator()`.
    fn genForInChars(g: Generator, s: *Ast.StmtForIn) anyerror!void {
        const var_name = if (s.vars.len > 0) s.vars[0] else "_cp";
        // Use pointer address as unique suffix to avoid name collisions when the
        // same loop variable name (e.g. `c`) appears in two separate chars() loops.
        const uid = @intFromPtr(s) & 0xFFFF;
        const iter_var = try std.fmt.allocPrint(g.alloc, "_cp_it_{x}", .{uid});
        defer g.alloc.free(iter_var);

        const recv = s.iter.call.callee.member.object;

        try g.writeIndent();
        try g.w.print("var {s} = std.unicode.Utf8View.initUnchecked(", .{iter_var});
        try g.genExpr(recv);
        try g.w.writeAll(").iterator();\n");
        try g.writeIndent();
        try g.w.print("while ({s}.nextCodepoint()) |{s}| {{\n", .{iter_var, var_name});
        const bg = g.indented();
        if (s.where) |w| {
            try bg.writeIndent();
            try bg.w.writeAll("if (!(");
            try bg.genExpr(w);
            try bg.w.writeAll(")) continue;\n");
        }
        try bg.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// True when `expr` is a call to `str.split(delim)` or `str.lines()` on a string.
    fn isSplitCallOnString(g: Generator, expr: *const Ast.Expr) bool {
        if (expr.* != .call) return false;
        const callee = expr.call.callee;
        if (callee.* != .member) return false;
        const m = callee.member.member;
        if (!std.mem.eql(u8, m, "split") and !std.mem.eql(u8, m, "lines")) return false;
        if (g.getExprDeclaredType(callee.member.object)) |tr| {
            return tr == .named and isStringTypeName(tr.named.name);
        }
        // Also accept when the TC inferred string type for the object.
        if (g.tc) |tc| {
            const obj_type = tc.expr_types.get(callee.member.object) orelse return false;
            return obj_type == .string;
        }
        return false;
    }

    fn genForNum(g: Generator, s: *Ast.StmtForNum) anyerror!void {
        // `for i in start : stop : step` → Zig while loop with explicit counter.
        try g.writeIndent();
        try g.w.print("var {s}: i64 = ", .{s.var_});
        try g.genExpr(s.start);
        try g.w.writeAll(";\n");
        try g.writeIndent();
        try g.w.print("while ({s} < ", .{s.var_});
        try g.genExpr(s.stop);
        try g.w.print(") : ({s} += ", .{s.var_});
        if (s.step) |step| try g.genExpr(step) else try g.w.writeAll("1");
        try g.w.writeAll(") {\n");
        try g.indented().genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn genBranch(g: Generator, s: *Ast.StmtBranch) anyerror!void {
        // Detect union dispatch: any on-clause has a binding name.
        const is_union = for (s.on) |on| { if (on.binding != null) break true; } else false;

        // Detect whether any on-clause has a guard expression.
        const has_guard = for (s.on) |on| { if (on.guard != null) break true; } else false;

        // Detect string dispatch: any on-value is a string literal.
        // Zig cannot switch on []const u8 — lower to if / else-if chains instead.
        const is_string = blk: {
            for (s.on) |on| {
                for (on.values) |v| {
                    if (v.* == .string_lit) break :blk true;
                }
            }
            break :blk false;
        };

        if (is_string) {
            // ── String dispatch: lower to if-else-if chain ────────────────────
            // Hoist subject into a temp so it isn't evaluated N times.
            try g.writeIndent();
            const tmp = try std.fmt.allocPrint(g.alloc, "_bs_{x}", .{@intFromPtr(s)});
            defer g.alloc.free(tmp);
            try g.w.writeAll("{\n");
            const bg = g.indented();
            try bg.writeIndent();
            try bg.w.print("const {s} = ", .{tmp});
            try bg.genExpr(s.expr);
            try bg.w.writeAll(";\n");
            for (s.on, 0..) |on, ci| {
                try bg.writeIndent();
                if (ci > 0) try bg.w.writeAll("} else ");
                try bg.w.writeAll("if (");
                for (on.values, 0..) |v, vi| {
                    if (vi > 0) try bg.w.writeAll(" or ");
                    try bg.w.print("std.mem.eql(u8, {s}, ", .{tmp});
                    if (v.* == .string_lit) {
                        try bg.genExpr(v);
                    } else {
                        try bg.genExpr(v);
                    }
                    try bg.w.writeAll(")");
                }
                // AND in the guard for this clause.
                if (on.guard) |guard| {
                    try bg.w.writeAll(" and ");
                    try bg.genExpr(guard);
                }
                try bg.w.writeAll(") {\n");
                try bg.indented().genStmts(on.body);
            }
            if (s.else_) |eb| {
                try bg.writeIndent();
                try bg.w.writeAll("} else {\n");
                try bg.indented().genStmts(eb);
            }
            if (s.on.len > 0) {
                try bg.writeIndent();
                try bg.w.writeAll("}\n");
            }
            try g.writeIndent();
            try g.w.writeAll("}\n");
            return;
        }

        // ── Guarded dispatch (any on-clause has `if condition`) ──────────────
        // Zig switch prongs cannot have guards, so we lower to sequential ifs.
        // Each `if (!_bd and pattern)` check: if the pattern matches but the
        // guard fails, _bd stays false and the next clause can match.
        // Emitted flat (no wrapping block) so `if (!_bd) unreachable` at the end
        // is visible to Zig's return-path analysis.
        if (has_guard) {
            const bv = try std.fmt.allocPrint(g.alloc, "_bv_{x}", .{@intFromPtr(s)});
            defer g.alloc.free(bv);
            const bd = try std.fmt.allocPrint(g.alloc, "_bd_{x}", .{@intFromPtr(s)});
            defer g.alloc.free(bd);
            try g.writeIndent();
            try g.w.print("const {s} = ", .{bv});
            try g.genExpr(s.expr);
            try g.w.writeAll(";\n");
            try g.writeIndent();
            try g.w.print("var {s} = false;\n", .{bd});
            for (s.on) |on| {
                try g.writeIndent();
                try g.w.print("if (!{s}", .{bd});
                if (is_union) {
                    // Union: check the tag, extract payload, then check guard.
                    if (on.values.len == 1) {
                        const v = on.values[0];
                        const tag_name: []const u8 = if (v.* == .member)
                            v.member.member
                        else if (v.* == .call and v.call.callee.* == .member)
                            v.call.callee.member.member
                        else "";
                        if (tag_name.len > 0) {
                            try g.w.print(" and {s} == .{s}", .{ bv, tag_name });
                        }
                    }
                    try g.w.writeAll(") {\n");
                    if (on.binding) |bname| {
                        // Extract the payload before checking the guard.
                        try g.indented().writeIndent();
                        try g.indented().w.print("const {s} = {s}.{s};\n", .{ bname, bv, on.values[0].member.member });
                        // Suppress unused-const Zig warning when the body doesn't
                        // reference the binding.  Only emit when there is no guard:
                        // if a guard is present it already uses bname, and Zig would
                        // report "pointless discard" if we also emitted `_ = bname;`.
                        if (on.guard == null) {
                            try g.indented().writeIndent();
                            try g.indented().w.print("_ = {s};\n", .{bname});
                        }
                        if (on.guard) |guard| {
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("if (");
                            try g.indented().genExpr(guard);
                            try g.indented().w.writeAll(") {\n");
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("}\n");
                        } else {
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                        }
                    } else {
                        if (on.guard) |guard| {
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("if (");
                            try g.indented().genExpr(guard);
                            try g.indented().w.writeAll(") {\n");
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                            try g.indented().writeIndent();
                            try g.indented().w.writeAll("}\n");
                        } else {
                            try g.indented().writeIndent();
                            try g.indented().w.print("{s} = true;\n", .{bd});
                            try g.indented().indented().genStmts(on.body);
                        }
                    }
                } else {
                    // Non-union (integer / enum): AND the values condition.
                    if (on.values.len > 0) {
                        try g.w.writeAll(" and (");
                        for (on.values, 0..) |v, vi| {
                            if (vi > 0) try g.w.writeAll(" or ");
                            try g.w.print("{s} == ", .{bv});
                            if (v.* == .member) {
                                try g.w.print(".{s}", .{v.member.member});
                            } else {
                                try g.genExpr(v);
                            }
                        }
                        try g.w.writeAll(")");
                    }
                    try g.w.writeAll(") {\n");
                    if (on.guard) |guard| {
                        try g.indented().writeIndent();
                        try g.indented().w.writeAll("if (");
                        try g.indented().genExpr(guard);
                        try g.indented().w.writeAll(") {\n");
                        try g.indented().writeIndent();
                        try g.indented().w.print("{s} = true;\n", .{bd});
                        try g.indented().indented().genStmts(on.body);
                        try g.indented().writeIndent();
                        try g.indented().w.writeAll("}\n");
                    } else {
                        try g.indented().writeIndent();
                        try g.indented().w.print("{s} = true;\n", .{bd});
                        try g.indented().indented().genStmts(on.body);
                    }
                }
                try g.writeIndent();
                try g.w.writeAll("}\n");
            }
            if (s.else_) |eb| {
                try g.writeIndent();
                try g.w.print("if (!{s}) {{\n", .{bd});
                try g.indented().genStmts(eb);
                try g.writeIndent();
                try g.w.writeAll("}\n");
            } else {
                // No else clause: emit `if (!_bd) unreachable` so Zig's control
                // flow analysis sees this path is unreachable (avoids "implicitly
                // returns" on functions where every pattern arm returns a value).
                try g.writeIndent();
                try g.w.print("if (!{s}) unreachable;\n", .{bd});
                // When every on-clause body ends with an explicit return, Zig still
                // thinks the function can "fall off the end" after the `if (!_bd)`
                // check because it sees `_bd == true` as a live path.  In that case
                // add a bare `unreachable;` so the control-flow graph is closed.
                const all_arms_return = blk: {
                    for (s.on) |on| {
                        if (on.body.len == 0) break :blk false;
                        switch (on.body[on.body.len - 1]) {
                            .return_ => {},
                            else    => break :blk false,
                        }
                    }
                    break :blk true;
                };
                if (all_arms_return) {
                    try g.writeIndent();
                    try g.w.writeAll("unreachable;\n");
                }
            }
            return;
        }

        // ── Standard Zig switch dispatch (integer, enum, union) ──────────────
        try g.writeIndent();
        try g.w.writeAll("switch (");
        try g.genExpr(s.expr);
        try g.w.writeAll(") {\n");
        const bg = g.indented();
        for (s.on) |on| {
            try bg.writeIndent();
            for (on.values, 0..) |v, i| {
                if (i > 0) try bg.w.writeAll(", ");
                if (is_union) {
                    // Emit `.variant_name` — extract member part of `Type.variant` or
                    // `Type.variant()` (constructor-call form used in on-clauses) expr.
                    if (v.* == .member) {
                        try bg.w.print(".{s}", .{v.member.member});
                    } else if (v.* == .call and v.call.callee.* == .member) {
                        try bg.w.print(".{s}", .{v.call.callee.member.member});
                    } else {
                        try bg.genExpr(v);
                    }
                } else {
                    // Char/int range: `on c'a'..c'z'` → `'a'...'z'` in Zig switch
                    // Enum member: `on Foo.bar` or `on mod.Foo.bar` → `.bar`
                    if (v.* == .binary and v.binary.op == .dotdot) {
                        try bg.genExpr(v.binary.left);
                        try bg.w.writeAll("...");
                        try bg.genExpr(v.binary.right);
                    } else if (v.* == .member) {
                        try bg.w.print(".{s}", .{v.member.member});
                    } else {
                        try bg.genExpr(v);
                    }
                }
            }
            if (is_union) {
                if (on.binding) |bname| {
                    // Determine payload kind for this variant:
                    //   .ref_payload  → ^T: Zig binding gives *T; emit auto-deref local.
                    //   .list_payload → List(T): inject list_loop_vars so nested for-in
                    //                   knows to iterate via .items.
                    //   .other        → plain value payload; no special treatment.
                    const PayloadKind = enum { ref_payload, list_payload, other };
                    const payload_kind: PayloadKind = blk: {
                        const v = on.values[0];
                        const variant_name: []const u8 = if (v.* == .member)
                            v.member.member
                        else if (v.* == .call and v.call.callee.* == .member)
                            v.call.callee.member.member
                        else break :blk .other;
                        // Extract union type name from the value expression object
                        // (e.g. `Type.optional` → "Type", `Type.optional()` → "Type").
                        const union_name: []const u8 = if (v.* == .member and v.member.object.* == .ident)
                            v.member.object.ident.name
                        else if (v.* == .call and v.call.callee.* == .member and
                                 v.call.callee.member.object.* == .ident)
                            v.call.callee.member.object.ident.name
                        else break :blk .other;
                        const du = g.union_decls.get(union_name) orelse break :blk .other;
                        for (du.variants) |vr| {
                            if (std.mem.eql(u8, vr.name, variant_name)) {
                                if (vr.payload) |pl| {
                                    if (pl == .ref_to) break :blk .ref_payload;
                                    if (pl == .generic and
                                        std.mem.eql(u8, pl.generic.name, "List"))
                                        break :blk .list_payload;
                                }
                                break :blk .other;
                            }
                        }
                        break :blk .other;
                    };
                    if (payload_kind == .ref_payload) {
                        // Pointer payload: |bname_ptr| { const bname = bname_ptr.*; ... }
                        try bg.w.print(" => |{s}_ptr| {{\n", .{bname});
                        try bg.indented().writeIndent();
                        try bg.indented().w.print("const {s} = {s}_ptr.*;\n", .{ bname, bname });
                    } else {
                        try bg.w.print(" => |{s}| {{\n", .{bname});
                    }
                    // For List(T) payload bindings, inject list_loop_vars so that any
                    // `for elem in bname` loop inside the body uses genForInList (.items).
                    if (payload_kind == .list_payload) {
                        var llv = std.StringHashMap(void).init(g.alloc);
                        try llv.put(bname, {});
                        var body_gen = bg.indented();
                        body_gen.list_loop_vars = &llv;
                        try body_gen.genStmts(on.body);
                        llv.deinit();
                    } else {
                        try bg.indented().genStmts(on.body);
                    }
                } else {
                    try bg.w.writeAll(" => {\n");
                    try bg.indented().genStmts(on.body);
                }
            } else {
                try bg.w.writeAll(" => {\n");
                try bg.indented().genStmts(on.body);
            }
            try bg.writeIndent();
            try bg.w.writeAll("},\n");
        }
        if (s.else_) |eb| {
            try bg.writeIndent();
            try bg.w.writeAll("else => {\n");
            try bg.indented().genStmts(eb);
            try bg.writeIndent();
            try bg.w.writeAll("},\n");
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn genPrint(g: Generator, s: *Ast.StmtPrint) anyerror!void {
        try g.writeIndent();
        if (s.args.len == 0) {
            try g.w.writeAll("std.debug.print(\"\\n\", .{});\n");
            return;
        }

        // If any arg is an allocating string call (including interp), emit each
        // such arg into a named temp so we can defer-free it and avoid GPA leaks.
        var any_alloc = false;
        for (s.args) |a| {
            if (isAllocatingStringInit(a, g.tc) or a.* == .string_interp) {
                any_alloc = true; break;
            }
        }

        if (!any_alloc) {
            // Fast path: no temporaries needed.
            try g.w.writeAll("std.debug.print(\"");
            for (s.args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(" ");
                try g.w.writeAll(printFmt(g.tc, g.catch_var, a));
            }
            try g.w.writeAll("\\n\", .{");
            for (s.args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a);
            }
            try g.w.writeAll("});\n");
            return;
        }

        // Slow path: wrap in a block, emit temp + defer for each allocating arg.
        try g.w.writeAll("{\n");
        const bg = g.indented();
        // Collect temp-var names (null = not a temp).
        var tmp_names = std.ArrayList(?[]const u8){};
        try tmp_names.ensureTotalCapacity(g.alloc, s.args.len);
        defer {
            for (tmp_names.items) |tn| if (tn) |n| g.alloc.free(n);
            tmp_names.deinit(g.alloc);
        }
        for (s.args, 0..) |a, i| {
            if (isAllocatingStringInit(a, g.tc) or a.* == .string_interp) {
                const tname = try std.fmt.allocPrint(g.alloc, "_pt{d}", .{i});
                try tmp_names.append(g.alloc, tname);
                try bg.writeIndent();
                try bg.w.print("const {s} = ", .{tname});
                try bg.genExpr(a);
                try bg.w.writeAll(";\n");
                if (isAllocatingStringInit(a, g.tc) or a.* == .string_interp) {
                    try bg.writeIndent();
                    try bg.w.print("defer _allocator.free({s});\n", .{tname});
                }
            } else {
                try tmp_names.append(g.alloc, null);
            }
        }
        try bg.writeIndent();
        try bg.w.writeAll("std.debug.print(\"");
        for (s.args, 0..) |a, i| {
            if (i > 0) try bg.w.writeAll(" ");
            if (tmp_names.items[i] != null) {
                try bg.w.writeAll("{s}");
            } else {
                try bg.w.writeAll(printFmt(g.tc, g.catch_var, a));
            }
        }
        try bg.w.writeAll("\\n\", .{");
        for (s.args, 0..) |a, i| {
            if (i > 0) try bg.w.writeAll(", ");
            if (tmp_names.items[i]) |tn| {
                try bg.w.writeAll(tn);
            } else {
                try bg.genExpr(a);
            }
        }
        try bg.w.writeAll("});\n");
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    fn genAssert(g: Generator, s: *Ast.StmtAssert) anyerror!void {
        try g.writeIndent();
        if (s.message != null) {
            try g.w.writeAll("if (!(");
            try g.genExpr(s.cond);
            try g.w.writeAll(")) {\n");
            try g.indented().line("std.debug.print(\"assertion failed\\n\", .{});");
            try g.indented().line("unreachable;");
            try g.writeIndent();
            try g.w.writeAll("}\n");
        } else {
            try g.w.writeAll("std.debug.assert(");
            try g.genExpr(s.cond);
            try g.w.writeAll(");\n");
        }
    }

    fn genDefer(g: Generator, s: *Ast.StmtDefer) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll(if (s.is_err) "errdefer " else "defer ");
        switch (s.body) {
            .expr => |e| {
                try g.genExpr(e);
                try g.w.writeAll(";\n");
            },
            else => {
                try g.w.writeAll("{\n");
                try g.indented().genStmt(s.body);
                try g.writeIndent();
                try g.w.writeAll("}\n");
            },
        }
    }

    /// `with target eol Block` — emit a plain block where bare-name assignments
    /// were desugared by AstBuilder to `target.name = value`.
    /// At CodeGen level the body is already correct; just emit a scoped block.
    fn genWith(g: Generator, s: *Ast.StmtWith) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("{ // with ");
        try g.genExpr(s.target);
        try g.w.writeAll("\n");
        try g.indented().genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `arena eol Block` — emit a scoped ArenaAllocator that shadows `_allocator`.
    /// All allocations within the block use the sub-arena; freed on block exit.
    ///
    ///   {   // arena
    ///       var _arena_scope = std.heap.ArenaAllocator.init(_allocator);
    ///       defer _arena_scope.deinit();
    ///       const _allocator = _arena_scope.allocator();
    ///       // body
    ///   }
    /// `arena eol Block` — swap `_allocator` to a fresh sub-arena for the block,
    /// then restore the parent allocator on exit.
    ///
    ///   {   // arena
    ///       var _arena_scope = std.heap.ArenaAllocator.init(_allocator);
    ///       const _parent_alloc = _allocator;         // save
    ///       _allocator = _arena_scope.allocator();    // switch to sub-arena
    ///       defer { _allocator = _parent_alloc; _arena_scope.deinit(); }
    ///       // body uses _allocator → sub-arena
    ///   }
    fn genArenaScope(g: Generator, s: *Ast.StmtArenaScope) anyerror!void {
        const depth = g.arena_depth + 1;
        try g.writeIndent();
        try g.w.writeAll("{ // arena\n");
        var ig = g.indented();
        ig.arena_depth = depth;
        try ig.writeIndent(); try ig.w.print("var _arena_scope_{d} = std.heap.ArenaAllocator.init(_allocator);\n", .{depth});
        try ig.writeIndent(); try ig.w.print("const _parent_alloc_{d} = _allocator;\n", .{depth});
        try ig.writeIndent(); try ig.w.print("_allocator = _arena_scope_{d}.allocator();\n", .{depth});
        try ig.writeIndent(); try ig.w.print("defer {{ _allocator = _parent_alloc_{d}; _arena_scope_{d}.deinit(); }}\n", .{ depth, depth });
        try ig.genStmts(s.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    /// `var name [: T] = base except field=val ...`
    /// Emits: `const name [: T] = blk: { var _tmp = base; _tmp.f = v; break :blk _tmp; };`
    fn genVarExcept(g: Generator, s: *Ast.StmtVarExcept) anyerror!void {
        try g.writeIndent();
        try g.w.writeAll("const ");
        try g.w.writeAll(s.name);
        if (s.type_ref) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        }
        try g.w.writeAll(" = blk: {\n");
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.writeAll("var _tmp = ");
        try ig.genExpr(s.base);
        try ig.w.writeAll(";\n");
        for (s.fields) |f| {
            try ig.writeIndent();
            try ig.w.writeAll("_tmp.");
            try ig.w.writeAll(f.name);
            try ig.w.writeAll(" = ");
            try ig.genExpr(f.value);
            try ig.w.writeAll(";\n");
        }
        try ig.writeIndent();
        try ig.w.writeAll("break :blk _tmp;\n");
        try g.writeIndent();
        try g.w.writeAll("};\n");
    }

    /// `target = base except field=val ...`
    /// Emits: `target = blk: { var _tmp = base; _tmp.f = v; break :blk _tmp; };`
    fn genAssignExcept(g: Generator, s: *Ast.StmtAssignExcept) anyerror!void {
        try g.writeIndent();
        try g.genExpr(s.target);
        try g.w.writeAll(" = blk: {\n");
        const ig = g.indented();
        try ig.writeIndent();
        try ig.w.writeAll("var _tmp = ");
        try ig.genExpr(s.base);
        try ig.w.writeAll(";\n");
        for (s.fields) |f| {
            try ig.writeIndent();
            try ig.w.writeAll("_tmp.");
            try ig.w.writeAll(f.name);
            try ig.w.writeAll(" = ");
            try ig.genExpr(f.value);
            try ig.w.writeAll(";\n");
        }
        try ig.writeIndent();
        try ig.w.writeAll("break :blk _tmp;\n");
        try g.writeIndent();
        try g.w.writeAll("};\n");
    }

    // ── raise / try-catch ─────────────────────────────────────────────────────

    fn genRaise(g: Generator, s: *Ast.StmtRaise) anyerror!void {
        // Map to Zebra's thread-local error context + Zig error return.
        try g.writeIndent();
        if (s.message) |msg| {
            if (s.details) |det| {
                // Two-arg form: `raise "msg", details_obj`
                // Determine details type from TypeChecker to pick the right shim.
                const det_type = if (g.tc) |tc| tc.expr_types.get(det) orelse .unknown else .unknown;
                // Unique label from AST pointer so multiple raises don't collide.
                const uid = @intFromPtr(s) & 0xFFFF;

                const det_is_primitive = switch (det_type) {
                    .int, .uint, .float, .bool, .char,
                    .int_n, .uint_n, .float_n => true,
                    else => false,
                };
                if (det_is_primitive) {
                    const fmt: []const u8 = switch (det_type) {
                        .float, .float_n => "{d}",
                        .char            => "{u}",
                        else             => "{}",
                    };
                    try g.w.print("{{ const _rdet_{x}: []const u8 = std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{ uid, fmt });
                    try g.genExpr(det);
                    try g.w.print("}}) catch @panic(\"OOM\");\n", .{});
                    try g.writeIndent();
                    try g.w.print("  const _rdet_ptr_{x} = _allocator.create([]const u8) catch @panic(\"OOM\");\n", .{uid});
                    try g.writeIndent();
                    try g.w.print("  _rdet_ptr_{x}.* = _rdet_{x};\n", .{uid, uid});
                    try g.writeIndent();
                    try g.w.print("  const _rshim_{x} = struct {{ fn call(p: *anyopaque) []const u8 {{\n", .{uid});
                    try g.writeIndent();
                    try g.w.writeAll("      return @as(*[]const u8, @alignCast(@ptrCast(p))).*;\n");
                    try g.writeIndent();
                    try g.w.print("  }} }};\n", .{});
                    try g.writeIndent();
                    try g.w.writeAll("  _error_ctx = .{ .message = ");
                    try g.genExpr(msg);
                    try g.w.print(", .details = .{{ .ptr = @ptrCast(_rdet_ptr_{x}), .toString_fn = _rshim_{x}.call }} }};\n", .{ uid, uid });
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                } else if (det_type == .string) {
                    // String details: heap-alloc the slice header so the pointer is stable.
                    try g.w.print("{{ const _rdet_{x}: []const u8 = ", .{uid});
                    try g.genExpr(det);
                    try g.w.print(";\n", .{});
                    try g.writeIndent();
                    try g.w.print("  const _rdet_ptr_{x} = _allocator.create([]const u8) catch @panic(\"OOM\");\n", .{uid});
                    try g.writeIndent();
                    try g.w.print("  _rdet_ptr_{x}.* = _rdet_{x};\n", .{uid, uid});
                    try g.writeIndent();
                    try g.w.print("  const _rshim_{x} = struct {{ fn call(p: *anyopaque) []const u8 {{\n", .{uid});
                    try g.writeIndent();
                    try g.w.writeAll("      return @as(*[]const u8, @alignCast(@ptrCast(p))).*;\n");
                    try g.writeIndent();
                    try g.w.print("  }} }};\n", .{});
                    try g.writeIndent();
                    try g.w.writeAll("  _error_ctx = .{ .message = ");
                    try g.genExpr(msg);
                    try g.w.print(", .details = .{{ .ptr = @ptrCast(_rdet_ptr_{x}), .toString_fn = _rshim_{x}.call }} }};\n", .{ uid, uid });
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                } else {
                    // Object details: heap-alloc the object, generate type-specific shim.
                    // The type name is inferred from the expression (best-effort: use ident or call callee name).
                    const type_name = detailsTypeName(det);
                    try g.w.print("{{ const _rdet_{x} = _allocator.create({s}) catch @panic(\"OOM\");\n", .{ uid, type_name });
                    try g.writeIndent();
                    try g.w.print("  _rdet_{x}.* = ", .{uid});
                    try g.genExpr(det);
                    try g.w.writeAll(";\n");
                    try g.writeIndent();
                    try g.w.print("  const _rshim_{x} = struct {{ fn call(p: *anyopaque) []const u8 {{\n", .{uid});
                    try g.writeIndent();
                    try g.w.print("      return @as(*{s}, @alignCast(@ptrCast(p))).toString();\n", .{type_name});
                    try g.writeIndent();
                    try g.w.print("  }} }};\n", .{});
                    try g.writeIndent();
                    try g.w.writeAll("  _error_ctx = .{ .message = ");
                    try g.genExpr(msg);
                    try g.w.print(", .details = .{{ .ptr = @ptrCast(_rdet_{x}), .toString_fn = _rshim_{x}.call }} }};\n", .{ uid, uid });
                    try g.writeIndent();
                    try g.w.writeAll("}\n");
                }
            } else {
                // Simple form: message only, no details.
                try g.w.writeAll("_error_ctx = .{ .message = ");
                try g.genExpr(msg);
                try g.w.writeAll(", .details = null };\n");
            }
            try g.writeIndent();
        }
        if (g.try_block_label) |lbl| {
            // Inside a `try` block: record the error into the tracking variable
            // then break out of the labeled block (does not return from the method).
            const ev = g.try_err_var.?;
            try g.w.print("{s} = error.ZebraError;\n", .{ev});
            try g.writeIndent();
            try g.w.print("break :{s};\n", .{lbl});
        } else {
            try g.w.writeAll("return error.ZebraError;\n");
        }
    }

    fn genTryCatch(g: Generator, s: *Ast.StmtTryCatch) anyerror!void {
        // Emit try/catch using an inline labeled block + a ?anyerror tracking variable.
        // This keeps all outer-scope variables accessible (no anonymous function barrier).
        //
        //   var _try_err_XXXX: ?anyerror = null;
        //   _try_blk_XXXX: {
        //       // body — `raise` emits:
        //       //   _error_ctx = ...; _try_err_XXXX = error.ZebraError; break :_try_blk_XXXX;
        //       break :_try_blk_XXXX;  // normal exit
        //   }
        //   if (_try_err_XXXX != null) {
        //       // catch body
        //   }
        //
        // Label/var names are unique-per-try-block via the AST node pointer address.
        const ptr_id = @intFromPtr(s) & 0xFFFF;
        const blk_label = try std.fmt.allocPrint(g.alloc, "_try_blk_{x}", .{ptr_id});
        const err_var   = try std.fmt.allocPrint(g.alloc, "_try_err_{x}", .{ptr_id});
        defer g.alloc.free(blk_label);
        defer g.alloc.free(err_var);

        // var/const _try_err_XXXX: ?anyerror = null;
        // Use `var` only when the body may mutate the err variable (via `raise` or
        // `try expr`); otherwise `const` avoids Zig's "never mutated" diagnostic.
        const has_raise = bodyNeedsErrVar(s.body, g.tc) or bodyHasThrowsCall(s.body, g.resolve, g.imported_modules, g.owner_members);
        try g.writeIndent();
        try g.w.print("{s} {s}: ?anyerror = null;\n", .{
            if (has_raise) "var" else "const", err_var,
        });

        // _try_blk_XXXX: {
        try g.writeIndent();
        try g.w.print("{s}: {{\n", .{blk_label});

        // Body — `raise` breaks the block and sets err_var.
        const tg = g.indented().withTryLabel(blk_label, err_var);
        try tg.genStmts(s.body);

        // Normal-exit break (no error) — skip if the body's last statement
        // already unconditionally breaks (raise, or throws-call with its own break).
        const body_ends_in_break = blk: {
            if (s.body.len == 0) break :blk false;
            break :blk s.body[s.body.len - 1] == .raise;
        };
        if (!body_ends_in_break) {
            try g.indented().writeIndent();
            try g.w.print("break :{s};\n", .{blk_label});
        }
        try g.writeIndent();
        try g.w.writeAll("}\n");

        // Catch clause(s).
        if (s.clauses.len == 0) return;

        const first = s.clauses[0];
        const catch_name = first.binding orelse "";
        try g.writeIndent();
        try g.w.print("if ({s} != null) {{\n", .{err_var});
        // Generate catch body with the binding name wired to _error_ctx.
        try g.indented().withCatchVar(catch_name).genStmts(first.body);
        try g.writeIndent();
        try g.w.writeAll("}\n");

        for (s.clauses[1..]) |extra| {
            try g.writeIndent();
            try g.w.writeAll("// (additional catch clause — typed dispatch not yet implemented)\n");
            _ = extra;
        }
    }

    fn genGuard(g: Generator, s: *Ast.StmtGuard) anyerror!void {
        // guard cond else { body }  →  if (!(cond)) { body }
        try g.writeIndent();
        try g.w.writeAll("if (!(");
        try g.genExpr(s.cond);
        try g.w.writeAll(")) {\n");
        try g.indented().genStmts(s.else_body);
        try g.writeIndent();
        try g.w.writeAll("}\n");
    }

    // ── Expressions ───────────────────────────────────────────────────────────

    fn genExpr(g: Generator, expr: *const Ast.Expr) anyerror!void {
        // Expression substitution: used to hoist an allocating receiver out of
        // a return value chain so it can be defer-freed before the return.
        if (g.expr_subst) |sub| {
            if (sub.orig == expr) {
                try g.w.writeAll(sub.name);
                return;
            }
        }
        sw: switch (expr.*) {
            .int_lit       => |e| try g.w.writeAll(e.text),
            .float_lit     => |e| try g.w.writeAll(e.text),
            .bool_lit      => |e| try g.w.writeAll(if (e.value) "true" else "false"),
            .char_lit      => |e| {
                // Two forms:
                //   Legacy:  c'A' or c"A" — strip the 'c' prefix; Zig uses 'A'
                //   New:     'A'           — already valid Zig char literal; emit as-is
                if (e.text.len > 0 and e.text[0] == 'c') {
                    const inner = e.text[1..]; // strip leading 'c'
                    if (inner.len >= 2 and inner[0] == '"') {
                        // c"A" → 'A' (swap delimiters)
                        try g.w.writeByte('\'');
                        try g.w.writeAll(inner[1 .. inner.len - 1]);
                        try g.w.writeByte('\'');
                    } else {
                        try g.w.writeAll(inner); // c'A' → 'A'
                    }
                } else {
                    try g.w.writeAll(e.text); // 'A' → 'A' (no transformation needed)
                }
            },
            .string_lit    => |e| try g.genStringLit(e),
            .string_interp => |e| try g.genStringInterp(e),
            .nil  => try g.w.writeAll("null"),
            .this => try g.w.writeAll(if (g.in_method) "self" else "undefined"),

            .ident  => |*e| try g.genIdent(e),
            .member => |e| {
                // Catch-variable member access: e.message → _error_ctx.message,
                //                               e.details → _error_ctx.details
                if (g.catch_var.len > 0 and e.object.* == .ident and
                    std.mem.eql(u8, e.object.ident.name, g.catch_var))
                {
                    if (std.mem.eql(u8, e.member, "message")) {
                        try g.w.writeAll("_error_ctx.message");
                        break :sw;
                    }
                    if (std.mem.eql(u8, e.member, "details")) {
                        try g.w.writeAll("_error_ctx.details");
                        break :sw;
                    }
                }
                // Stdlib property access: list.len → list.items.len, etc.
                if (g.getExprDeclaredType(e.object)) |tr| {
                    if (try g.genStdlibProp(e.object, tr, e.member)) break :sw;
                }
                // TC-type fallback for List/HashMap len/count on unannotated vars.
                if (g.tc) |tc| {
                    const obj_tc = tc.expr_types.get(e.object) orelse .unknown;
                    if (obj_tc == .generic_named) {
                        const gn = obj_tc.generic_named;
                        if (std.mem.eql(u8, gn.sym.name, "List") and
                            (std.mem.eql(u8, e.member, "len") or std.mem.eql(u8, e.member, "count"))) {
                            try g.writeListLen(e.object);
                            break :sw;
                        }
                        if (std.mem.eql(u8, gn.sym.name, "HashMap") and
                            (std.mem.eql(u8, e.member, "len") or std.mem.eql(u8, e.member, "count"))) {
                            try g.genExpr(e.object);
                            try g.w.writeAll(".count()");
                            break :sw;
                        }
                    }
                }
                // TC-type fallback for DateTime field access (unannotated vars).
                if (g.tc) |tc| {
                    const obj_tc = tc.expr_types.get(e.object) orelse .unknown;
                    if (obj_tc == .date_time) {
                        const dt_fields = std.StaticStringMap([]const u8).initComptime(&.{
                            .{ "year", "year" }, .{ "month", "month" }, .{ "day", "day" },
                            .{ "hour", "hour" }, .{ "minute", "minute" }, .{ "second", "second" },
                        });
                        if (dt_fields.get(e.member)) |field| {
                            try g.w.writeAll("_dt_to_gregorian(");
                            try g.genExpr(e.object);
                            try g.w.print(".epoch_ms).{s}", .{field});
                            break :sw;
                        }
                        if (std.mem.eql(u8, e.member, "weekday")) {
                            try g.w.writeAll("_dt_weekday(");
                            try g.genExpr(e.object);
                            try g.w.writeAll(")");
                            break :sw;
                        }
                    }
                }
                // Computed property (getter): obj.area → obj.area()
                if (g.tc) |tc| {
                    const obj_type = tc.expr_types.get(e.object) orelse .unknown;
                    if (obj_type == .named) {
                        const key = std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ obj_type.named.name, e.member }) catch "";
                        if (tc.getter_methods.contains(key)) {
                            try g.genExpr(e.object);
                            try g.w.writeByte('.');
                            try g.w.writeAll(e.member);
                            try g.w.writeAll("()");
                            break :sw;
                        }
                    }
                }
                // Math constants: Math.PI, Math.E, Math.TAU, Math.INF, Math.NAN
                if (e.object.* == .ident and std.mem.eql(u8, e.object.ident.name, "Math")) {
                    if (std.mem.eql(u8, e.member, "PI"))  { try g.w.writeAll("std.math.pi");      break :sw; }
                    if (std.mem.eql(u8, e.member, "E"))   { try g.w.writeAll("std.math.e");       break :sw; }
                    if (std.mem.eql(u8, e.member, "TAU")) { try g.w.writeAll("std.math.tau");     break :sw; }
                    if (std.mem.eql(u8, e.member, "INF")) { try g.w.writeAll("std.math.inf(f64)"); break :sw; }
                    if (std.mem.eql(u8, e.member, "NAN")) { try g.w.writeAll("std.math.nan(f64)"); break :sw; }
                }
                // Tuple index access: p.0 → p.@"0"
                if (e.member.len > 0 and std.ascii.isDigit(e.member[0])) {
                    try g.genExpr(e.object);
                    try g.w.print(".@\"{s}\"", .{e.member});
                    break :sw;
                }
                // Last-resort List.len: cross-module calls returning List(T) have TC type
                // `.unknown` (generic returns are not preserved in ModuleInterface).
                // When the member is `len` AND the object's type is unknown (not a concrete
                // named type, not a string), assume ArrayList and emit `.items.len`.
                // Use `.len` only (not `count`) to avoid collisions with user struct fields
                // named `count` (e.g. `Counter.count`).
                if (std.mem.eql(u8, e.member, "len")) {
                    const obj_tc = if (g.tc) |tc| tc.expr_types.get(e.object) orelse .unknown else TypeChecker.Type.unknown;
                    if (obj_tc == .unknown) {
                        try g.writeListLen(e.object);
                        break :sw;
                    }
                }
                // Auto-deref for ^T struct/class fields: `pair.left` → `pair.left.*`
                // when the field's declared TypeRef is ref_to (^T in Zebra).
                // Zig stores the pointer; Zebra semantics expose the dereffed value.
                const field_needs_deref = blk: {
                    const tc = g.tc orelse break :blk false;
                    const obj_type = tc.expr_types.get(e.object) orelse break :blk false;
                    if (obj_type != .named) break :blk false;
                    const sym = obj_type.named;
                    const scope = sym.own_scope orelse break :blk false;
                    const field_sym = scope.lookupLocal(e.member) orelse break :blk false;
                    if (field_sym.decl != .var_) break :blk false;
                    const field_tr = field_sym.decl.var_.type_ orelse break :blk false;
                    break :blk field_tr == .ref_to;
                };
                try g.genExpr(e.object);
                try g.w.writeAll(".");
                try g.w.writeAll(e.member);
                if (field_needs_deref) try g.w.writeAll(".*");
            },
            .call  => |e| try g.genCall(e),

            .index => |e| {
                try g.genExpr(e.object);
                try g.w.writeAll("[");
                // str ([]const u8) requires usize index; i64 variables need a cast.
                const idx_needs_cast = if (g.tc) |tc| blk: {
                    const t = tc.expr_types.get(e.index) orelse .unknown;
                    break :blk t == .int or t == .uint;
                } else false;
                if (idx_needs_cast) try g.w.writeAll("@intCast(");
                try g.genExpr(e.index);
                if (idx_needs_cast) try g.w.writeAll(")");
                try g.w.writeAll("]");
            },
            .slice => |e| {
                try g.genExpr(e.object);
                try g.w.writeAll("[");
                if (e.start) |s| {
                    const needs_cast = if (g.tc) |tc| blk: {
                        const t = tc.expr_types.get(s) orelse .unknown;
                        break :blk t == .int or t == .uint;
                    } else false;
                    if (needs_cast) try g.w.writeAll("@intCast(");
                    try g.genExpr(s);
                    if (needs_cast) try g.w.writeAll(")");
                } else {
                    try g.w.writeAll("0");
                }
                try g.w.writeAll("..");
                if (e.stop) |s| {
                    const needs_cast = if (g.tc) |tc| blk: {
                        const t = tc.expr_types.get(s) orelse .unknown;
                        break :blk t == .int or t == .uint;
                    } else false;
                    if (needs_cast) try g.w.writeAll("@intCast(");
                    try g.genExpr(s);
                    if (needs_cast) try g.w.writeAll(")");
                }
                try g.w.writeAll("]");
            },

            .binary => |e| try g.genBinary(e),
            .unary  => |e| try g.genUnary(e),

            .cast => |e| {
                try g.w.writeAll("@as(");
                try g.genType(e.target);
                try g.w.writeAll(", ");
                try g.genExpr(e.expr);
                try g.w.writeAll(")");
            },
            .to_nilable => |e| {
                // `expr to?` — we don't know the target type here; pass through.
                try g.genExpr(e.expr);
            },
            .to_non_nil => |e| {
                // If the inner ident is already nil-narrowed, genIdent will emit
                // `name.?` itself. Adding another `.?` would produce `name.?.?`.
                // Only append `.?` when the expression is not already unwrapped.
                const already_unwrapped = blk: {
                    if (g.nil_narrowed) |nn| {
                        switch (e.expr.*) {
                            .ident => |ie| break :blk nn.contains(ie.name),
                            else => {},
                        }
                    }
                    break :blk false;
                };
                try g.genExpr(e.expr);
                if (!already_unwrapped) try g.w.writeAll(".?");
            },
            .is_nil => |e| {
                try g.w.writeAll("(");
                try g.genExpr(e.expr);
                try g.w.writeAll(" == null)");
            },
            .orelse_ => |e| {
                try g.genExpr(e.expr);
                try g.w.writeAll(" orelse ");
                try g.genExpr(e.fallback);
            },
            .catch_ => |e| {
                try g.genExpr(e.expr);
                if (e.err_var) |ev| {
                    try g.w.print(" catch |{s}| ", .{ev});
                } else {
                    try g.w.writeAll(" catch ");
                }
                try g.genExpr(e.fallback);
            },
            .if_expr => |e| {
                try g.w.writeAll("if (");
                try g.genExpr(e.cond);
                try g.w.writeAll(") ");
                try g.genExpr(e.then_expr);
                try g.w.writeAll(" else ");
                try g.genExpr(e.else_expr);
            },
            .lambda   => |e| try g.genLambda(e),
            .list_lit => |e| {
                // Emit as a comptime slice literal.
                try g.w.writeAll("&.{");
                for (e.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genExpr(el);
                }
                try g.w.writeAll("}");
            },
            .dict_lit => {
                try g.w.writeAll(
                    "@compileError(\"dict literal: use std.AutoHashMap\")",
                );
            },
            .array_lit => |e| {
                try g.w.writeAll(".{");
                for (e.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genExpr(el);
                }
                try g.w.writeAll("}");
            },
            .all_any => {
                try g.w.writeAll("@compileError(\"all/any: rewrite as a loop\")");
            },
            .old     => |e| try g.genExpr(e.expr), // contract pre-value → pass through
            .zig_lit => |e| try g.genZigLit(e),
            .try_ => |e| {
                // `expr?` in Zebra — two meanings depending on the inner type:
                //   - error union → `try expr`   (propagate error to caller)
                //   - optional    → `expr.?`      (force-unwrap; panics if nil)
                // Note: `opt?.field` is parsed as `(try_ opt).field`, so we
                // emit `opt.?.field` — `.?` auto-derefs through `?*T` too.
                // Use optional_unwraps (declared type, pre nil-narrowing) rather than
                // expr_types (which may be narrowed to the non-optional type inside guards).
                const inner_is_optional = if (g.tc) |tc| tc.optional_unwraps.contains(expr) else false;
                if (inner_is_optional) {
                    // If the inner ident is already nil-narrowed, genIdent will emit
                    // `name.?` on its own — don't add a second `.?`.
                    const already_nil_narrowed = blk: {
                        if (g.nil_narrowed) |nn| {
                            if (e.expr.* == .ident) break :blk nn.contains(e.expr.ident.name);
                        }
                        break :blk false;
                    };
                    try g.genExpr(e.expr);
                    if (!already_nil_narrowed) try g.w.writeAll(".?");
                } else if (g.try_block_label) |lbl| {
                    // Inside a try/catch block: redirect errors to the block's
                    // tracking variable and break out, rather than propagating
                    // to the enclosing method.
                    //   expr catch |_c| { _try_err_XXXX = _c; break :blk; }
                    const ev  = g.try_err_var.?;
                    const tmp = try std.fmt.allocPrint(g.alloc, "_tc_{x}", .{@intFromPtr(e)});
                    defer g.alloc.free(tmp);
                    try g.genExpr(e.expr);
                    try g.w.print(" catch |{s}| {{ {s} = {s}; break :{s}; }}", .{ tmp, ev, tmp, lbl });
                } else {
                    try g.w.writeAll("try ");
                    // Suppress auto-try inside genCall — the `try` above already covers it.
                    // g is a value parameter, so shadow it with a mutable copy.
                    var g2 = g;
                    g2.suppress_auto_try = true;
                    try g2.genExpr(e.expr);
                }
            },
            .tuple_lit => |e| {
                // (a, b, c) → .{ @as(T0, a), @as(T1, b), @as(T2, c) }
                // Use @as(T, ...) so Zig can determine the anonymous struct field types.
                try g.w.writeAll(".{ ");
                for (e.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(el) orelse .unknown;
                        if (t != .unknown and t != .named) {
                            const zig_t = Builtins.zigTypeName(t.name());
                            if (!std.mem.eql(u8, zig_t, t.name())) {
                                try g.w.print("@as({s}, ", .{zig_t});
                                try g.genExpr(el);
                                try g.w.writeAll(")");
                                continue;
                            }
                        }
                    }
                    try g.genExpr(el);
                }
                try g.w.writeAll(" }");
            },

            // `expr is TypeName` — runtime type-tag check.
            // Non-generic: emits (expr._type_tag == _ttag_TypeName)
            //   Upper bits of _ttag are 0, so full u64 compare works.
            // Generic bare check (Phase 3): will emit (expr._type_tag & 0xFFFFFFFF) == _ttag_TypeName
            // Parameterised (Phase 3): will emit (expr._type_tag == <combined u64 literal>)
            // Parenthesised so unary `not` and other operators bind correctly.
            .type_check => |e| {
                try g.w.writeAll("(");
                try g.genExpr(e.expr);
                try g.w.print("._type_tag == _ttag_{s})", .{e.type_name});
            },
        }
    }

    /// Emit an identifier, injecting `self.` when the resolved symbol is a
    /// field and we are inside a method body.
    /// Look up the declared type of an expression.  Only works for direct
    /// identifier references (local vars and parameters that have a type
    /// annotation).  Returns null for everything else.
    fn getExprDeclaredType(g: Generator, expr: *const Ast.Expr) ?Ast.TypeRef {
        if (expr.* == .ident) {
            const sym = g.resolve.exprs.get(&expr.ident) orelse return null;
            return switch (sym.decl) {
                .var_  => |v| v.type_,
                .param => |p| p.type_,
                else   => null,
            };
        }
        // Handle `this.fieldName` — look up the field in the current class's member list.
        if (expr.* == .member) {
            const mem = expr.member;
            if (mem.object.* == .this) {
                for (g.owner_members) |decl| {
                    if (decl == .var_) {
                        const field = decl.var_;
                        if (std.mem.eql(u8, field.name, mem.member)) {
                            return field.type_;
                        }
                    }
                }
                return null;
            }
        }
        // Handle `ClassName.fieldName` — look through the class's member list for the field type.
        if (expr.* == .member) {
            const mem = expr.member;
            if (mem.object.* == .ident) {
                const class_sym = g.resolve.exprs.get(&mem.object.ident) orelse return null;
                const members: []const Ast.Decl = switch (class_sym.decl) {
                    .class   => |c| c.members,
                    .struct_ => |s| s.members,
                    else     => return null,
                };
                for (members) |decl| {
                    if (decl == .var_) {
                        const field = decl.var_;
                        if (std.mem.eql(u8, field.name, mem.member)) {
                            return field.type_;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn genIdent(g: Generator, e: *const Ast.ExprIdent) anyerror!void {
        // Inside a lambda body: captured vars become self.name
        for (g.capture_fields) |cf| {
            if (std.mem.eql(u8, cf, e.name)) {
                try g.w.print("self.{s}", .{e.name});
                return;
            }
        }
        if (g.in_method) {
            if (g.resolve.exprs.get(e)) |sym| {
                if (sym.kind == .var_) {
                    // Nil-narrowed field: self.name.?
                    if (g.nil_narrowed) |nn| {
                        if (nn.contains(e.name)) {
                            try g.w.print("self.{s}.?", .{e.name});
                            return;
                        }
                    }
                    try g.w.print("self.{s}", .{e.name});
                    return;
                }
            }
        }
        // Nil-narrowed local: name.?
        if (g.nil_narrowed) |nn| {
            if (nn.contains(e.name)) {
                try g.w.print("{s}.?", .{e.name});
                return;
            }
        }
        try g.w.writeAll(e.name);
    }

    /// Return the `[]const Param` for a callee expression, or null if unavailable.
    /// Used to support named/default arguments at call sites.
    fn lookupParams(g: Generator, e: *Ast.ExprCall) ?[]const Ast.Param {
        if (e.callee.* == .ident) {
            if (g.resolve.exprs.get(&e.callee.ident)) |sym| {
                switch (sym.decl) {
                    .method => |m| return m.params,
                    // Constructor call: ClassName(name: val, ...) — find cue init params.
                    .class  => |c| {
                        for (c.members) |mem| if (mem == .init) return mem.init.params;
                        return null;
                    },
                    .struct_ => |s| {
                        for (s.members) |mem| if (mem == .init) return mem.init.params;
                        return null;
                    },
                    else => return null,
                }
            }
        }
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            const obj_type = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
            if (obj_type == .named) {
                const class_sym = obj_type.named;
                if (class_sym.own_scope) |scope| {
                    if (scope.lookupLocal(mem.member)) |method_sym| {
                        if (method_sym.kind == .method) return method_sym.decl.method.params;
                    }
                }
            }
        }
        return null;
    }

    /// Emit a comma-separated argument list, honouring named args and defaults.
    /// If params is null or no arg is named, falls back to positional emission.
    fn genArgs(g: Generator, params: ?[]const Ast.Param, args: []const Ast.Arg) anyerror!void {
        const has_named = for (args) |a| { if (a.name != null) break true; } else false;
        if (!has_named) {
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genArgExpr(a.value);
            }
            return;
        }
        if (params) |ps| {
            // Build a resolved array indexed by param position.
            var resolved = try g.alloc.alloc(?*const Ast.Expr, ps.len);
            defer g.alloc.free(resolved);
            @memset(resolved, null);
            var positional_idx: usize = 0;
            for (args) |a| {
                if (a.name) |name| {
                    for (ps, 0..) |p, pi| {
                        if (std.mem.eql(u8, p.name, name)) { resolved[pi] = a.value; break; }
                    }
                } else {
                    while (positional_idx < ps.len and resolved[positional_idx] != null) : (positional_idx += 1) {}
                    if (positional_idx < ps.len) { resolved[positional_idx] = a.value; positional_idx += 1; }
                }
            }
            for (resolved, 0..) |maybe_expr, i| {
                if (i > 0) try g.w.writeAll(", ");
                if (maybe_expr) |expr| {
                    try g.genArgExpr(expr);
                } else if (i < ps.len and ps[i].default != null) {
                    try g.genArgExpr(ps[i].default.?);
                } else {
                    try g.w.writeAll("undefined"); // missing required arg
                }
            }
        } else {
            // No param info — emit positionally in order written.
            for (args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genArgExpr(a.value);
            }
        }
    }

    /// Emit a single argument expression, prepending `&` when the expression is
    /// a bare fn_ref (function name) being passed to a fn_sig-typed parameter.
    fn genArgExpr(g: Generator, expr: *const Ast.Expr) anyerror!void {
        if (g.tc) |tc| {
            if (tc.fn_ref_args.contains(expr)) {
                try g.w.writeAll("&");
            }
        }
        try g.genExpr(expr);
    }

    fn genCall(g: Generator, e: *Ast.ExprCall) anyerror!void {
        // Generic construction: Stack(int)(42) → Stack(i64).init(42)
        // Detected by type_args.len > 0 (set by AstBuilder.buildGenericConstruct).
        if (e.type_args.len > 0 and e.callee.* == .ident) {
            const class_name = e.callee.ident.name;
            // Stdlib generics: List(T)() → std.ArrayList(T){} (allocator passed to each op)
            if (std.mem.eql(u8, class_name, "List") and e.type_args.len == 1) {
                try g.w.writeAll("std.ArrayList(");
                try g.genType(e.type_args[0]);
                try g.w.writeAll("){}");
                return;
            }
            try g.w.writeAll(class_name);
            try g.w.writeAll("(");
            for (e.type_args, 0..) |ta, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genType(ta);
            }
            try g.w.writeAll(").init(");
            for (e.args, 0..) |a, i| {
                if (i > 0) try g.w.writeAll(", ");
                try g.genExpr(a.value);
            }
            try g.w.writeAll(")");
            return;
        }

        // Union construction: TypeName.variant(value) → TypeName{ .variant = value }
        // or TypeName.variant() → TypeName{ .variant = {} } for unit variants.
        // e.details.toString() inside a catch block →
        //   if (_error_ctx.details) |_d| _d.toString() else ""
        if (e.callee.* == .member and g.catch_var.len > 0) {
            const mem = e.callee.member;
            if (std.mem.eql(u8, mem.member, "toString") and
                mem.object.* == .member)
            {
                const inner = mem.object.member;
                if (std.mem.eql(u8, inner.member, "details") and
                    inner.object.* == .ident and
                    std.mem.eql(u8, inner.object.ident.name, g.catch_var))
                {
                    try g.w.writeAll("(if (_error_ctx.details) |_det| _det.toString() else \"\")");
                    return;
                }
            }
        }
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            // Cross-module union construction: Module.UnionName.variant(value?)
            // Callee shape: { object: member { object: ident(mod_alias), member: type_name }, member: variant }
            // Emit: mod_alias.TypeName{ .variant = value_or_{} }
            if (mem.object.* == .member) {
                const outer = mem.object.member;
                if (outer.object.* == .ident) {
                    const mod_alias  = outer.object.ident.name;
                    const type_name  = outer.member;
                    const variant    = mem.member;
                    // Confirm the type is a union in the imported module.
                    const is_xmod_union = blk: {
                        const imp = g.imported_modules orelse break :blk false;
                        const iface = imp.get(mod_alias) orelse break :blk false;
                        const is_union_ptr = iface.types.getPtr(type_name) orelse break :blk false;
                        break :blk is_union_ptr.*;
                    };
                    if (is_xmod_union) {
                        try g.w.print("{s}.{s}{{ .{s} = ", .{ mod_alias, type_name, variant });
                        if (e.args.len == 1) {
                            // Check whether this cross-module variant's payload is ^T.
                            const box_type: ?[]const u8 = blk: {
                                const imp = g.imported_modules orelse break :blk null;
                                const iface = imp.get(mod_alias) orelse break :blk null;
                                const key = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ type_name, variant });
                                defer g.alloc.free(key);
                                break :blk iface.boxed_variants.get(key);
                            };
                            if (box_type) |inner_name| {
                                const box_lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{@intFromPtr(e)});
                                defer g.alloc.free(box_lbl);
                                try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, @intFromPtr(e) });
                                try g.w.print("{s}.{s}", .{ mod_alias, inner_name });
                                try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{@intFromPtr(e)});
                                try g.genExpr(e.args[0].value);
                                try g.w.print("; break :{s} _bp_{x}; }}", .{ box_lbl, @intFromPtr(e) });
                            } else {
                                try g.genExpr(e.args[0].value);
                            }
                        } else {
                            try g.w.writeAll("{}");
                        }
                        try g.w.writeAll(" }");
                        return;
                    }
                }
            }
            if (mem.object.* == .ident) {
                // Result.ok(v) / Result.err(v) → anonymous struct literal, inferred to declared type
                if (std.mem.eql(u8, mem.object.ident.name, "Result")) {
                    if (std.mem.eql(u8, mem.member, "ok") or std.mem.eql(u8, mem.member, "err")) {
                        try g.w.print(".{{ .{s} = ", .{mem.member});
                        if (e.args.len >= 1) try g.genExpr(e.args[0].value) else try g.w.writeAll("{}");
                        try g.w.writeAll(" }");
                        return;
                    }
                }
                const type_name = mem.object.ident.name;
                if (g.union_names.contains(type_name) or g.exposed_unions.contains(type_name)) {
                    try g.w.print("{s}{{ .{s} = ", .{type_name, mem.member});
                    if (e.args.len == 1) {
                        // Check whether this variant's payload is ^T (heap-boxed).
                        // For same-module unions: look up union_decls.
                        // For exposed (cross-module) unions: look up boxed_variants via the
                        // stored module alias so the correct qualified inner type is emitted.
                        var box_inner: ?*const Ast.TypeRef = null;
                        var box_xmod_alias: ?[]const u8  = null;
                        var box_xmod_inner: ?[]const u8  = null;
                        if (g.union_decls.get(type_name)) |du| {
                            for (du.variants) |v| {
                                if (std.mem.eql(u8, v.name, mem.member)) {
                                    if (v.payload) |pl| switch (pl) {
                                        .ref_to => |inner| { box_inner = inner; },
                                        else    => {},
                                    };
                                    break;
                                }
                            }
                        } else if (g.exposed_unions.get(type_name)) |mod_alias| {
                            // Cross-module exposed union: consult boxed_variants table.
                            if (g.imported_modules) |imp| {
                                if (imp.get(mod_alias)) |iface| {
                                    const key = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ type_name, mem.member });
                                    defer g.alloc.free(key);
                                    if (iface.boxed_variants.get(key)) |inner_name| {
                                        box_xmod_alias = mod_alias;
                                        box_xmod_inner = inner_name;
                                    }
                                }
                            }
                        }
                        if (box_inner) |inner| {
                            const box_lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{@intFromPtr(e)});
                            defer g.alloc.free(box_lbl);
                            try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, @intFromPtr(e) });
                            try g.genType(inner.*);
                            try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{@intFromPtr(e)});
                            try g.genExpr(e.args[0].value);
                            try g.w.print("; break :{s} _bp_{x}; }}", .{ box_lbl, @intFromPtr(e) });
                        } else if (box_xmod_inner) |inner_name| {
                            const box_lbl = try std.fmt.allocPrint(g.alloc, "_box_{x}", .{@intFromPtr(e)});
                            defer g.alloc.free(box_lbl);
                            try g.w.print("{s}: {{ const _bp_{x} = _allocator.create(", .{ box_lbl, @intFromPtr(e) });
                            try g.w.print("{s}.{s}", .{ box_xmod_alias.?, inner_name });
                            try g.w.print(") catch @panic(\"OOM\"); _bp_{x}.* = ", .{@intFromPtr(e)});
                            try g.genExpr(e.args[0].value);
                            try g.w.print("; break :{s} _bp_{x}; }}", .{ box_lbl, @intFromPtr(e) });
                        } else {
                            try g.genExpr(e.args[0].value);
                        }
                    } else {
                        try g.w.writeAll("{}");
                    }
                    try g.w.writeAll(" }");
                    return;
                }
            }
        }
        // Builtin collection constructors: `List()` → `std.ArrayList(...){}`,
        // `HashMap()` → `std.StringHashMap(...).init(_allocator)`.
        // These appear in assignment RHS and field initializers when no type annotation
        // is available, so we emit the least-typed form that Zig can infer.
        if (e.callee.* == .ident and e.args.len == 0) {
            const name = e.callee.ident.name;
            if (std.mem.eql(u8, name, "List")) {
                // Zero-arg `List()` without LHS type context.
                // Class field assignments now go through genStdlibInit directly (in genAssign),
                // so this path only fires for bare expressions like `return List()` or
                // unannotated local vars. Rely on Zig inference via `.{}` in generic bodies,
                // or emit the untyped ArrayList form for non-generic contexts.
                if (g.is_generic) {
                    try g.w.writeAll(".{}");
                } else {
                    try g.w.writeAll("std.ArrayList([]const u8){}");
                }
                return;
            }
            if (std.mem.eql(u8, name, "HashMap")) {
                try g.w.writeAll("std.StringHashMap(i64).init(_allocator)");
                return;
            }
            if (std.mem.eql(u8, name, "CsvWriter")) {
                try g.w.writeAll("_csv_writer_init()");
                return;
            }
        }
        // Constructor call for exposed class alias: `ExposedClass(args)` after
        // `use Mod exposing ExposedClass` → `ExposedClass.init(args)`.
        // Must be checked before the generic ident-call path below.
        if (e.callee.* == .ident) {
            const cname = e.callee.ident.name;
            if (g.exposed_classes.contains(cname)) {
                try g.w.print("{s}.init(", .{cname});
                for (e.args, 0..) |a, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genExpr(a.value);
                }
                try g.w.writeAll(")");
                return;
            }
        }
        // Constructor call: ClassName(args) → ClassName.init(args) if class has `cue init`,
        // else ClassName{} for zero-value construction.
        if (e.callee.* == .ident) {
            const ident = &e.callee.ident;
            if (g.resolve.exprs.get(ident)) |sym| {
                if (sym.kind == .class or sym.kind == .struct_) {
                    const class_name = ident.name;
                    // Scan AST members for a `cue init` declaration (DeclInit).
                    const members: []const Ast.Decl = switch (sym.decl) {
                        .class   => |c| c.members,
                        .struct_ => |s| s.members,
                        else     => &[_]Ast.Decl{},
                    };
                    var has_cue_init = false;
                    for (members) |m| {
                        if (m == .init) { has_cue_init = true; break; }
                    }
                    if (has_cue_init) {
                        try g.w.print("{s}.init(", .{class_name});
                        // Resolve init params for named-arg reordering support.
                        const init_params: ?[]const Ast.Param = blk: {
                            for (members) |m| {
                                if (m == .init) break :blk m.init.params;
                            }
                            break :blk null;
                        };
                        try g.genArgs(init_params, e.args);
                        try g.w.writeAll(")");
                    } else if (sym.kind == .struct_) {
                        // Structs without `cue init`: emit a struct literal.
                        // Named args → .field = value; positional → value (order = declaration order).
                        if (e.args.len == 0) {
                            try g.w.print("{s}{{}}", .{class_name});
                        } else {
                            try g.w.print("{s}{{", .{class_name});
                            for (e.args, 0..) |a, i| {
                                if (i > 0) try g.w.writeAll(",");
                                if (a.name) |n| {
                                    try g.w.print(" .{s} = ", .{n});
                                } else {
                                    try g.w.writeAll(" ");
                                }
                                try g.genExpr(a.value);
                            }
                            try g.w.writeAll(" }");
                        }
                    } else {
                        // No explicit `cue init`: call the synthetic default init().
                        // Every class now has a generated init() that stamps _type_id.
                        try g.w.print("{s}.init()", .{class_name});
                    }
                    return;
                }
            }
        }
        // File I/O static calls: File.read(path), File.write(path, data), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "File")) {
                if (try g.genFileCall(mem.member, e.args)) return;
            }
        }
        // Dir static calls: Dir.create/delete/exists/list/createAll/deleteAll.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Dir")) {
                if (try g.genDirCall(mem.member, e.args)) return;
            }
        }
        // Path static calls: Path.join/basename/dirname/ext/stem/isAbsolute.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Path")) {
                if (try g.genPathCall(mem.member, e.args)) return;
            }
        }
        // Http static calls: Http.get/post/json/postJson/serve.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Http")) {
                if (try g.genHttpCall(mem.member, e.args)) return;
            }
        }
        // Csv static calls: Csv.parse(text), Csv.parseFile(path).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Csv")) {
                if (try g.genCsvCall(mem.member, e.args)) return;
            }
        }
        // DateTime static calls: DateTime.now(), DateTime.fromEpoch(ms), DateTime.of(y,m,d,...).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "DateTime")) {
                if (try g.genDateTimeCall(mem.member, e.args)) return;
            }
        }
        // Reflect static calls: Reflect.className(obj), Reflect.fieldNames(obj), Reflect.fieldTypes(obj).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Reflect")) {
                if (try g.genReflectCall(mem.member, e.args)) return;
            }
        }
        // Hash static calls: Hash.sha256(data), Hash.sha512(data), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Hash")) {
                if (try g.genHashCall(mem.member, e.args)) return;
            }
        }
        // Random static calls: Random.int(min, max), Random.float(), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Random")) {
                if (try g.genRandomCall(mem.member, e.args)) return;
            }
        }
        // Arg static calls: Arg.parse().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Arg")) {
                if (try g.genArgCall(mem.member, e.args)) return;
            }
        }
        // Terminal static calls: Terminal.print(msg, color), Terminal.width(), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Terminal")) {
                if (try g.genTerminalCall(mem.member, e.args)) return;
            }
        }
        // Log static calls: Log.info(msg), Log.warn(msg), Log.setLevel("warn"), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Log")) {
                if (try g.genLogCall(mem.member, e.args)) return;
            }
        }
        // Uri static calls: Uri.parse(url).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Uri")) {
                if (try g.genUriCall(mem.member, e.args)) return;
            }
        }
        // Compress static calls: Compress.gzip(data), Compress.gunzip(data).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Compress")) {
                if (try g.genCompressCall(mem.member, e.args)) return;
            }
        }
        // Mime static calls: Mime.fromExt(ext), Mime.toExt(mime).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Mime")) {
                if (try g.genMimeCall(mem.member, e.args)) return;
            }
        }
        // Timer static calls: Timer.start().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Timer")) {
                if (try g.genTimerCall(mem.member, e.args)) return;
            }
        }
        // Json static calls: Json.parse(s), Json.stringify(v), Json.object(), Json.array().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Json")) {
                if (try g.genJsonCall(mem.member, e.args)) return;
            }
        }
        // HttpResponse factory: HttpResponse.ok(body), HttpResponse.notFound(body), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "HttpResponse")) {
                if (try g.genHttpResponseFactory(mem.member, e.args)) return;
            }
        }
        // Tcp static call: Tcp.connect(host, port).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Tcp")) {
                if (try g.genTcpCall(mem.member, e.args)) return;
            }
        }
        // Udp static call: Udp.socket().
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Udp")) {
                if (try g.genUdpCall(mem.member, e.args)) return;
            }
        }
        // Net static call: Net.resolve(host).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Net")) {
                if (try g.genNetCall(mem.member, e.args)) return;
            }
        }
        // Math static call: Math.sin(x), Math.pow(x,y), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Math")) {
                if (try g.genMathCall(mem.member, e.args)) return;
            }
        }
        // Regex static call: Regex.compile(pattern).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Regex")) {
                if (try g.genRegexCall(mem.member, e.args)) return;
            }
        }
        // Gui static call: Gui.run(title, w, h, callback).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Gui")) {
                if (try g.genGuiCall(mem.member, e.args)) return;
            }
        }
        // sys static calls: sys.args(), sys.exit(n), sys.err("msg"), etc.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "sys")) {
                if (try g.genSysCall(mem.member, e.args)) return;
            }
        }
        // Shell static calls: Shell.run(cmd).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Shell")) {
                if (try g.genShellCall(mem.member, e.args)) return;
            }
        }
        // toString() on any value — use TC-inferred type for format specifier.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (std.mem.eql(u8, mem.member, "toString")) {
                const obj_tc = if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
                // char.toString() — encode the Unicode codepoint as UTF-8 via {u}.
                if (obj_tc == .char) {
                    if (try g.genCharMethod(mem.object, "toString", e.args)) return;
                }
                const fmt: []const u8 = switch (obj_tc) {
                    .float => "{d}",
                    else   => "{}",
                };
                try g.w.print("(std.fmt.allocPrint(_allocator, \"{s}\", .{{", .{fmt});
                try g.genExpr(mem.object);
                try g.w.writeAll("}) catch unreachable)");
                return;
            }
        }
        // Extension method call: obj.method(args) where "TypeName.method" is in ext_methods.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (g.tc) |tc| {
                const obj_type = tc.expr_types.get(mem.object) orelse .unknown;
                const tname_opt: ?[]const u8 = switch (obj_type) {
                    .string         => "String",
                    .int            => "int",
                    .uint           => "uint",
                    .float          => "float",
                    .bool           => "bool",
                    .char           => "char",
                    .string_builder => "StringBuilder",
                    .named          => |sym| switch (sym.decl) {
                        .class     => |c| c.name,
                        .struct_   => |s| s.name,
                        .interface => |i| i.name,
                        else       => null,
                    },
                    else => null,
                };
                if (tname_opt) |tname| {
                    const key = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{tname, mem.member});
                    defer g.alloc.free(key);
                    if (tc.ext_methods.get(key) != null) {
                        try g.w.print("_ext_{s}_{s}(", .{tname, mem.member});
                        try g.genExpr(mem.object);
                        for (e.args) |a| {
                            try g.w.writeAll(", ");
                            try g.genExpr(a.value);
                        }
                        try g.w.writeAll(")");
                        return;
                    }
                }
            }
        }
        // Stdlib method call: obj.method(args) where obj has a known stdlib type.
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (g.getExprDeclaredType(mem.object)) |tr| {
                if (try g.genStdlibMethod(mem.object, tr, mem.member, e.args)) return;
            } else {
                // No declared type annotation — fall back on TC-inferred type.
                // This handles string literals ("hello".method()) and
                // unannotated vars inferred from sys.args() etc.
                // Skip fallback for .named types (user-defined class methods go
                // through genExpr → user struct method call below).
                const tc_type: TypeChecker.Type = blk: {
                    // Inside extension method bodies, `this` has a known self type.
                    if (mem.object.* == .this) {
                        if (g.ext_self_type) |est| break :blk est;
                    }
                    break :blk if (g.tc) |tc| tc.expr_types.get(mem.object) orelse .unknown else .unknown;
                };
                switch (tc_type) {
                    .string     => if (try g.genStringMethod(mem.object, mem.member, e.args)) return,
                    .char       => if (try g.genCharMethod(mem.object, mem.member, e.args)) return,
                    .tcp_conn      => if (try g.genTcpMethod(mem.object, mem.member, e.args)) return,
                    .udp_socket    => if (try g.genUdpMethod(mem.object, mem.member, e.args)) return,
                    .regex         => if (try g.genRegexMethod(mem.object, mem.member, e.args)) return,
                    .gui_context   => if (try g.genGuiWidgetMethod(mem.object, mem.member, e.args)) return,
                    .str_slice     => if (try g.genStrSliceMethod(mem.object, mem.member, e.args)) return,
                    .json_value    => if (try g.genJsonMethod(mem.object, mem.member, e.args)) return,
                    .date_time     => if (try g.genDateTimeMethod(mem.object, mem.member, e.args)) return,
                    .http_response => if (try g.genHttpResponseMethod(mem.object, mem.member, e.args)) return,
                    .csv_table     => if (try g.genCsvMethod(mem.object, mem.member, e.args)) return,
                    .csv_writer    => if (try g.genCsvWriterMethod(mem.object, mem.member, e.args)) return,
                    .csv_row       => if (try g.genListMethod(mem.object, mem.member, e.args)) return,
                    .arg_result    => if (try g.genArgResultMethod(mem.object, mem.member, e.args)) return,
                    .timer_handle  => if (try g.genTimerResultMethod(mem.object, mem.member, e.args)) return,
                    .unknown       => if (try g.genListMethod(mem.object, mem.member, e.args)) return,
                    else           => {},
                }
            }
        }
        // Closure vars (lambdas with capture blocks) are struct instances;
        // call them via .call() instead of direct invocation.
        if (e.callee.* == .ident) {
            if (g.closure_vars) |cv| {
                if (cv.contains(e.callee.ident.name)) {
                    try g.w.writeAll(e.callee.ident.name);
                    try g.w.writeAll(".call(");
                    try g.genArgs(null, e.args);
                    try g.w.writeAll(")");
                    return;
                }
            }
        }
        // Bare method call inside an instance method body: `method(args)` → `self.method(args)`.
        // Field idents already get `self.` in genIdent; methods need it here at the call site.
        if (e.callee.* == .ident and g.in_method and g.owner.len > 0) {
            const ident = &e.callee.ident;
            if (g.resolve.exprs.get(ident)) |sym| {
                if (sym.kind == .method) {
                    const is_shared: bool = switch (sym.decl) {
                        .method => |m| m.mods.shared,
                        else    => false,
                    };
                    // Top-level functions have no owner class — call directly.
                    const is_top_level: bool = switch (sym.decl) {
                        .method => |m| m.is_top_level,
                        else    => false,
                    };
                    const bare_params: ?[]const Ast.Param = switch (sym.decl) {
                        .method => |m| m.params,
                        else    => null,
                    };
                    // Auto-propagate errors: when calling a `throws` method from
                    // inside a `throws` method (and not inside a try/catch block),
                    // emit `try` so Zig doesn't reject the ignored error union.
                    const callee_throws: bool = switch (sym.decl) {
                        .method => |m| m.throws or bodyHasRaise(m.body orelse &.{}, g.tc),
                        else    => false,
                    };
                    if (callee_throws and g.current_method_throws and g.try_block_label == null and !g.suppress_auto_try) {
                        try g.w.writeAll("try ");
                    }
                    if (is_top_level) {
                        try g.w.writeAll(ident.name);
                    } else if (is_shared) {
                        try g.w.print("{s}.{s}", .{ g.owner, ident.name });
                    } else {
                        try g.w.print("self.{s}", .{ident.name});
                    }
                    try g.w.writeAll("(");
                    try g.genArgs(bare_params, e.args);
                    try g.w.writeAll(")");
                    return;
                }
            }
        }
        // Cross-module constructor call: `Mod.TypeName(args)` → `Mod.TypeName.init(args)`
        // Detected when the callee is `member_access(module_ident, "TypeName")` and the
        // module's interface exports `TypeName` as a type (not a method).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident) {
                const mod_name = mem.object.ident.name;
                if (g.imported_modules) |imp| {
                    if (imp.get(mod_name)) |iface| {
                        if (iface.types.contains(mem.member)) {
                            // It's a cross-module type constructor.
                            try g.w.print("{s}.{s}.init(", .{ mod_name, mem.member });
                            try g.genArgs(null, e.args);
                            try g.w.writeAll(")");
                            return;
                        }
                    }
                }
            }
        }
        // Cross-module `throws` method call: emit `try` when the callee's module
        // interface records the method as throwing and we're in a throws context.
        if (g.current_method_throws and g.try_block_label == null and !g.suppress_auto_try and
            e.callee.* == .member and e.callee.member.object.* == .ident)
        {
            const mod_name = e.callee.member.object.ident.name;
            const method_name = e.callee.member.member;
            if (g.imported_modules) |imp| {
                if (imp.get(mod_name)) |iface| {
                    if (iface.throws_methods.contains(method_name)) {
                        try g.w.writeAll("try ");
                    }
                }
            }
        }
        // Self method call via `.method()` syntax: callee is `this.method_name`.
        // The resolver doesn't store idents for member-access callees, so we walk
        // the owner class/struct members to check if the called method is `throws`.
        // Only emit `try ` prefix when we're in a throws method outside any try block.
        // Inside a try/catch block, `genStmt` handles the catch-and-redirect suffix
        // (see the `exprCallIsThrows` check there, which now covers `this.method()` too).
        if (!g.suppress_auto_try and g.current_method_throws and g.try_block_label == null and
            e.callee.* == .member and e.callee.member.object.* == .this)
        {
            const method_name = e.callee.member.member;
            const callee_throws = for (g.owner_members) |decl| {
                if (decl == .method) {
                    const m = decl.method;
                    if (std.mem.eql(u8, m.name, method_name)) {
                        break m.throws or bodyHasRaise(m.body orelse &.{}, g.tc);
                    }
                }
            } else false;
            if (callee_throws) try g.w.writeAll("try ");
        }
        try g.genExpr(e.callee);
        try g.w.writeAll("(");
        try g.genArgs(g.lookupParams(e), e.args);
        try g.w.writeAll(")");
    }

    fn genBinary(g: Generator, e: *Ast.ExprBinary) anyerror!void {
        switch (e.op) {
            .div => {
                // Float division uses `/`; integer division uses @divTrunc.
                const is_float = if (g.tc) |tc| blk: {
                    const t = tc.expr_types.get(e.left) orelse .unknown;
                    break :blk t.isFloatFamily();
                } else false;
                if (is_float) {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" / ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                } else {
                    try g.w.writeAll("@divTrunc(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            .add => {
                // str + str → string concatenation via _str_concat; otherwise numeric add.
                const left_is_str = if (g.tc) |tc|
                    (tc.expr_types.get(e.left) orelse .unknown) == .string
                else false;
                if (left_is_str) {
                    try g.w.writeAll("_str_concat(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(", _allocator)");
                } else {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" + ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            .int_div => {
                try g.w.writeAll("@divTrunc(");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .pow => {
                try g.w.writeAll("std.math.pow(f64, ");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .mod => {
                // Zig's `%` operator on signed integers requires explicit @rem or @mod.
                // Use @mod (mathematical modulo, result has sign of divisor) which matches
                // Zebra's `%` semantics and works for both signed and float types.
                try g.w.writeAll("@mod(");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .dotdot => {
                try g.genExpr(e.left);
                try g.w.writeAll("..");
                try g.genExpr(e.right);
            },
            .eq, .ne => {
                // For string == / != use std.mem.eql rather than the raw == operator,
                // which Zig does not support on slices.
                // Exception: never use std.mem.eql when one side is nil (null) —
                // that is always a raw null comparison (e.g., optional != nil).
                const either_nil = (e.left.* == .nil or e.right.* == .nil);
                const left_is_str = blk: {
                    if (either_nil) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.left) orelse .unknown;
                        break :blk t == .string;
                    }
                    break :blk false;
                };
                // If the left side is unknown but the right side is a known string
                // (e.g. a string literal), use std.mem.eql to avoid Zig slice == error.
                const right_is_str = blk: {
                    if (either_nil or left_is_str) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.right) orelse .unknown;
                        break :blk t == .string;
                    }
                    break :blk false;
                };
                // For user-defined union == / != use std.meta.eql, which Zig requires
                // instead of the raw == operator (tagged unions are not comparable with ==).
                const left_is_union = blk: {
                    if (either_nil or left_is_str or right_is_str) break :blk false;
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.left) orelse .unknown;
                        break :blk t == .named and t.named.kind == .union_;
                    }
                    break :blk false;
                };
                if (left_is_str or right_is_str) {
                    if (e.op == .ne) try g.w.writeAll("!");
                    try g.w.writeAll("std.mem.eql(u8, ");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                } else if (left_is_union) {
                    if (e.op == .ne) try g.w.writeAll("!");
                    try g.w.writeAll("std.meta.eql(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                } else {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" ");
                    try g.w.writeAll(binaryOpStr(e.op));
                    try g.w.writeAll(" ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            .lt, .le, .gt, .ge => {
                // Use comptime-polymorphic helpers that handle both strings and numerics.
                const helper: []const u8 = switch (e.op) {
                    .lt => "_zebra_lt",
                    .le => "_zebra_le",
                    .gt => "_zebra_gt",
                    .ge => "_zebra_ge",
                    else => unreachable,
                };
                try g.w.writeAll(helper);
                try g.w.writeAll("(");
                try g.genExpr(e.left);
                try g.w.writeAll(", ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
            .in_ => {
                try g.w.writeAll("_zebra_in(");
                try g.genExpr(e.left);   // item (needle)
                try g.w.writeAll(", ");
                try g.genExpr(e.right);  // container (haystack)
                try g.w.writeAll(")");
            },
            .mul => {
                // str * int → string repetition; otherwise numeric multiply.
                const left_is_str = if (g.tc) |tc|
                    (tc.expr_types.get(e.left) orelse .unknown) == .string
                else false;
                if (left_is_str) {
                    try g.w.writeAll("_str_repeat(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(", ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(", _allocator)");
                } else {
                    try g.w.writeAll("(");
                    try g.genExpr(e.left);
                    try g.w.writeAll(" * ");
                    try g.genExpr(e.right);
                    try g.w.writeAll(")");
                }
            },
            else => {
                try g.w.writeAll("(");
                try g.genExpr(e.left);
                try g.w.writeAll(" ");
                try g.w.writeAll(binaryOpStr(e.op));
                try g.w.writeAll(" ");
                try g.genExpr(e.right);
                try g.w.writeAll(")");
            },
        }
    }

    fn genUnary(g: Generator, e: *Ast.ExprUnary) anyerror!void {
        switch (e.op) {
            .neg     => { try g.w.writeAll("(-"); try g.genExpr(e.operand); try g.w.writeAll(")"); },
            .not_    => { try g.w.writeAll("(!"); try g.genExpr(e.operand); try g.w.writeAll(")"); },
            .bit_not => { try g.w.writeAll("(~"); try g.genExpr(e.operand); try g.w.writeAll(")"); },
            .old     => try g.genExpr(e.operand), // contract pre-value → pass through
        }
    }

    fn genStringLit(g: Generator, e: Ast.ExprStringLit) anyerror!void {
        switch (e.kind) {
            .plain => {
                // Triple-quoted doc string """...""" (single-line or multiline).
                if (e.text.len >= 6 and e.text[0] == '"' and e.text[1] == '"' and e.text[2] == '"') {
                    // Strip opening and closing """ delimiters.
                    // For multiline, the content includes embedded newlines.
                    const inner = e.text[3 .. e.text.len - 3];
                    // Strip leading newline (the one right after opening """).
                    const after_lead = if (inner.len > 0 and inner[0] == '\n') inner[1..] else inner;
                    // Strip trailing whitespace-only tail (indentation of closing """).
                    var trim_end = after_lead.len;
                    while (trim_end > 0 and
                           (after_lead[trim_end - 1] == ' ' or after_lead[trim_end - 1] == '\t'))
                        : (trim_end -= 1) {}
                    const content = after_lead[0..trim_end];
                    try g.w.writeByte('"');
                    for (content) |c| switch (c) {
                        '"'  => try g.w.writeAll("\\\""),
                        '\n' => try g.w.writeAll("\\n"),
                        '\r' => try g.w.writeAll("\\r"),
                        '\t' => try g.w.writeAll("\\t"),
                        else => try g.w.writeByte(c),
                    };
                    try g.w.writeByte('"');
                    return;
                }
                // If the Zebra source used single-quotes, re-emit as double-quoted Zig string.
                // Zig only allows single-quotes for character literals (single codepoint).
                if (e.text.len >= 2 and e.text[0] == '\'') {
                    const inner = e.text[1 .. e.text.len - 1]; // strip outer single quotes
                    try g.w.writeByte('"');
                    for (inner) |c| switch (c) {
                        '"'  => try g.w.writeAll("\\\""),
                        '\n' => try g.w.writeAll("\\n"),
                        '\r' => try g.w.writeAll("\\r"),
                        '\t' => try g.w.writeAll("\\t"),
                        else => try g.w.writeByte(c),
                    };
                    try g.w.writeByte('"');
                } else {
                    try g.w.writeAll(e.text);
                }
            },
            .raw   => {
                // r"..." / r'...' — backslashes are literal, not escape sequences.
                // e.text is the full source token including the r prefix and quotes.
                // Emit as a Zig double-quoted string with backslashes doubled.
                const content = e.text[2 .. e.text.len - 1]; // strip r, open-quote, close-quote
                try g.w.writeByte('"');
                for (content) |c| switch (c) {
                    '\\' => try g.w.writeAll("\\\\"),
                    '"'  => try g.w.writeAll("\\\""),
                    '\n' => try g.w.writeAll("\\n"),
                    '\r' => try g.w.writeAll("\\r"),
                    '\t' => try g.w.writeAll("\\t"),
                    else => try g.w.writeByte(c),
                };
                try g.w.writeByte('"');
            },
            .nosub => {
                // ns"..." → strip 'ns' prefix.
                try g.w.writeAll(e.text[2..]);
            },
            .zig => {
                // zig"..." → strip 'zig' prefix and surrounding quotes; emit inner content.
                if (e.text.len >= 5) try g.w.writeAll(e.text[4 .. e.text.len - 1]);
            },
        }
    }

    /// Emit `try std.fmt.allocPrint(_allocator, "fmt", .{args...})`.
    ///
    /// Format string construction rules:
    ///   - literal parts: `{` → `{{`, `}` → `}}`, rest verbatim
    ///   - expr parts: `{s}` / `{}` / `{u}` / `{any}` based on type; or `{fmt}`
    ///     if a `.format` part immediately follows
    fn genStringInterp(g: Generator, e: Ast.ExprStringInterp) anyerror!void {
        // ── Build format string ──────────────────────────────────────────────
        var fmt_buf = std.ArrayList(u8){};
        defer fmt_buf.deinit(g.alloc);

        // Per-arg unsigned cast type (null = no cast needed).
        // Needed when a bit-repr spec (x/X/o/b) is applied to a signed integer:
        // Zig prepends '+' for positive signed ints, which is wrong for hex dumps.
        var cast_types = std.ArrayList(?[]const u8){};
        defer cast_types.deinit(g.alloc);

        var i: usize = 0;
        while (i < e.parts.len) : (i += 1) {
            switch (e.parts[i]) {
                .literal => |lit| {
                    // Escape `{` and `}` so they don't confuse std.fmt.
                    for (lit) |c| {
                        if (c == '{' or c == '}') {
                            try fmt_buf.writer(g.alloc).writeByte(c);
                            try fmt_buf.writer(g.alloc).writeByte(c);
                        } else {
                            try fmt_buf.writer(g.alloc).writeByte(c);
                        }
                    }
                },
                .expr => |ex| {
                    // Check if next part is a format spec.
                    const has_fmt = (i + 1 < e.parts.len) and
                        switch (e.parts[i + 1]) { .format => true, else => false };
                    if (has_fmt) {
                        const raw_spec = switch (e.parts[i + 1]) { .format => |s| s, else => unreachable };
                        const ex_type = if (g.tc) |tc| tc.expr_types.get(ex) orelse .unknown else .unknown;
                        try fmt_buf.writer(g.alloc).writeByte('{');
                        try writeZigFmtSpec(fmt_buf.writer(g.alloc), raw_spec, ex_type);
                        try fmt_buf.writer(g.alloc).writeByte('}');
                        try cast_types.append(g.alloc, castTypeForBitSpec(raw_spec, ex_type));
                        i += 1; // skip the consumed format part
                    } else {
                        const spec = printFmt(g.tc, g.catch_var, ex);
                        try fmt_buf.writer(g.alloc).writeAll(spec);
                        try cast_types.append(g.alloc, null);
                    }
                },
                .format => unreachable, // consumed above
            }
        }

        // ── Emit call ────────────────────────────────────────────────────────
        try g.w.writeAll("(std.fmt.allocPrint(_allocator, \"");
        // Write the format string with escaped backslashes and double-quotes.
        for (fmt_buf.items) |c| {
            if (c == '"')  { try g.w.writeAll("\\\""); }
            else if (c == '\\') { try g.w.writeAll("\\\\"); }
            else try g.w.writeByte(c);
        }
        try g.w.writeAll("\", .{");

        // Emit the expression arguments (only .expr parts).
        var first = true;
        var arg_idx: usize = 0;
        for (e.parts) |part| {
            switch (part) {
                .expr => |ex| {
                    if (!first) try g.w.writeAll(", ");
                    first = false;
                    const cast = if (arg_idx < cast_types.items.len) cast_types.items[arg_idx] else null;
                    if (cast) |ut| {
                        try g.w.print("@as({s}, @bitCast(", .{ut});
                        try g.genExpr(ex);
                        try g.w.writeAll("))");
                    } else {
                        try g.genExpr(ex);
                    }
                    arg_idx += 1;
                },
                else => {},
            }
        }
        try g.w.writeAll("}) catch @panic(\"OOM\"))");
    }

    fn genZigLit(g: Generator, e: Ast.ExprZigLit) anyerror!void {
        // e.text is "zig\"...\"" or "zig'...'" (raw source).
        // Layout: z i g <quote-char> <content...> <quote-char>
        //         0 1 2  3            4..len-2      len-1
        if (e.text.len >= 5) try g.w.writeAll(e.text[4 .. e.text.len - 1]);
    }

    fn genLambda(g: Generator, e: *Ast.ExprLambda) anyerror!void {
        // Emit as an anonymous struct with a `call` method — the standard Zig
        // idiom for lambdas.
        //
        // Without capture:
        //   struct { fn call(params) RetT { body } }.call
        //
        // With capture (explicit `capture` block):
        //   (struct { field1: T1, field2: T2, ...,
        //             fn call(self: *@This(), params) RetT { body } }
        //   { .field1 = init1, .field2 = init2, ... }).call

        const has_capture = e.capture.len > 0;

        if (has_capture) try g.w.writeAll("(");
        try g.w.writeAll("struct {");

        // Capture fields
        if (has_capture) {
            try g.w.writeAll("\n");
            const fg = g.indented();
            for (e.capture) |cv| {
                try fg.writeIndent();
                try fg.w.writeAll(cv.name);
                try fg.w.writeAll(": ");
                if (cv.type_) |tr| {
                    try fg.genType(tr);
                } else if (cv.init) |init| {
                    try fg.w.writeAll("@TypeOf(");
                    try fg.genExpr(init);
                    try fg.w.writeAll(")");
                } else {
                    try fg.w.writeAll("anytype");
                }
                try fg.w.writeAll(",\n");
            }
            try g.writeIndent();
        }

        // call method
        try g.w.writeAll(" fn call(");
        var first = true;
        if (has_capture) {
            try g.w.writeAll("self: *@This()");
            first = false;
        }
        for (e.params) |p| {
            if (!first) try g.w.writeAll(", ");
            first = false;
            try g.w.writeAll(p.name);
            try g.w.writeAll(": ");
            if (p.type_) |tr| try g.genType(tr) else try g.w.writeAll("anytype");
        }
        try g.w.writeAll(") ");
        // Return type: use declared type if present, else infer:
        //   - Expression body → @TypeOf(expr) (valid in Zig when params are typed)
        //   - Statement body  → walk body for first `return expr`; use TC type or void
        if (e.return_type) |rt| {
            try g.genType(rt);
        } else {
            switch (e.body) {
                .expr => |ex| {
                    try g.w.writeAll("@TypeOf(");
                    try g.genExpr(ex);
                    try g.w.writeAll(")");
                },
                .stmts => |ss| {
                    // Find first `return expr` and query TypeChecker for its type.
                    const inferred = blk: {
                        if (g.tc) |tc| {
                            for (ss) |stmt| {
                                if (stmt == .return_ and stmt.return_.value != null) {
                                    const t = tc.expr_types.get(stmt.return_.value.?) orelse break :blk TypeChecker.Type.void_;
                                    break :blk t;
                                }
                            }
                        }
                        break :blk TypeChecker.Type.void_;
                    };
                    try g.w.writeAll(zigTypeNameOf(inferred));
                },
            }
        }
        try g.w.writeAll(" {");
        // Build capture_fields list so idents inside the body emit `self.name`
        var cap_names = std.ArrayList([]const u8){};
        defer cap_names.deinit(g.alloc);
        for (e.capture) |cv| try cap_names.append(g.alloc, cv.name);
        const lg = g.asMethod().withCaptureFields(cap_names.items);
        switch (e.body) {
            .expr  => |ex| {
                try lg.w.writeAll(" return ");
                try lg.genExpr(ex);
                try lg.w.writeAll(";");
            },
            .stmts => |ss| {
                var ret_set_lambda = try analyzeEscapes(ss, g.alloc);
                defer ret_set_lambda.deinit();
                try lg.w.writeAll("\n");
                try lg.indented().withReturnedNames(&ret_set_lambda).genStmts(ss);
                try lg.writeIndent();
            },
        }
        try g.w.writeAll(" }");
        try g.w.writeAll(" }");

        // Capture initialiser
        if (has_capture) {
            try g.w.writeAll("{ ");
            for (e.capture) |cv| {
                try g.w.writeAll(".");
                try g.w.writeAll(cv.name);
                try g.w.writeAll(" = ");
                if (cv.init) |init| try g.genExpr(init) else try g.w.writeAll("undefined");
                try g.w.writeAll(", ");
            }
            try g.w.writeAll("}");
            try g.w.writeAll(").call");
        } else {
            try g.w.writeAll(".call");
        }
    }

    // ── Type reference ────────────────────────────────────────────────────────

    fn genType(g: Generator, tr: Ast.TypeRef) anyerror!void {
        switch (tr) {
            .named       => |n| {
                // Try static mapping first; fall back to dynamic sized-type emission
                // for arbitrary-width types like int5, uint3, float7.
                const zig = zigTypeName(n.name);
                if (!std.mem.eql(u8, zig, n.name)) {
                    try g.w.writeAll(zig);
                } else if (!try Builtins.writeZigSizedType(g.w, n.name)) {
                    try g.w.writeAll(zig);
                }
            },
            .nilable     => |inner| {
                // Self-referential nilable field (e.g., `var next as Node?` inside `class Node`):
                // Zig requires a pointer to break the infinite-size cycle → emit `?*ClassName`.
                const inner_is_self_ref = inner.* == .named and
                    g.owner.len > 0 and
                    std.mem.eql(u8, inner.named.name, g.owner);
                if (inner_is_self_ref) {
                    try g.w.writeAll("?*");
                    try g.w.writeAll(inner.named.name);
                } else {
                    try g.w.writeAll("?");
                    try g.genType(inner.*);
                }
            },
            .stream      => |inner| {
                // Zig has no built-in stream/generator type.
                try g.w.writeAll("anytype /* stream: ");
                try g.genType(inner.*);
                try g.w.writeAll(" */");
            },
            .error_union => |inner| {
                try g.w.writeAll("anyerror!");
                try g.genType(inner.*);
            },
            .ref_to      => |inner| {
                // ^T — heap-indirection pointer; emits `*T` in Zig to break recursive struct size.
                // Special case: ^T? (ref_to wrapping nilable) → `?*T` rather than `*?T`.
                // This is the natural form for optional recursive references (linked list next, tree children).
                if (inner.* == .nilable) {
                    try g.w.writeAll("?*");
                    try g.genType(inner.nilable.*);
                } else {
                    try g.w.writeAll("*");
                    try g.genType(inner.*);
                }
            },
            .generic     => |gtr| {
                // Result(T, E) → _Result(T, E)
                if (std.mem.eql(u8, gtr.name, "Result")) {
                    try g.w.writeAll("_Result(");
                    if (gtr.args.len >= 1) try g.genType(gtr.args[0]) else try g.w.writeAll("void");
                    try g.w.writeAll(", ");
                    if (gtr.args.len >= 2) try g.genType(gtr.args[1]) else try g.w.writeAll("[]const u8");
                    try g.w.writeAll(")");
                    return;
                }
                // HashMap(K, V): use StringHashMap for string keys, AutoHashMap otherwise.
                if (std.mem.eql(u8, gtr.name, "HashMap")) {
                    const key_is_str = gtr.args.len >= 1 and isStringTypeRef(gtr.args[0]);
                    if (key_is_str) {
                        try g.w.writeAll("std.StringHashMap(");
                        if (gtr.args.len >= 2) try g.genType(gtr.args[1]) else try g.w.writeAll("anytype");
                        try g.w.writeAll(")");
                    } else {
                        try g.w.writeAll("std.AutoHashMap(");
                        for (gtr.args, 0..) |arg, i| {
                            if (i > 0) try g.w.writeAll(", ");
                            try g.genType(arg);
                        }
                        try g.w.writeAll(")");
                    }
                    return;
                }
                try g.w.writeAll(zigGenericName(gtr.name));
                if (gtr.args.len > 0) {
                    try g.w.writeAll("(");
                    for (gtr.args, 0..) |arg, i| {
                        if (i > 0) try g.w.writeAll(", ");
                        try g.genType(arg);
                    }
                    try g.w.writeAll(")");
                }
            },
            .void_       => try g.w.writeAll("void"),
            .same        => try g.w.writeAll(if (g.owner.len > 0) g.owner else "@This()"),
            .tuple       => |ttr| {
                // (T1, T2, …) → struct { T1, T2, … }  (Zig anonymous struct / tuple)
                try g.w.writeAll("struct { ");
                for (ttr.elems, 0..) |el, i| {
                    if (i > 0) try g.w.writeAll(", ");
                    try g.genType(el);
                }
                try g.w.writeAll(" }");
            },
        }
    }
};

// ── Type annotation helper ────────────────────────────────────────────────────

/// Map a TypeChecker.Type to the Zig type annotation string that must appear
/// when a `var` local is initialised with that type.  Returns null when Zig's
/// own inference is correct (named types, stdlib opaques from constructor
/// calls, etc.) so the caller can omit the annotation entirely.
///
/// All non-null results are heap-allocated via `alloc` and must be freed by
/// the caller (typically with `defer alloc.free(ann)`).
fn tcTypeAnnotation(t: TypeChecker.Type, alloc: Allocator) !?[]const u8 {
    return switch (t) {
        // Primitives where Zig's inference would produce comptime_int / comptime_float
        // or a literal array type instead of a slice.
        .int        => try alloc.dupe(u8, "i64"),
        .uint       => try alloc.dupe(u8, "u64"),
        .float      => try alloc.dupe(u8, "f64"),
        .bool       => try alloc.dupe(u8, "bool"),
        .char       => try alloc.dupe(u8, "u21"),
        .string     => try alloc.dupe(u8, "[]const u8"),
        .str_slice  => try alloc.dupe(u8, "[]const []const u8"),
        .void_      => try alloc.dupe(u8, "void"),
        // Sized numerics — bit-width is runtime data so we must allocPrint.
        .int_n   => |w| try std.fmt.allocPrint(alloc, "i{d}", .{w}),
        .uint_n  => |w| try std.fmt.allocPrint(alloc, "u{d}", .{w}),
        .float_n => |w| try std.fmt.allocPrint(alloc, "f{d}", .{w}),
        // Optional wrapper — recurse; propagate null if inner is unresolvable.
        .optional => |inner| blk: {
            const inner_s = try tcTypeAnnotation(inner.*, alloc) orelse break :blk null;
            defer alloc.free(inner_s);
            break :blk try std.fmt.allocPrint(alloc, "?{s}", .{inner_s});
        },
        // Named user types, stdlib opaques, tuples, unknown — Zig infers correctly
        // from constructor calls, so no annotation is needed.
        //
        // GENERIC TYPES (List, HashMap, …): these also fall through here and
        // return null.  That is safe today because every generic-typed local in
        // Zebra requires an explicit `as List(T)` annotation in the source, so
        // `genLocalVar` always takes the `if (n.type_) |tr|` branch and emits
        // `genType(tr)` — it never reaches this function for those vars.
        //
        // If that assumption ever changes (e.g. we add type inference for
        // generics so `var xs = List()` works without an annotation), the
        // generic cases will silently fall through here and produce an
        // unannotated `var xs = ...` — Zig will then reject it with a
        // "variable of type 'std.ArrayList(…)' must be const or comptime"
        // error.  At that point, add explicit `.list`, `.hash_map`, etc. arms
        // to this switch that emit the correct Zig container type.
        else => null,
    };
}

// ── C header generation ───────────────────────────────────────────────────────

/// Emit a C header (`#pragma once` + function declarations) for all
/// `shared def` methods in `module` whose signatures are C-compatible.
/// Call this after `generate()` when in lib mode.
pub fn generateHeader(module: Ast.Module, writer: std.io.AnyWriter) anyerror!void {
    try writer.print(
        \\// Auto-generated by the Zebra compiler.  DO NOT EDIT.
        \\// Source: {s}
        \\#pragma once
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\
        \\
    , .{module.file});

    for (module.decls) |decl| {
        const type_name, const members = switch (decl) {
            .class   => |c| .{ c.name, c.members },
            .struct_ => |s| .{ s.name, s.members },
            else     => continue,
        };
        var any_exported = false;
        for (members) |m| {
            const n = switch (m) { .method => |meth| meth, else => continue };
            if (!Generator.isMethodCExportable(n)) continue;
            if (!any_exported) {
                try writer.print("// {s}\n", .{type_name});
                any_exported = true;
            }
            const ret_c = if (n.return_type) |rt| cTypeName(rt) else "void";
            try writer.print("{s} {s}_{s}(", .{ ret_c, type_name, n.name });
            for (n.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s} {s}", .{ cTypeName(p.type_.?), p.name });
            }
            try writer.writeAll(");\n");
        }
        if (any_exported) try writer.writeAll("\n");
    }
}

fn cTypeName(tr: Ast.TypeRef) []const u8 {
    return switch (tr) {
        .void_  => "void",
        .named  => |n| std.StaticStringMap([]const u8).initComptime(&.{
            .{ "int",     "int64_t"  }, .{ "uint",    "uint64_t" },
            .{ "float",   "double"   }, .{ "bool",    "bool"     },
            .{ "char",    "uint32_t" },
            .{ "int8",    "int8_t"   }, .{ "int16",   "int16_t"  },
            .{ "int32",   "int32_t"  }, .{ "int64",   "int64_t"  },
            .{ "uint8",   "uint8_t"  }, .{ "uint16",  "uint16_t" },
            .{ "uint32",  "uint32_t" }, .{ "uint64",  "uint64_t" },
            .{ "float32", "float"    }, .{ "float64", "double"   },
        }).get(n.name) orelse "/* unsupported */",
        else => "/* unsupported */",
    };
}

// ── Print format specifier ────────────────────────────────────────────────────

/// Choose the Zig format specifier for a single `print` argument based on its
/// inferred type.  Falls back to `{any}` when type information is unavailable.
/// `catch_var` is the current catch-clause binding name (empty if not in a catch);
/// `catch_var.message` is always `[]const u8` so always uses `{s}`.
fn printFmt(tc: ?*const TypeChecker.TypeCheckResult, catch_var: []const u8, expr: *const Ast.Expr) []const u8 {
    // e.message inside a catch block is always []const u8.
    if (catch_var.len > 0 and expr.* == .member) {
        const mem = expr.member;
        if (std.mem.eql(u8, mem.member, "message") and
            mem.object.* == .ident and
            std.mem.eql(u8, mem.object.ident.name, catch_var))
        {
            return "{s}";
        }
    }
    const result = tc orelse return "{any}";
    const t_opt = result.expr_types.get(expr);
    // Fallback for extension method calls: look up return type from ext_methods.
    const t: TypeChecker.Type = t_opt orelse blk: {
        if (expr.* == .call and expr.call.callee.* == .member) {
            const mem = expr.call.callee.member;
            const obj_type = result.expr_types.get(mem.object) orelse .unknown;
            const tname: ?[]const u8 = switch (obj_type) {
                .string         => "String",
                .int            => "int",
                .uint           => "uint",
                .float          => "float",
                .bool           => "bool",
                .char           => "char",
                .string_builder => "StringBuilder",
                .named          => |sym| switch (sym.decl) {
                    .class     => |c| c.name,
                    .struct_   => |s| s.name,
                    .interface => |i| i.name,
                    else       => null,
                },
                else => null,
            };
            if (tname) |tn| {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, mem.member})) |key| {
                    if (result.ext_methods.get(key)) |ext_meth| {
                        if (ext_meth.return_type) |*rt| {
                            // Derive type from return TypeRef
                            const rname = switch (rt.*) {
                                .named => |n| n.name,
                                else   => "",
                            };
                            if (Builtins.isStringTypeName(rname)) break :blk .string;
                            const sk = Builtins.scalarKind(rname);
                            break :blk switch (sk) {
                                .int, .int_n   => .int,
                                .uint, .uint_n => .uint,
                                .float, .float_n => .float,
                                .bool          => .bool,
                                .char          => .char,
                                else           => .unknown,
                            };
                        }
                    }
                } else |_| {}
            }
        }
        break :blk .unknown;
    };
    return switch (t) {
        .string                        => "{s}",
        .int, .uint, .int_n, .uint_n,
        .bool                          => "{}",
        .float, .float_n               => "{d}",
        .char                          => "{u}",
        .void_, .unknown, .named,
        .string_builder,
        .http_request,
        .http_response,
        .tcp_conn,
        .udp_socket,
        .regex,
        .gui_context,
        .shell,
        .file,
        .str_slice,
        .sys_run_result,
        .json_value,
        .json_array,
        .date_time,
        .calendar_view,
        .csv_table,
        .csv_writer,
        .csv_row,
        .arg_result,
        .uri_result,
        .timer_handle,
        .optional,
        .tuple,
        .generic_named,
        .cross_module,
        .fn_ref, .fn_sig               => "{any}",
    };
}

// ── Format spec translation ───────────────────────────────────────────────────

/// Translate a Zebra/Python-style format spec (the text after `:` in `[expr:spec]`,
/// already stripped of the leading `:`) into the Zig format specifier that goes
/// inside `{...}`.  Writes directly to `w`.
///
/// Python mini-language:  `[[fill]align][sign][#][0][width][.prec][type]`
/// Zig format string:      `[type][:[[fill]align][width][.prec]]`
///
/// Examples
///   ""       → ""          (empty — use TC-inferred default; caller adds `{}`)
///   "08x"    → "x:0>8"
///   ">10.2f" → "d:>10.2"
///   "<20s"   → "s:<20"
///   ".2f"    → "d:.2"
///   "^15"    → ":^15"      (no type — Zig uses default, just alignment+width)
///   "_>15"   → ":_>15"
fn writeZigFmtSpec(
    w:       anytype,
    spec:    []const u8,
    tc_type: TypeChecker.Type,
) !void {
    if (spec.len == 0) return;

    const isAlignChar = struct {
        fn f(c: u8) bool { return c == '<' or c == '>' or c == '^'; }
    }.f;

    var i: usize = 0;
    var fill:      ?u8          = null;
    var align_ch:  ?u8          = null;
    var zero_pad               = false;
    var width:     []const u8  = "";
    var precision: []const u8  = "";
    var type_ch:   ?u8         = null;

    // ── Fill + align ────────────────────────────────────────────────────────
    // Pattern: [fill]align  where align ∈ { < > ^ }
    if (i + 1 < spec.len and !isAlignChar(spec[i]) and isAlignChar(spec[i + 1])) {
        fill     = spec[i];
        align_ch = spec[i + 1];
        i += 2;
    } else if (i < spec.len and isAlignChar(spec[i])) {
        align_ch = spec[i];
        i += 1;
    }

    // ── Sign (skip — Zig doesn't support the same sign formatting) ──────────
    if (i < spec.len and (spec[i] == '+' or spec[i] == '-' or spec[i] == ' ')) {
        i += 1;
    }

    // ── Alternate form # (skip) ─────────────────────────────────────────────
    if (i < spec.len and spec[i] == '#') i += 1;

    // ── Zero-pad (implicit fill='0', align='>') ──────────────────────────────
    // Only applies if no explicit fill/align seen yet.
    if (i < spec.len and spec[i] == '0' and align_ch == null) {
        zero_pad = true;
        fill     = '0';
        align_ch = '>';
        i += 1;
    }

    // ── Width ────────────────────────────────────────────────────────────────
    const w_start = i;
    while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {}
    width = spec[w_start..i];

    // ── Grouping option (skip) ───────────────────────────────────────────────
    if (i < spec.len and (spec[i] == '_' or spec[i] == ',')) i += 1;

    // ── Precision ────────────────────────────────────────────────────────────
    if (i < spec.len and spec[i] == '.') {
        const p_start = i;
        i += 1;
        while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {}
        precision = spec[p_start..i];
    }

    // ── Type character ───────────────────────────────────────────────────────
    if (i < spec.len) {
        type_ch = spec[i];
        // (remaining chars ignored)
    }

    // ── Emit Zig specifier ───────────────────────────────────────────────────
    // 1. Type part (before the ':')
    if (type_ch) |tc| {
        switch (tc) {
            's'                => try w.writeByte('s'),
            'c'                => try w.writeByte('c'),
            'u'                => try w.writeByte('u'),
            'd', 'i', 'n'      => try w.writeByte('d'),
            'f', 'g', 'G', '%' => try w.writeByte('d'), // Zig uses 'd' for decimal float
            'e', 'E'           => try w.writeByte('e'),
            'x'                => try w.writeByte('x'),
            'X'                => try w.writeByte('X'),
            'o'                => try w.writeByte('o'),
            'b'                => try w.writeByte('b'),
            else               => try w.writeByte('d'),
        }
    } else {
        // No explicit type: infer from TC type.
        switch (tc_type) {
            .string              => try w.writeByte('s'),
            .float, .float_n     => try w.writeByte('d'),
            .char                => try w.writeByte('u'),
            .int, .uint,
            .int_n, .uint_n      => try w.writeByte('d'),
            else                 => {}, // leave empty — Zig default
        }
    }

    // 2. Format options (after ':')
    const has_opts = fill != null or align_ch != null or
                     width.len > 0 or precision.len > 0 or zero_pad;
    if (has_opts) {
        try w.writeByte(':');
        if (fill)     |f| try w.writeByte(f);
        if (align_ch) |a| try w.writeByte(a);
        try w.writeAll(width);
        try w.writeAll(precision);
    }
}

/// When a bit-repr format spec (x/X/o/b) is applied to a signed integer, Zig's
/// std.fmt prepends a `+` sign for positive values, giving e.g. `+ff` instead
/// of `ff`.  Return the Zig unsigned type name to cast to before formatting, or
/// Map a TypeChecker.Type to its Zig type name string for use in generated code.
/// Used when we need a concrete return type (e.g. block-body lambda return types).
fn zigTypeNameOf(t: TypeChecker.Type) []const u8 {
    return switch (t) {
        .int, .uint     => "i64",
        .float          => "f64",
        .bool           => "bool",
        .char           => "u21",
        .string         => "[]const u8",
        .void_          => "void",
        .int_n   => |b| switch (b) { 8 => "i8", 16 => "i16", 32 => "i32", 64 => "i64", 128 => "i128", else => "i64" },
        .uint_n  => |b| switch (b) { 8 => "u8", 16 => "u16", 32 => "u32", 64 => "u64", 128 => "u128", else => "u64" },
        .float_n => |b| switch (b) { 16 => "f16", 32 => "f32", 64 => "f64", 128 => "f128", else => "f64" },
        else            => "void",
    };
}

/// null if no cast is needed (type is unsigned/float/string, or spec doesn't
/// request a bit representation).
fn castTypeForBitSpec(spec: []const u8, tc_type: TypeChecker.Type) ?[]const u8 {
    if (spec.len == 0) return null;
    // The type character is the last non-digit, non-fill character in the spec;
    // for our purposes it's sufficient to check the final character.
    const last = spec[spec.len - 1];
    if (last != 'x' and last != 'X' and last != 'o' and last != 'b') return null;
    return switch (tc_type) {
        .int        => "u64",
        .int_n => |n| switch (n) {
            8   => "u8",
            16  => "u16",
            32  => "u32",
            64  => "u64",
            128 => "u128",
            else => null,
        },
        else => null,
    };
}

// ── Entry-point detection ─────────────────────────────────────────────────────

/// Search decls (recursing into namespaces) for a class that contains a
/// `shared def main`.  Returns the fully-qualified Zig path (allocated via
/// `alloc`) if found, else null.  Caller must free the returned slice.
/// Find the `shared def main` method in any class/namespace in the module.
/// Returns a pointer to the method declaration (in the arena-owned AST).
fn findMainMethod(decls: []const Ast.Decl) ?*Ast.DeclMethod {
    for (decls) |decl| {
        switch (decl) {
            .class => |c| {
                for (c.members) |m| {
                    if (m == .method and m.method.mods.shared and
                        std.mem.eql(u8, m.method.name, "main"))
                        return m.method;
                }
            },
            .namespace => |ns| {
                if (findMainMethod(ns.decls)) |m| return m;
            },
            else => {},
        }
    }
    return null;
}

fn findMainClass(decls: []const Ast.Decl, alloc: Allocator, prefix: []const u8) anyerror!?[]const u8 {
    for (decls) |decl| {
        switch (decl) {
            .class => |c| {
                for (c.members) |m| {
                    if (m == .method and
                        m.method.mods.shared and
                        std.mem.eql(u8, m.method.name, "main"))
                    {
                        if (prefix.len > 0)
                            return try std.fmt.allocPrint(alloc, "{s}.{s}", .{prefix, c.name});
                        return try alloc.dupe(u8, c.name);
                    }
                }
            },
            .namespace => |ns| {
                // Build the qualified prefix for this namespace level.
                const ns_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(alloc, "{s}.{s}", .{prefix, ns.name})
                else
                    try alloc.dupe(u8, ns.name);
                defer alloc.free(ns_prefix);
                if (try findMainClass(ns.decls, alloc, ns_prefix)) |name| return name;
            },
            else => {},
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn generateSnippet(src: []const u8, alloc: Allocator) anyerror![]u8 {
    const Tokenizer  = @import("Tokenizer.zig");
    const Parser     = @import("Parser.zig");
    const AstBuilder = @import("AstBuilder.zig");
    const Binder     = @import("Binder.zig");

    const tokens = try Tokenizer.tokenize(src, alloc);
    defer alloc.free(tokens);

    var parse_result = try Parser.parse(tokens, alloc);
    defer parse_result.deinit();

    const ok = switch (parse_result) {
        .ok  => |*s| s,
        .err => |e| {
            std.debug.print("parse error at token {}\n", .{e.error_pos});
            return error.ParseFailed;
        },
    };

    var sym_arena = std.heap.ArenaAllocator.init(alloc);
    defer sym_arena.deinit();

    const module = try AstBuilder.build(ok, sym_arena.allocator());
    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc, null);
    defer resolve.deinit();

    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);

    _ = try generate(module, &resolve, null, alloc, out.writer(alloc).any(), .stub, null, false, null);
    return out.toOwnedSlice(alloc);
}

test "codegen: class fields become struct fields" {
    const src =
        \\class Counter
        \\    var count as int
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub const Counter = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "count: i64") != null);
}

test "codegen: method gets self param and field uses self prefix" {
    const src =
        \\class Counter
        \\    var count as int
        \\    def increment
        \\        count = count + 1
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub fn increment(self: *Counter)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "self.count") != null);
}

test "codegen: method params and return type" {
    const src =
        \\class Greeter
        \\    def greet(name as String) as String
        \\        return name
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out,
        "pub fn greet(self: *Greeter, name: []const u8) []const u8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return name;") != null);
}

test "codegen: interface becomes comptime checker" {
    const src =
        \\interface Printable
        \\    def render
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out,
        "pub fn Printable(comptime T: type) void {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@hasDecl(T, \"render\")") != null);
}

test "codegen: enum members" {
    const src =
        \\enum Direction
        \\    North
        \\    South
        \\    East
        \\    West
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pub const Direction = enum {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "North,") != null);
    try testing.expect(std.mem.indexOf(u8, out, "West,") != null);
}

test "codegen: mixin inlined into class, not emitted standalone" {
    // `adds` is part of the class header line, not a body statement.
    const src =
        \\mixin Loggable
        \\    var log_level as int
        \\
        \\class Service adds Loggable
        \\    var name as String
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    // Mixin should NOT appear as a standalone type.
    try testing.expect(std.mem.indexOf(u8, out, "const Loggable") == null);
    // Mixin field should be inlined inside Service.
    try testing.expect(std.mem.indexOf(u8, out, "log_level: i64") != null);
}

test "codegen: nilable type maps to ?T" {
    const src =
        \\class Node
        \\    var next as Node?
        \\
    ;
    const out = try generateSnippet(src, testing.allocator);
    defer testing.allocator.free(out);

    // Self-referential `Node?` must be a pointer-nilable `?*Node` to avoid
    // infinite-size struct in Zig.
    try testing.expect(std.mem.indexOf(u8, out, "next: ?*Node") != null);
}
