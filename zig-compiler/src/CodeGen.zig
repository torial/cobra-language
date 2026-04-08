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
    module:       Ast.Module,
    resolve:      *const Resolver.ResolveResult,
    tc:           ?*const TypeChecker.TypeCheckResult,
    alloc:        Allocator,
    writer:       std.io.AnyWriter,
    gui_backend:  GuiBackend,
    native_uses:  ?*const std.StringHashMap(NativeUse),
    emit_exports: bool,
) anyerror!GenerateResult {
    var mixins = try collectMixins(module, alloc);
    defer mixins.deinit();
    var union_names = try collectUnionNames(module, alloc);
    defer union_names.deinit();

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
        .mutated        = null,
        .closure_vars   = null,
        .capture_fields = &.{},
        .union_names    = &union_names,
        .gui_backend    = gui_backend,
        .uses_gui_ptr   = &uses_gui,
        .native_uses    = native_uses,
        .emit_exports   = emit_exports,
        .has_exports_ptr = &has_exports,
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

// ── Free helper functions ─────────────────────────────────────────────────────

/// Extract the simple name from a TypeRef, or null for compound forms.
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
        // int_div, pow, dotdot handled specially in genBinary.
        .int_div, .pow, .dotdot => unreachable,
    };
}

// ── Body reference analysis ───────────────────────────────────────────────────
//
// Two pre-scans are run on each method body before emitting code:
//
//  1. collectRefs  — which params / self are actually referenced?
//                    Used to emit `_ = param;` only when a param is unused.
//
//  2. scanMutations — which local names appear as assignment targets?
//                    Used to emit `const` vs `var` for local declarations.

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
        .with      => |s| { try refsInExpr(s.target, r, o); try refsInStmts(s.body, r, o); },
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

fn bodyHasRaise(stmts: []const Ast.Stmt) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise   => return true,
            .var_    => |n| { if (n.init) |e| if (exprHasTry(e)) return true; },
            .assign  => |s| { if (exprHasTry(s.value)) return true; },
            .return_ => |s| { if (s.value) |v| if (exprHasTry(v)) return true; },
            .expr    => |e| if (exprHasTry(e)) return true,
            .print   => |s| { for (s.args) |a| if (exprHasTry(a)) return true; },
            .if_     => |s| {
                if (exprHasTry(s.cond)) return true;
                if (bodyHasRaise(s.then_body)) return true;
                for (s.else_ifs) |ei| {
                    if (exprHasTry(ei.cond)) return true;
                    if (bodyHasRaise(ei.body)) return true;
                }
                if (s.else_body) |eb| if (bodyHasRaise(eb)) return true;
            },
            .while_  => |s| { if (exprHasTry(s.cond)) return true; if (bodyHasRaise(s.body)) return true; },
            .for_in  => |s| if (bodyHasRaise(s.body)) return true,
            .for_num => |s| if (bodyHasRaise(s.body)) return true,
            .branch  => |s| {
                for (s.on) |on| if (bodyHasRaise(on.body)) return true;
                if (s.else_) |eb| if (bodyHasRaise(eb)) return true;
            },
            .with    => |s| if (bodyHasRaise(s.body)) return true,
            .defer_  => |s| return bodyHasRaise(&.{s.body}),
            .guard   => |s| { if (exprHasTry(s.cond)) return true; if (bodyHasRaise(s.else_body)) return true; },
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
fn bodyNeedsErrVar(stmts: []const Ast.Stmt) bool {
    for (stmts) |stmt| {
        switch (stmt) {
            .raise   => return true,
            .var_    => |n| { if (n.init) |e| if (exprHasTry(e)) return true; },
            .assign  => |s| { if (exprHasTry(s.value)) return true; },
            .return_ => |s| { if (s.value) |v| if (exprHasTry(v)) return true; },
            .expr    => |e| if (exprHasTry(e)) return true,
            .print   => |s| { for (s.args) |a| if (exprHasTry(a)) return true; },
            .if_     => |s| {
                if (exprHasTry(s.cond)) return true;
                if (bodyNeedsErrVar(s.then_body)) return true;
                for (s.else_ifs) |ei| {
                    if (exprHasTry(ei.cond)) return true;
                    if (bodyNeedsErrVar(ei.body)) return true;
                }
                if (s.else_body) |eb| if (bodyNeedsErrVar(eb)) return true;
            },
            .while_  => |s| { if (exprHasTry(s.cond)) return true; if (bodyNeedsErrVar(s.body)) return true; },
            .for_in  => |s| if (bodyNeedsErrVar(s.body)) return true,
            .for_num => |s| if (bodyNeedsErrVar(s.body)) return true,
            .branch  => |s| {
                for (s.on) |on| if (bodyNeedsErrVar(on.body)) return true;
                if (s.else_) |eb| if (bodyNeedsErrVar(eb)) return true;
            },
            .with    => |s| if (bodyNeedsErrVar(s.body)) return true,
            .defer_  => |s| return bodyNeedsErrVar(&.{s.body}),
            .guard   => |s| { if (exprHasTry(s.cond)) return true; if (bodyNeedsErrVar(s.else_body)) return true; },
            .try_catch => {}, // inner try has its own err variable
            .destruct => {},
            else => {},
        }
    }
    return false;
}

/// Returns true if `e` is a call to a `throws`-annotated method
/// (ClassName.methodName(args) form only).
fn exprCallIsThrows(e: *const Ast.ExprCall, resolve: *const Resolver.ResolveResult) bool {
    if (e.callee.* != .member) return false;
    const mem = e.callee.member;
    if (mem.object.* != .ident) return false;
    const sym = resolve.exprs.get(&mem.object.ident) orelse return false;
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
fn bodyHasThrowsCall(stmts: []const Ast.Stmt, resolve: *const Resolver.ResolveResult) bool {
    for (stmts) |stmt| {
        if (stmt == .expr and stmt.expr.* == .call) {
            if (exprCallIsThrows(stmt.expr.call, resolve)) return true;
        }
    }
    return false;
}

fn exprHasTry(expr: *const Ast.Expr) bool {
    return switch (expr.*) {
        .try_   => true,
        .binary => |e| exprHasTry(e.left) or exprHasTry(e.right),
        .unary  => |e| exprHasTry(e.operand),
        .call   => |e| blk: {
            if (exprHasTry(e.callee)) break :blk true;
            for (e.args) |a| if (exprHasTry(a.value)) break :blk true;
            break :blk false;
        },
        .member    => |e| exprHasTry(e.object),
        .orelse_   => |e| exprHasTry(e.expr) or exprHasTry(e.fallback),
        .catch_    => |e| exprHasTry(e.expr) or exprHasTry(e.fallback),
        .to_non_nil => |e| exprHasTry(e.expr),
        .to_nilable => |e| exprHasTry(e.expr),
        .is_nil    => |e| exprHasTry(e.expr),
        else => false,
    };
}

fn refsInExpr(expr: *const Ast.Expr, r: *const Resolver.ResolveResult, o: *Refs) anyerror!void {
    switch (expr.*) {
        .ident => |*e| {
            if (r.exprs.get(e)) |sym| switch (sym.kind) {
                .var_  => o.uses_self = true,
                .param => try o.param_names.put(e.name, {}),
                else   => {},
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
fn scanReturnedNames(stmts: []const Ast.Stmt, alloc: Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    errdefer set.deinit();
    try scanReturnedNamesInto(stmts, &set);
    return set;
}

fn scanReturnedNamesInto(stmts: []const Ast.Stmt, set: *std.StringHashMap(void)) !void {
    for (stmts) |stmt| {
        switch (stmt) {
            .return_ => |s| if (s.value) |v| collectIdentNames(v, set) catch {},
            .if_     => |s| {
                try scanReturnedNamesInto(s.then_body, set);
                for (s.else_ifs) |ei| try scanReturnedNamesInto(ei.body, set);
                if (s.else_body) |eb| try scanReturnedNamesInto(eb, set);
            },
            .while_  => |s| try scanReturnedNamesInto(s.body, set),
            .for_in  => |s| try scanReturnedNamesInto(s.body, set),
            .for_num => |s| try scanReturnedNamesInto(s.body, set),
            .branch  => |s| {
                for (s.on) |on| try scanReturnedNamesInto(on.body, set);
                if (s.else_) |eb| try scanReturnedNamesInto(eb, set);
            },
            .with    => |s| try scanReturnedNamesInto(s.body, set),
            .try_catch => |s| {
                try scanReturnedNamesInto(s.body, set);
                for (s.clauses) |cl| try scanReturnedNamesInto(cl.body, set);
            },
            .guard => |s| try scanReturnedNamesInto(s.else_body, set),
            else => {},
        }
    }
}

/// Walk expr and record any .ident names into `set` (for return ownership).
fn collectIdentNames(expr: *const Ast.Expr, set: *std.StringHashMap(void)) !void {
    switch (expr.*) {
        .ident => |e| try set.put(e.name, {}),
        .call  => |e| {
            for (e.args) |a| try collectIdentNames(a.value, set);
        },
        else => {},
    }
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
            .try_catch => |s| {
                try scanMutationsInto(s.body, set, tc_opt);
                for (s.clauses) |cl| try scanMutationsInto(cl.body, set, tc_opt);
            },
            .guard    => |s| try scanMutationsInto(s.else_body, set, tc_opt),
            .destruct => |s| try scanMutationsInExpr(s.init, set, tc_opt),
            else      => {},
        }
    }
}

/// Mark any local variable that is used directly as a method-call receiver as
/// "mutated".  Zebra methods always take `self: *Owner`, so even a read-only
/// call through a local requires that local to be declared `var`.
/// Extension methods (from `extend` blocks) are pass-by-value and are NOT mutating.
fn scanMutationsInExpr(
    expr:   *const Ast.Expr,
    set:    *std.StringHashMap(void),
    tc_opt: ?*const TypeChecker.TypeCheckResult,
) anyerror!void {
    switch (expr.*) {
        // obj.method(args) — if obj is a bare identifier, mark it as needing var
        // unless the method is a non-mutating stdlib operation (strings, reads).
        .call => |e| {
            if (e.callee.* == .member) {
                const obj    = e.callee.member.object;
                const method = e.callee.member.member;
                const non_mutating = std.StaticStringMap(void).initComptime(&.{
                    .{ "contains",   {} }, .{ "startsWith", {} }, .{ "endsWith",   {} },
                    .{ "trim",       {} }, .{ "trimLeft",   {} }, .{ "trimRight",  {} },
                    .{ "concat",     {} }, .{ "toInt",      {} }, .{ "toFloat",    {} },
                    .{ "format",     {} }, .{ "at",         {} }, .{ "fetch",      {} },
                    .{ "count",      {} }, .{ "upper",      {} }, .{ "lower",      {} },
                    .{ "indexOf",    {} }, .{ "replace",    {} }, .{ "repeat",     {} },
                    .{ "split",      {} }, .{ "lines",      {} }, .{ "toString",   {} },
                    .{ "padLeft",    {} }, .{ "padRight",   {} }, .{ "center",     {} },
                    .{ "bytes",      {} }, .{ "isEmpty",    {} }, .{ "isAlpha",    {} },
                    .{ "isNumeric",  {} }, .{ "join",       {} }, .{ "reverse",    {} },
                    .{ "toHex",      {} }, .{ "fromHex",    {} },
                    // StringBuilder read-only ops
                    .{ "build",          {} }, .{ "len",            {} },
                    // UTF-8 / Unicode ops
                    .{ "chars",          {} }, .{ "isValidUtf8",    {} },
                    .{ "codePointCount", {} },
                    // Char predicates / transforms
                    .{ "isAlpha",        {} }, .{ "isDigit",        {} },
                    .{ "isWhitespace",   {} }, .{ "isUpper",        {} },
                    .{ "isLower",        {} }, .{ "toUpper",        {} },
                    .{ "toLower",        {} },
                    // TCP / UDP — don't reassign the handle, so the variable stays const
                    .{ "write",          {} }, .{ "read",           {} },
                    .{ "send",           {} }, .{ "recv",           {} },
                    .{ "close",          {} },
                    // Regex — all methods are non-mutating
                    .{ "match",          {} }, .{ "find",           {} },
                    .{ "findAll",        {} }, .{ "replace",        {} },
                });
                // Extension methods are pass-by-value: never require var on the receiver.
                const is_ext_method = blk: {
                    if (tc_opt) |tc| {
                        if (obj.* == .ident) {
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
                                // Build key and check — use a fixed buffer to avoid alloc.
                                var buf: [256]u8 = undefined;
                                if (std.fmt.bufPrint(&buf, "{s}.{s}", .{tn, method})) |key| {
                                    if (tc.ext_methods.get(key) != null) break :blk true;
                                } else |_| {}
                            }
                        }
                    }
                    break :blk false;
                };
                if (!is_ext_method and non_mutating.get(method) == null and obj.* == .ident)
                    try set.put(obj.ident.name, {});
            }
            // Recurse into args.
            for (e.args) |a| try scanMutationsInExpr(a.value, set, tc_opt);
        },
        .binary    => |e| { try scanMutationsInExpr(e.left, set, tc_opt); try scanMutationsInExpr(e.right, set, tc_opt); },
        .unary     => |e| try scanMutationsInExpr(e.operand, set, tc_opt),
        .member    => |e| try scanMutationsInExpr(e.object, set, tc_opt),
        .index     => |e| { try scanMutationsInExpr(e.object, set, tc_opt); try scanMutationsInExpr(e.index, set, tc_opt); },
        .if_expr   => |e| { try scanMutationsInExpr(e.cond, set, tc_opt); try scanMutationsInExpr(e.then_expr, set, tc_opt); try scanMutationsInExpr(e.else_expr, set, tc_opt); },
        .orelse_   => |e| { try scanMutationsInExpr(e.expr, set, tc_opt); try scanMutationsInExpr(e.fallback, set, tc_opt); },
        .catch_    => |e| { try scanMutationsInExpr(e.expr, set, tc_opt); try scanMutationsInExpr(e.fallback, set, tc_opt); },
        .tuple_lit => |e| { for (e.elems) |el| try scanMutationsInExpr(el, set, tc_opt); },
        else       => {},
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
        .while_  => |s| nameUsedInExpr(name, s.cond) or nameUsedInStmts(name, s.body),
        .for_in  => |s| nameUsedInExpr(name, s.iter) or nameUsedInStmts(name, s.body),
        .for_num => |s| nameUsedInExpr(name, s.start) or nameUsedInExpr(name, s.stop) or nameUsedInStmts(name, s.body),
        .guard    => |s| nameUsedInExpr(name, s.cond) or nameUsedInStmts(name, s.else_body),
        .destruct => |s| nameUsedInExpr(name, s.init),
        else      => false,
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

    // ── Context-adjustment helpers ────────────────────────────────────────────

    fn withOwner(g: Generator, new_owner: []const u8) Generator {
        var c = g; c.owner = new_owner; return c;
    }
    fn withExtSelf(g: Generator, t: TypeChecker.Type) Generator {
        var c = g; c.ext_self_type = t; return c;
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
        try g.w.writeAll("const _allocator = _arena.allocator();\n\n");
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
            \\    };
            \\}
            \\
        );
        // ── String padding helpers ──────────────────────────────────────────
        try g.w.writeAll("fn _pad_left(s: []const u8, width: usize, fill: u8, alloc: std.mem.Allocator) []const u8 {\n");
        try g.w.writeAll("    if (s.len >= width) return s;\n");
        try g.w.writeAll("    const buf = alloc.alloc(u8, width) catch @panic(\"OOM\");\n");
        try g.w.writeAll("    @memset(buf[0 .. width - s.len], fill);\n");
        try g.w.writeAll("    @memcpy(buf[width - s.len ..], s);\n");
        try g.w.writeAll("    return buf;\n}\n");
        try g.w.writeAll("fn _pad_right(s: []const u8, width: usize, fill: u8, alloc: std.mem.Allocator) []const u8 {\n");
        try g.w.writeAll("    if (s.len >= width) return s;\n");
        try g.w.writeAll("    const buf = alloc.alloc(u8, width) catch @panic(\"OOM\");\n");
        try g.w.writeAll("    @memcpy(buf[0 .. s.len], s);\n");
        try g.w.writeAll("    @memset(buf[s.len ..], fill);\n");
        try g.w.writeAll("    return buf;\n}\n");
        try g.w.writeAll("fn _pad_center(s: []const u8, width: usize, fill: u8, alloc: std.mem.Allocator) []const u8 {\n");
        try g.w.writeAll("    if (s.len >= width) return s;\n");
        try g.w.writeAll("    const pad = width - s.len;\n");
        try g.w.writeAll("    const lpad = pad / 2;\n");
        try g.w.writeAll("    const buf = alloc.alloc(u8, width) catch @panic(\"OOM\");\n");
        try g.w.writeAll("    @memset(buf[0 .. lpad], fill);\n");
        try g.w.writeAll("    @memcpy(buf[lpad .. lpad + s.len], s);\n");
        try g.w.writeAll("    @memset(buf[lpad + s.len ..], fill);\n");
        try g.w.writeAll("    return buf;\n}\n\n");
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
        // ── HTTP networking helpers ─────────────────────────────────────────
        // HttpResponse text is heap-allocated for program duration (page_allocator avoids GPA leak tracking).
        try g.w.writeAll("const HttpResponse = struct { status: u16, text: []const u8 };\n");
        try g.w.writeAll("fn _http_request(method: std.http.Method, url: []const u8, payload: ?[]const u8) HttpResponse {\n");
        try g.w.writeAll("    var _hc = std.http.Client{ .allocator = _allocator };\n");
        try g.w.writeAll("    defer _hc.deinit();\n");
        try g.w.writeAll("    var _hb = std.io.Writer.Allocating.init(std.heap.page_allocator);\n");
        try g.w.writeAll("    const _hr = _hc.fetch(.{ .location = .{ .url = url }, .method = method, .payload = payload, .response_writer = &_hb.writer }) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("    return .{ .status = @intFromEnum(_hr.status), .text = _hb.written() };\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _http_get(url: []const u8) HttpResponse { return _http_request(.GET, url, null); }\n");
        try g.w.writeAll("fn _http_post(url: []const u8, payload: []const u8) HttpResponse { return _http_request(.POST, url, payload); }\n");
        // ── HTTP server ─────────────────────────────────────────────────────
        try g.w.writeAll("const HttpRequest = struct { method: []const u8, path: []const u8, content: []const u8 };\n");
        try g.w.writeAll(
            \\fn _http_serve(port: u16, handler: anytype) void {
            \\    const _alloc = std.heap.page_allocator;
            \\    var _srv = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port).listen(.{ .reuse_address = true }) catch |e| @panic(@errorName(e));
            \\    defer _srv.deinit();
            \\    while (true) {
            \\        var _conn = _srv.accept() catch continue;
            \\        defer _conn.stream.close();
            \\        // Read request head using recv (works on Windows sockets).
            \\        // We read into a large buffer and scan for \r\n\r\n.
            \\        var _hd: [16384]u8 = undefined;
            \\        var _hl: usize = 0;
            \\        while (_hl < _hd.len - 4096) {
            \\            const _n = std.posix.recv(_conn.stream.handle, _hd[_hl..@min(_hl+4096, _hd.len)], 0) catch break;
            \\            if (_n == 0) break;
            \\            _hl += _n;
            \\            if (std.mem.indexOf(u8, _hd[0.._hl], "\r\n\r\n") != null) break;
            \\        }
            \\        const _hdrs_end = (std.mem.indexOf(u8, _hd[0.._hl], "\r\n\r\n") orelse (_hl -| 4)) + 4;
            \\        const _head = _hd[0.._hdrs_end];
            \\        // Bytes already read after the headers (peeked body).
            \\        var _peeked: usize = if (_hl > _hdrs_end) _hl - _hdrs_end else 0;
            \\        // Parse request line: METHOD PATH VERSION
            \\        const _rl_end = std.mem.indexOf(u8, _head, "\r\n") orelse _hl;
            \\        var _rp = std.mem.splitScalar(u8, _head[0.._rl_end], ' ');
            \\        const _method = _rp.next() orelse "GET";
            \\        const _raw_path = _rp.next() orelse "/";
            \\        const _path = _raw_path[0 .. (std.mem.indexOfScalar(u8, _raw_path, '?') orelse _raw_path.len)];
            \\        // Parse Content-Length for request body.
            \\        var _cl: usize = 0;
            \\        var _hdr_it = std.mem.splitSequence(u8, _head, "\r\n");
            \\        _ = _hdr_it.next();
            \\        while (_hdr_it.next()) |_hl_| {
            \\            if (_hl_.len == 0) break;
            \\            const _cp = std.mem.indexOfScalar(u8, _hl_, ':') orelse continue;
            \\            const _hn = std.mem.trim(u8, _hl_[0.._cp], " ");
            \\            const _hv = std.mem.trim(u8, _hl_[_cp+1..], " ");
            \\            if (std.ascii.eqlIgnoreCase(_hn, "content-length"))
            \\                _cl = std.fmt.parseInt(usize, _hv, 10) catch 0;
            \\        }
            \\        var _body: []const u8 = "";
            \\        if (_cl > 0) {
            \\            const _bb = _alloc.alloc(u8, _cl) catch @panic("OOM");
            \\            // Copy any body bytes already read with the headers.
            \\            const _pre = @min(_peeked, _cl);
            \\            if (_pre > 0) @memcpy(_bb[0.._pre], _hd[_hdrs_end.._hdrs_end+_pre]);
            \\            var _bi: usize = _pre;
            \\            while (_bi < _cl) {
            \\                const _rn = std.posix.recv(_conn.stream.handle, _bb[_bi..], 0) catch break;
            \\                if (_rn == 0) break;
            \\                _bi += _rn;
            \\            }
            \\            _body = _bb[0.._bi];
            \\            _ = &_peeked; // suppress unused warning
            \\        }
            \\        // Invoke handler and write response.
            \\        const _req = HttpRequest{ .method = _method, .path = _path, .content = _body };
            \\        const _resp = if (comptime @typeInfo(@TypeOf(handler)) == .@"fn") handler(_req) else handler.call(_req);
            \\        const _st: []const u8 = switch (_resp.status) {
            \\            200 => "OK", 201 => "Created", 204 => "No Content",
            \\            301 => "Moved Permanently", 302 => "Found",
            \\            400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
            \\            404 => "Not Found", 405 => "Method Not Allowed",
            \\            500 => "Internal Server Error",
            \\            else => "Unknown",
            \\        };
            \\        const _out = std.fmt.allocPrint(_alloc,
            \\            "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            \\            .{ _resp.status, _st, _resp.text.len, _resp.text }) catch @panic("OOM");
            \\        _conn.stream.writeAll(_out) catch {};
            \\    }
            \\}
            \\
        );
        try g.w.writeAll("\n");
        // ── TCP helpers ────────────────────────────────────────────────────
        try g.w.writeAll("const TcpConn = struct { stream: std.net.Stream };\n");
        try g.w.writeAll("fn _tcp_connect(host: []const u8, port: u16) TcpConn {\n");
        try g.w.writeAll("    const s = std.net.tcpConnectToHost(_allocator, host, port) catch |e| @panic(@errorName(e));\n");
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
        try g.w.writeAll("fn _tcp_close(conn: TcpConn) void { conn.stream.close(); }\n\n");
        // ── UDP helpers ────────────────────────────────────────────────────
        try g.w.writeAll("const UdpSocket = struct { handle: std.posix.socket_t };\n");
        try g.w.writeAll("fn _udp_socket() UdpSocket {\n");
        try g.w.writeAll("    const s = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("    return .{ .handle = s };\n");
        try g.w.writeAll("}\n");
        try g.w.writeAll("fn _udp_send(sock: UdpSocket, host: []const u8, port: u16, data: []const u8) void {\n");
        try g.w.writeAll("    const dest = std.net.Address.parseIp4(host, port) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("    _ = std.posix.sendto(sock.handle, data, 0, &dest.any, dest.getOsSockLen()) catch |e| @panic(@errorName(e));\n");
        try g.w.writeAll("}\n");
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

        for (module.decls) |decl| try g.genTopDecl(decl);

        // Emit a top-level `pub fn main()` thunk if any class has a
        // `shared def main`.  Zig's startup code looks for `root.main`.
        if (try findMainClass(module.decls, g.alloc, "")) |class_name| {
            defer g.alloc.free(class_name);
            // If the main method throws, call it with `try`.
            const main_throws = findMainMethod(module.decls) != null and blk: {
                const m = findMainMethod(module.decls).?;
                break :blk m.throws or (m.body != null and bodyHasRaise(m.body.?));
            };
            const call_prefix: []const u8 = if (main_throws) "try " else "";
            try g.w.print(
                "pub fn main() !void {{\n    defer _arena.deinit();\n    {s}{s}.main();\n}}\n",
                .{ call_prefix, class_name },
            );
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
        }
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
            // Zebra dep: the generated .zig exports a type matching the last path
            // segment.  Unwrap it so `Utils.method()` works without double qualifier.
            try g.w.print("const {s} = @import(\"{s}.zig\").{s};\n", .{ alias, import_rel, alias });
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

    fn genClass(g: Generator, n: *Ast.DeclClass) anyerror!void {
        const cg = g.withOwner(n.name);

        try g.writeIndent();
        try g.w.print("pub const {s} = struct {{\n", .{n.name});

        const ig = cg.indented();

        // ① Inline mixin members before class members (fields first in Zig
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

        // ③ Interface conformance checks.
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
        const sg = g.withOwner(n.name);
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
        try g.writeIndent();
        const pub_str: []const u8 = if (n.mods.public or n.mods.shared) "pub " else "";
        try g.w.print("{s}const {s} = union(enum) {{\n", .{pub_str, n.name});
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

        const needs_error = m.throws or (m.body != null and bodyHasRaise(m.body.?));
        if (needs_error) try g.w.writeAll("anyerror!");
        if (m.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");

        if (m.body) |body| {
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            var mut_set = try scanMutations(body, g.alloc, g.tc);
            defer mut_set.deinit();
            var ret_set = try scanReturnedNames(body, g.alloc);
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
        const mg = g.asMethod();

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
            try g.w.print("self: *{s}", .{g.owner});
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
            (n.body != null and bodyHasRaise(n.body.?));
        if (needs_error) try g.w.writeAll("anyerror!");
        if (n.return_type) |rt| try g.genType(rt) else try g.w.writeAll("void");

        if (n.body) |body| {
            // Pre-scan 1: which params / self are actually referenced?
            var refs = try collectRefs(body, g.resolve, g.alloc);
            defer refs.deinit();
            // Pre-scan 2: which locals are mutated? (var vs const)
            var mut_set = try scanMutations(body, g.alloc, g.tc);
            defer mut_set.deinit();
            // Pre-scan 3: which locals appear in return expressions?
            // Those must NOT get defer-free (caller takes ownership).
            var ret_set = try scanReturnedNames(body, g.alloc);
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
        try g.w.print(") {s} {{\n", .{g.owner});
        const body = n.body orelse &[_]Ast.Stmt{};
        var refs = try collectRefs(body, g.resolve, g.alloc);
        defer refs.deinit();
        var mut_set = try scanMutations(body, g.alloc, g.tc);
        defer mut_set.deinit();
        var cv_map = std.StringHashMap(void).init(g.alloc);
        defer cv_map.deinit();
        const bg = mg.indented().withMutated(&mut_set).withClosureVars(&cv_map);
        try bg.writeIndent();
        try bg.w.print("var self: {s} = undefined;\n", .{g.owner});
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

    fn genStmt(g: Generator, stmt: Ast.Stmt) anyerror!void {
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
                    exprCallIsThrows(e.call, g.resolve))
                {
                    const ev  = g.try_err_var.?;
                    const lbl = g.try_block_label.?;
                    try g.w.print(" catch |_e| {{ {s} = _e; break :{s}; }}", .{ev, lbl});
                }
                try g.w.writeAll(";\n");
            },
            .pass      => try g.line("// pass"),
            .break_    => try g.line("break;"),
            .continue_ => try g.line("continue;"),
            .defer_    => |s| try g.genDefer(s),
            .contract  => {}, // contracts not emitted (runtime verification out of scope)
            .with      => |s| try g.genWith(s),
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
        const kw: []const u8 = if (n.is_const or !is_mutated) "const" else "var";

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
                        // Emit cleanup defer unless this var is returned (caller takes ownership).
                        const is_returned_ctor = if (g.returned_names) |rn| rn.contains(n.name) else false;
                        if (!is_returned_ctor) {
                            try g.writeIndent();
                            if (std.mem.eql(u8, gtr.name, "List")) {
                                try g.w.print("defer {s}.deinit(_allocator);\n", .{n.name});
                            } else {
                                try g.w.print("defer {s}.deinit();\n", .{n.name});
                            }
                        }
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

        // List/HashMap vars need `var` only when a deinit will be emitted, because
        // deinit takes *Self (mutable pointer). Borrowed vars (.at() / .fetch() init)
        // and returned vars don't get a deinit, so they can stay `const`.
        const eff_kw: []const u8 = blk: {
            if (n.type_) |tr| {
                if (tr == .generic) {
                    const gn = tr.generic.name;
                    if (std.mem.eql(u8, gn, "List") or std.mem.eql(u8, gn, "HashMap")) {
                        // Same "is_borrowed" check as the deinit-emission path below.
                        const is_borrowed_kw: bool = if (n.init) |e| b2: {
                            if (e.* == .call and e.call.callee.* == .member) {
                                const m = e.call.callee.member.member;
                                break :b2 std.mem.eql(u8, m, "at") or std.mem.eql(u8, m, "fetch");
                            }
                            break :b2 false;
                        } else false;
                        const is_returned_kw = if (g.returned_names) |rn| rn.contains(n.name) else false;
                        if (!is_borrowed_kw and !is_returned_kw)
                            break :blk "var";
                    }
                }
            }
            break :blk kw;
        };
        try g.w.writeAll(eff_kw);
        try g.w.writeAll(" ");
        try g.w.writeAll(n.name);
        if (n.type_) |tr| {
            try g.w.writeAll(": ");
            try g.genType(tr);
        } else if (std.mem.eql(u8, kw, "var")) {
            // Mutable var without explicit type: emit TC-inferred type to avoid
            // "comptime_int/comptime_float must be const" errors in Zig.
            if (n.init) |e| {
                if (g.tc) |tc| {
                    const t = tc.expr_types.get(e) orelse .unknown;
                    const ts: ?[]const u8 = switch (t) {
                        .int   => "i64",
                        .uint  => "u64",
                        .float => "f64",
                        .bool  => "bool",
                        .char  => "u21",
                        else   => null,
                    };
                    if (ts) |s| {
                        try g.w.writeAll(": ");
                        try g.w.writeAll(s);
                    }
                }
            }
        }
        if (n.init) |e| {
            try g.w.writeAll(" = ");
            try g.genExpr(e);
        } else {
            try g.w.writeAll(" = undefined");
        }
        try g.w.writeAll(";\n");
        // List/HashMap vars initialized from non-constructor exprs (e.g. File.readLines,
        // buildNgrams) need deinit — the constructor path already returns early above.
        // Exception: collection element accesses (.at(), .fetch()) borrow the element
        // without taking ownership — deiniting them would double-free the original.
        if (n.type_) |tr| {
            if (tr == .generic) {
                const gtr = tr.generic;
                const is_list_or_map = std.mem.eql(u8, gtr.name, "List") or
                                       std.mem.eql(u8, gtr.name, "HashMap");
                if (is_list_or_map) {
                    // Detect borrowed (non-owning) inits: list.at(i) or map.fetch(k)
                    const is_borrowed: bool = if (n.init) |e| blk: {
                        if (e.* == .call and e.call.callee.* == .member) {
                            const m = e.call.callee.member.member;
                            break :blk std.mem.eql(u8, m, "at") or std.mem.eql(u8, m, "fetch");
                        }
                        break :blk false;
                    } else false;
                    const is_returned = if (g.returned_names) |rn| rn.contains(n.name) else false;
                    if (!is_returned and !is_borrowed) {
                        try g.writeIndent();
                        if (std.mem.eql(u8, gtr.name, "List")) {
                            try g.w.print("defer {s}.deinit(_allocator);\n", .{n.name});
                        } else {
                            try g.w.print("defer {s}.deinit();\n", .{n.name});
                        }
                    }
                }
            }
        }
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
                if (std.mem.eql(u8, n.name, "TcpConn"))   return g.genTcpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "UdpSocket"))  return g.genUdpMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "Regex"))      return g.genRegexMethod(object, method, args);
                if (std.mem.eql(u8, n.name, "Gui"))        return g.genGuiWidgetMethod(object, method, args);
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
                        try g.genExpr(object);
                        try g.w.writeAll(".items.len");
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

    // ── sys static methods ────────────────────────────────────────────────────

    /// Emit a static `sys.*` call.
    ///
    ///   sys.args()          → ArrayList([]const u8) of command-line args (alloc'd)
    ///   sys.exit(code)      → std.process.exit(code)  — noreturn
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
        return false;
    }

    // ── Shell static methods ──────────────────────────────────────────────────

    /// Emit a static `Shell.*` call.
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

    fn genStrSliceMethod(g: Generator, obj: *const Ast.Expr, method: []const u8) anyerror!bool {
        if (std.mem.eql(u8, method, "count")) {
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(obj);
            try g.w.writeAll(".len))");
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
            // list.remove(i) → _ = list.orderedRemove(i)
            try g.w.writeAll("_ = ");
            try g.genExpr(obj);
            try g.w.writeAll(".orderedRemove(");
            if (args.len > 0) try g.genExpr(args[0].value);
            try g.w.writeAll(")");
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
            // items.len is usize; cast to i64 to match Zebra's int type.
            try g.w.writeAll("@as(i64, @intCast(");
            try g.genExpr(obj);
            try g.w.writeAll(".items.len))");
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
            if (cv.type_) |tr| try fg.genType(tr) else try fg.w.writeAll("anytype");
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
        // Pre-scan returned names so deferred frees are skipped for returned strings.
        var ret_set_capture = try scanReturnedNames(
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
                try g.genExpr(s.target);
                try g.w.writeAll(" ");
                try g.w.writeAll(assignOpStr(s.op));
                try g.w.writeAll(" ");
                try g.genExpr(s.value);
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
                    // Emit `.variant_name` — extract member part of `Type.variant` expr.
                    if (v.* == .member) {
                        try bg.w.print(".{s}", .{v.member.member});
                    } else {
                        try bg.genExpr(v);
                    }
                } else {
                    try bg.genExpr(v);
                }
            }
            if (is_union) {
                if (on.binding) |bname| {
                    try bg.w.print(" => |{s}| {{\n", .{bname});
                } else {
                    try bg.w.writeAll(" => {\n");
                }
            } else {
                try bg.w.writeAll(" => {\n");
            }
            try bg.indented().genStmts(on.body);
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
        const has_raise = bodyNeedsErrVar(s.body) or bodyHasThrowsCall(s.body, g.resolve);
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
                // Zebra char literals: c'A' or c"A" → strip 'c' prefix; Zig uses 'A'
                // Also convert c"A" double-quote form to single-quote form.
                const inner = e.text[1..]; // strip leading 'c'
                if (inner.len >= 2 and inner[0] == '"') {
                    // c"A" → 'A' (swap delimiters)
                    try g.w.writeByte('\'');
                    try g.w.writeAll(inner[1 .. inner.len - 1]);
                    try g.w.writeByte('\'');
                } else {
                    try g.w.writeAll(inner); // c'A' → 'A'
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
                // Tuple index access: p.0 → p.@"0"
                if (e.member.len > 0 and std.ascii.isDigit(e.member[0])) {
                    try g.genExpr(e.object);
                    try g.w.print(".@\"{s}\"", .{e.member});
                    break :sw;
                }
                try g.genExpr(e.object);
                try g.w.writeAll(".");
                try g.w.writeAll(e.member);
            },
            .call  => |e| try g.genCall(e),

            .index => |e| {
                try g.genExpr(e.object);
                try g.w.writeAll("[");
                try g.genExpr(e.index);
                try g.w.writeAll("]");
            },
            .slice => |e| {
                try g.genExpr(e.object);
                try g.w.writeAll("[");
                if (e.start) |s| try g.genExpr(s) else try g.w.writeAll("0");
                try g.w.writeAll("..");
                if (e.stop) |s| try g.genExpr(s);
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
                if (g.try_block_label) |lbl| {
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
                    try g.genExpr(e.expr);
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

    fn genCall(g: Generator, e: *Ast.ExprCall) anyerror!void {
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
                if (g.union_names.contains(type_name)) {
                    try g.w.print("{s}{{ .{s} = ", .{type_name, mem.member});
                    if (e.args.len == 1) {
                        try g.genExpr(e.args[0].value);
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
                try g.w.writeAll("std.ArrayList([]const u8){}");
                return;
            }
            if (std.mem.eql(u8, name, "HashMap")) {
                try g.w.writeAll("std.StringHashMap(i64).init(_allocator)");
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
                        for (e.args, 0..) |a, i| {
                            if (i > 0) try g.w.writeAll(", ");
                            try g.genExpr(a.value);
                        }
                        try g.w.writeAll(")");
                    } else {
                        // No `cue init`: emit a zero-initialised struct literal.
                        try g.w.print("{s}{{}}", .{class_name});
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
        // Http static calls: Http.get(url), Http.post(url, body), Http.serve(port, handler).
        if (e.callee.* == .member) {
            const mem = e.callee.member;
            if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Http")) {
                if (try g.genHttpCall(mem.member, e.args)) return;
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
                    .tcp_conn   => if (try g.genTcpMethod(mem.object, mem.member, e.args)) return,
                    .udp_socket => if (try g.genUdpMethod(mem.object, mem.member, e.args)) return,
                    .regex       => if (try g.genRegexMethod(mem.object, mem.member, e.args)) return,
                    .gui_context => if (try g.genGuiWidgetMethod(mem.object, mem.member, e.args)) return,
                    .str_slice  => if (try g.genStrSliceMethod(mem.object, mem.member)) return,
                    .unknown    => if (try g.genListMethod(mem.object, mem.member, e.args)) return,
                    else        => {},
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
                    for (e.args, 0..) |a, i| {
                        if (i > 0) try g.w.writeAll(", ");
                        try g.genExpr(a.value);
                    }
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
                    if (is_shared) {
                        try g.w.print("{s}.{s}(", .{ g.owner, ident.name });
                    } else {
                        try g.w.print("self.{s}(", .{ident.name});
                    }
                    for (e.args, 0..) |a, i| {
                        if (i > 0) try g.w.writeAll(", ");
                        try g.genExpr(a.value);
                    }
                    try g.w.writeAll(")");
                    return;
                }
            }
        }
        try g.genExpr(e.callee);
        try g.w.writeAll("(");
        for (e.args, 0..) |a, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.genExpr(a.value);
        }
        try g.w.writeAll(")");
    }

    fn genBinary(g: Generator, e: *Ast.ExprBinary) anyerror!void {
        switch (e.op) {
            .div, .int_div => {
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
            .dotdot => {
                try g.genExpr(e.left);
                try g.w.writeAll("..");
                try g.genExpr(e.right);
            },
            .eq, .ne => {
                // For string == / != use std.mem.eql rather than the raw == operator,
                // which Zig does not support on slices.
                const left_is_str = blk: {
                    if (g.tc) |tc| {
                        const t = tc.expr_types.get(e.left) orelse .unknown;
                        break :blk t == .string;
                    }
                    break :blk false;
                };
                if (left_is_str) {
                    if (e.op == .ne) try g.w.writeAll("!");
                    try g.w.writeAll("std.mem.eql(u8, ");
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
            .plain => try g.w.writeAll(e.text),
            .raw   => {
                // r"..." → strip the 'r' prefix; Zig double-quoted strings work here.
                try g.w.writeAll(e.text[1..]);
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
                if (cv.type_) |tr| try fg.genType(tr) else try fg.w.writeAll("anytype");
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
        const lg = g.asMethod();
        switch (e.body) {
            .expr  => |ex| {
                try lg.w.writeAll(" return ");
                try lg.genExpr(ex);
                try lg.w.writeAll(";");
            },
            .stmts => |ss| {
                var ret_set_lambda = try scanReturnedNames(ss, g.alloc);
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
                try g.w.writeAll("?");
                try g.genType(inner.*);
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
        .optional,
        .tuple                         => "{any}",
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

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc);
    defer resolve.deinit();

    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);

    _ = try generate(module, &resolve, null, alloc, out.writer(alloc).any(), .stub);
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

    try testing.expect(std.mem.indexOf(u8, out, "next: ?Node") != null);
}
