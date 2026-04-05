//! TypeChecker: semantic analysis Pass 3 — assign types to expressions
//! and verify type compatibility.
//!
//! Consumes Pass 1 (`SymbolTable`) and Pass 2 (`ResolveResult`) to:
//!   - Assign a concrete `Type` to every expression in the AST.
//!   - Verify that variable initialisers match declared types.
//!   - Verify that `return` expressions match method return types.
//!   - Verify that assignment RHS types match LHS types.
//!   - Verify that `if` / `while` / `assert` conditions are `bool`.
//!   - Verify that `and` / `or` operands are `bool`.
//!   - Verify that arithmetic operands are numeric and have matching types.
//!
//! ## What is deferred
//!
//! - Compound types (`T?`, `!T`, generics) are recorded as `Type.unknown`
//!   and checked in a later pass.
//! - Member-access type resolution (`obj.field`) is deferred to Pass 4,
//!   when the full type of the object is available.
//! - Method-call argument type checking is deferred similarly.
//!
//! ## Usage
//!
//! ```zig
//! var tc_result = try TypeChecker.typeCheckPass3(module, &resolve_result, gpa, gpa);
//! defer tc_result.deinit();
//! if (tc_result.hasErrors()) { /* report */ }
//! ```

const std      = @import("std");
const Ast      = @import("Ast.zig");
const ST       = @import("SymbolTable.zig");
const Binder   = @import("Binder.zig");
const Resolver = @import("Resolver.zig");
const Builtins = @import("Builtins.zig");

const Allocator   = std.mem.Allocator;
const Symbol      = ST.Symbol;
const SymbolKind  = ST.SymbolKind;
const Diagnostic  = Binder.Diagnostic;
const DiagKind    = Binder.DiagKind;

// ── Type representation ───────────────────────────────────────────────────────

pub const Type = union(enum) {
    // ── Primitives ────────────────────────────────────────────────────────────
    int,              // i64  (default signed integer)
    uint,             // u64  (default unsigned integer)
    float,            // f64  (default float)
    bool,
    char,
    string,
    void_,

    // ── Sized numeric types ───────────────────────────────────────────────────
    /// Signed integer with explicit bit width: int8, int32, int(5), …
    int_n:   u16,
    /// Unsigned integer with explicit bit width: uint8, uint32, byte, …
    uint_n:  u16,
    /// Floating-point with explicit bit width: float32, float16, …
    float_n: u16,

    // ── User-defined ──────────────────────────────────────────────────────────
    /// A class / interface / struct / mixin / enum.
    named: *const Symbol,

    // ── Stdlib types ─────────────────────────────────────────────────────────
    /// `StringBuilder` — wraps `std.ArrayList(u8)`.
    string_builder,
    /// `HttpRequest` — incoming server request passed to `Http.serve` handler.
    http_request,
    /// `HttpResponse` — result of `Http.get` / `Http.post`, or constructed via `HttpResponse.ok` etc.
    http_response,
    /// `TcpConn` — result of `Tcp.connect`.
    tcp_conn,
    /// `UdpSocket` — result of `Udp.socket`.
    udp_socket,
    /// `Regex` — compiled regular expression.
    regex,
    /// `Gui` — GUI context passed to `Gui.run` frame callback; also the `Gui` namespace type.
    gui_context,

    // ── Special ───────────────────────────────────────────────────────────────
    /// Cannot determine type: upstream error or unsupported construct.
    /// Suppresses further cascading errors.
    unknown,

    /// Two types are the same value.
    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .int     => b == .int,
            .uint    => b == .uint,
            .float   => b == .float,
            .bool    => b == .bool,
            .char    => b == .char,
            .string  => b == .string,
            .void_   => b == .void_,
            .int_n   => |wa| switch (b) { .int_n   => |wb| wa == wb, else => false },
            .uint_n  => |wa| switch (b) { .uint_n  => |wb| wa == wb, else => false },
            .float_n => |wa| switch (b) { .float_n => |wb| wa == wb, else => false },
            .named          => |sa| switch (b) { .named   => |sb| sa == sb, else => false },
            .string_builder => b == .string_builder,
            .http_request   => b == .http_request,
            .http_response  => b == .http_response,
            .tcp_conn       => b == .tcp_conn,
            .udp_socket     => b == .udp_socket,
            .regex          => b == .regex,
            .gui_context    => b == .gui_context,
            .unknown        => b == .unknown,
        };
    }

    /// `from` can be assigned where `to` is expected.
    /// `unknown` on either side bypasses the check (error already reported).
    /// All numeric types are assignment-compatible with each other at the
    /// Zebra level — Zig enforces the actual range/precision constraints.
    /// This reflects the "integer literals are untyped" principle.
    pub fn isAssignable(from: Type, to: Type) bool {
        if (from == .unknown or to == .unknown) return true;
        // Any numeric → any numeric: defer to Zig.
        if (from.isNumeric() and to.isNumeric()) return true;
        // char (u21) is assignment-compatible with integer types — it IS a codepoint.
        if (to == .char and (from.isNumeric() or from == .char)) return true;
        if (from == .char and to.isNumeric()) return true;
        if (from == .http_request  and to == .http_request)  return true;
        if (from == .http_response and to == .http_response) return true;
        if (from == .tcp_conn   and to == .tcp_conn)   return true;
        if (from == .udp_socket and to == .udp_socket) return true;
        if (from == .regex      and to == .regex)      return true;
        if (from == .gui_context and to == .gui_context) return true;
        return eql(from, to);
    }

    /// Human-readable name for diagnostics.
    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .int     => "int",
            .uint    => "uint",
            .float   => "float",
            .bool    => "bool",
            .char    => "char",
            .string  => "String",
            .void_   => "void",
            .int_n   => "int<N>",    // diagnostic only — exact width not tracked in []const u8
            .uint_n  => "uint<N>",
            .float_n => "float<N>",
            .named          => |s| s.name,
            .string_builder => "StringBuilder",
            .http_request   => "HttpRequest",
            .http_response  => "HttpResponse",
            .tcp_conn       => "TcpConn",
            .udp_socket     => "UdpSocket",
            .regex          => "Regex",
            .gui_context    => "Gui",
            .unknown        => "<unknown>",
        };
    }

    /// True for any signed integer type.
    pub fn isIntFamily(t: Type) bool {
        return switch (t) { .int, .int_n => true, else => false };
    }

    /// True for any unsigned integer type.
    pub fn isUintFamily(t: Type) bool {
        return switch (t) { .uint, .uint_n => true, else => false };
    }

    /// True for any floating-point type.
    pub fn isFloatFamily(t: Type) bool {
        return switch (t) { .float, .float_n => true, else => false };
    }

    /// True for any numeric type (signed, unsigned, or float).
    pub fn isNumeric(t: Type) bool {
        return t.isIntFamily() or t.isUintFamily() or t.isFloatFamily();
    }
};

// ── Result ────────────────────────────────────────────────────────────────────

pub const TypeCheckResult = struct {
    /// Every walked expression → its inferred `Type`.
    expr_types: std.AutoHashMap(*const Ast.Expr, Type),
    diags:      []const Diagnostic,
    diag_alloc: Allocator,

    pub fn hasErrors(self: TypeCheckResult) bool {
        for (self.diags) |d| if (d.kind == .err) return true;
        return false;
    }

    pub fn deinit(self: *TypeCheckResult) void {
        for (self.diags) |d| self.diag_alloc.free(d.message);
        self.diag_alloc.free(self.diags);
        self.expr_types.deinit();
    }
};

// ── Public entry point ────────────────────────────────────────────────────────

/// Run Pass 3 on `module` using the already-populated `resolve` result.
///
/// - `map_alloc`  — owns the `expr_types` hash-map entries.
/// - `diag_alloc` — owns the `diags` slice and message strings.
pub fn typeCheckPass3(
    module:     Ast.Module,
    resolve:    *const Resolver.ResolveResult,
    map_alloc:  Allocator,
    diag_alloc: Allocator,
) anyerror!TypeCheckResult {
    var expr_types     = std.AutoHashMap(*const Ast.Expr, Type).init(map_alloc);
    var loop_var_types = std.StringHashMap(Type).init(map_alloc);
    defer loop_var_types.deinit();
    var diags          = std.ArrayList(Diagnostic){};

    const tc = TypeChecker{
        .resolve        = resolve,
        .map_alloc      = map_alloc,
        .diag_alloc     = diag_alloc,
        .expr_types     = &expr_types,
        .diags          = &diags,
        .return_type    = .void_,
        .owner_sym      = null,
        .loop_var_types = &loop_var_types,
    };

    try tc.checkModule(module);

    return .{
        .expr_types = expr_types,
        .diags      = try diags.toOwnedSlice(diag_alloc),
        .diag_alloc = diag_alloc,
    };
}

// ── TypeChecker context ───────────────────────────────────────────────────────
//
// Passed by value; `expr_types` and `diags` are behind pointers so all copies
// share the same output maps.  `return_type` and `owner_sym` are cheap scalars
// that are overridden via `withReturn` / `withOwner` when descending into a
// method or type body.

const TypeChecker = struct {
    resolve:     *const Resolver.ResolveResult,
    map_alloc:   Allocator,
    diag_alloc:  Allocator,
    expr_types:  *std.AutoHashMap(*const Ast.Expr, Type),
    diags:       *std.ArrayList(Diagnostic),
    /// Expected return type of the enclosing method.  `void_` at module level.
    return_type: Type,
    /// Symbol for the enclosing type body — used to resolve `this` and `same`.
    owner_sym:   ?*const Symbol,
    /// Transient element-type overrides for active loop variables.
    /// Keyed by variable name (string).  Shared across TypeChecker copies.
    loop_var_types: *std.StringHashMap(Type),

    fn withReturn(tc: TypeChecker, ret: Type) TypeChecker {
        var c = tc; c.return_type = ret; return c;
    }
    fn withOwner(tc: TypeChecker, owner: ?*const Symbol) TypeChecker {
        var c = tc; c.owner_sym = owner; return c;
    }

    // ── Module ────────────────────────────────────────────────────────────────

    fn checkModule(tc: TypeChecker, module: Ast.Module) anyerror!void {
        for (module.decls) |decl| try tc.checkTopDecl(decl);
    }

    fn checkTopDecl(tc: TypeChecker, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .use       => {},
            .namespace => |n| for (n.decls) |d| try tc.checkTopDecl(d),
            .class     => |n| try tc.checkClass(n),
            .interface => |n| try tc.checkInterface(n),
            .struct_   => |n| try tc.checkStruct(n),
            .mixin     => |n| try tc.checkMixin(n),
            .enum_     => |n| try tc.checkEnum(n),
            .extend    => |n| try tc.checkExtend(n),
            .method    => |n| try tc.checkMethod(n),
            .property  => |n| try tc.checkProperty(n),
            .var_      => |n| try tc.checkVarDecl(n),
            .init      => |n| try tc.checkInit(n),
            .union_    => {},  // no body to type-check (variants are types, not expressions)
        }
    }

    // ── Type declarations ─────────────────────────────────────────────────────

    fn checkClass(tc: TypeChecker, n: *Ast.DeclClass) anyerror!void {
        for (n.invariants) |e| _ = try tc.inferExpr(e);
        for (n.members)    |m| try tc.checkMember(m);
    }

    fn checkInterface(tc: TypeChecker, n: *Ast.DeclInterface) anyerror!void {
        for (n.members) |m| try tc.checkMember(m);
    }

    fn checkStruct(tc: TypeChecker, n: *Ast.DeclStruct) anyerror!void {
        for (n.invariants) |e| _ = try tc.inferExpr(e);
        for (n.members)    |m| try tc.checkMember(m);
    }

    fn checkMixin(tc: TypeChecker, n: *Ast.DeclMixin) anyerror!void {
        for (n.members) |m| try tc.checkMember(m);
    }

    fn checkEnum(tc: TypeChecker, n: *Ast.DeclEnum) anyerror!void {
        for (n.members) |*m| {
            if (m.value) |v| _ = try tc.inferExpr(v);
        }
    }

    fn checkExtend(tc: TypeChecker, n: *Ast.DeclExtend) anyerror!void {
        for (n.members) |m| try tc.checkMember(m);
    }

    fn checkMember(tc: TypeChecker, decl: Ast.Decl) anyerror!void {
        switch (decl) {
            .method   => |n| try tc.checkMethod(n),
            .property => |n| try tc.checkProperty(n),
            .var_     => |n| try tc.checkVarDecl(n),
            .init     => |n| try tc.checkInit(n),
            else      => {},
        }
    }

    // ── Method ────────────────────────────────────────────────────────────────

    fn checkMethod(tc: TypeChecker, n: *Ast.DeclMethod) anyerror!void {
        const ret = tc.typeFromOptRef(if (n.return_type) |*rt| rt else null);
        const inner = tc.withReturn(ret);

        for (n.params) |p| {
            if (p.default) |d| {
                const dt = try inner.inferExpr(d);
                if (p.type_) |*pt| {
                    const declared = tc.typeFromRef(pt);
                    if (!Type.isAssignable(dt, declared))
                        try inner.emitMismatch(spanOf(d), dt, declared);
                }
            }
        }
        if (n.body)    |body| try inner.checkStmts(body);
        for (n.require) |e|   _ = try inner.inferExpr(e);
        for (n.ensure)  |e|   _ = try inner.inferExpr(e);
    }

    fn checkProperty(tc: TypeChecker, n: *Ast.DeclProperty) anyerror!void {
        const prop_type = tc.typeFromOptRef(if (n.type_) |*t| t else null);
        const inner = tc.withReturn(prop_type);
        if (n.getter) |body| try inner.checkStmts(body);
        if (n.setter) |body| try inner.checkStmts(body);
    }

    // ── Variable / field declaration ──────────────────────────────────────────

    fn checkVarDecl(tc: TypeChecker, n: *Ast.DeclVar) anyerror!void {
        if (n.init) |init_expr| {
            const actual = try tc.inferExpr(init_expr);
            if (n.type_) |*tr| {
                const declared = tc.typeFromRef(tr);
                if (!Type.isAssignable(actual, declared))
                    try tc.emitMismatch(spanOf(init_expr), actual, declared);
            }
        }
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    fn checkInit(tc: TypeChecker, n: *Ast.DeclInit) anyerror!void {
        for (n.params) |p| {
            if (p.default) |d| _ = try tc.inferExpr(d);
        }
        if (n.body)     |body| try tc.checkStmts(body);
        for (n.require) |e|   _ = try tc.inferExpr(e);
        for (n.ensure)  |e|   _ = try tc.inferExpr(e);
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn checkStmts(tc: TypeChecker, stmts: []const Ast.Stmt) anyerror!void {
        for (stmts) |stmt| try tc.checkStmt(stmt);
    }

    fn checkStmt(tc: TypeChecker, stmt: Ast.Stmt) anyerror!void {
        switch (stmt) {
            .if_      => |s| {
                try tc.checkBoolExpr(s.cond);
                try tc.checkStmts(s.then_body);
                for (s.else_ifs) |ei| {
                    try tc.checkBoolExpr(ei.cond);
                    try tc.checkStmts(ei.body);
                }
                if (s.else_body) |eb| try tc.checkStmts(eb);
            },
            .while_   => |s| {
                try tc.checkBoolExpr(s.cond);
                try tc.checkStmts(s.body);
                if (s.post_body) |pb| try tc.checkStmts(pb);
            },
            .for_in   => |s| {
                _ = try tc.inferExpr(s.iter);
                const elem = tc.inferForInElemType(s.iter);
                if (elem != .unknown) {
                    for (s.vars) |vname| try tc.loop_var_types.put(vname, elem);
                }
                if (s.where) |w| try tc.checkBoolExpr(w);
                try tc.checkStmts(s.body);
                if (elem != .unknown) {
                    for (s.vars) |vname| _ = tc.loop_var_types.remove(vname);
                }
            },
            .for_num  => |s| {
                _ = try tc.inferNumericExpr(s.start);
                _ = try tc.inferNumericExpr(s.stop);
                if (s.step) |st| _ = try tc.inferNumericExpr(st);
                // Loop variable is always int.
                try tc.loop_var_types.put(s.var_, .int);
                try tc.checkStmts(s.body);
                _ = tc.loop_var_types.remove(s.var_);
            },
            .branch   => |s| {
                _ = try tc.inferExpr(s.expr);
                for (s.on) |on| {
                    for (on.values) |v| _ = try tc.inferExpr(v);
                    try tc.checkStmts(on.body);
                }
                if (s.else_) |eb| try tc.checkStmts(eb);
            },
            .return_  => |s| try tc.checkReturn(s),
            .assert   => |s| {
                try tc.checkBoolExpr(s.cond);
                if (s.message) |m| _ = try tc.inferExpr(m);
            },
            .print    => |s| { for (s.args) |a| _ = try tc.inferExpr(a); },
            .yield    => |s| _ = try tc.inferExpr(s.value),
            .assign   => |s| try tc.checkAssign(s),
            .var_     => |n| try tc.checkVarDecl(n),
            .expr     => |e| _ = try tc.inferExpr(e),
            .contract => |s| { for (s.exprs) |e| _ = try tc.inferExpr(e); },
            .defer_   => |s| try tc.checkStmt(s.body),
            .with     => |s| { _ = try tc.inferExpr(s.target); try tc.checkStmts(s.body); },
            .var_except    => |s| { _ = try tc.inferExpr(s.base); for (s.fields) |f| _ = try tc.inferExpr(f.value); },
            .assign_except => |s| { _ = try tc.inferExpr(s.target); _ = try tc.inferExpr(s.base); for (s.fields) |f| _ = try tc.inferExpr(f.value); },
            .raise    => |s| {
                if (s.message) |m| _ = try tc.inferExpr(m);
                if (s.details) |d| {
                    const det_type = try tc.inferExpr(d);
                    switch (det_type) {
                        .string  => {}, // string.toString() is itself — always OK
                        .unknown => {}, // can't check statically, suppress
                        .named   => |sym| {
                            const has_to_string = if (sym.own_scope) |scope|
                                scope.lookupLocal("toString") != null
                            else false;
                            if (!has_to_string)
                                try tc.emitError(s.span,
                                    "raise details must implement 'toString as str': type '{s}' has no toString method",
                                    .{sym.name});
                        },
                        else => |t| try tc.emitError(s.span,
                            "raise details must implement 'toString as str': got '{s}'",
                            .{t.name()}),
                    }
                }
            },
            .try_catch => |s| {
                try tc.checkStmts(s.body);
                for (s.clauses) |cl| try tc.checkStmts(cl.body);
            },
            .pass, .break_, .continue_ => {},
        }
    }

    fn checkReturn(tc: TypeChecker, s: *Ast.StmtReturn) anyerror!void {
        if (s.value) |v| {
            const actual = try tc.inferExpr(v);
            if (!Type.isAssignable(actual, tc.return_type))
                try tc.emitMismatch(spanOf(v), actual, tc.return_type);
        } else {
            if (tc.return_type != .void_ and tc.return_type != .unknown)
                try tc.emitError(s.span, "return without value in non-void method", .{});
        }
    }

    fn checkAssign(tc: TypeChecker, s: *Ast.StmtAssign) anyerror!void {
        const lhs = try tc.inferExpr(s.target);
        const rhs = try tc.inferExpr(s.value);
        if (s.op == .assign) {
            if (!Type.isAssignable(rhs, lhs))
                try tc.emitMismatch(spanOf(s.value), rhs, lhs);
        } else {
            // Compound ops (+= -= etc.) require numeric LHS.
            if (!lhs.isNumeric() and lhs != .unknown)
                try tc.emitError(s.span, "compound assignment requires numeric type, got '{s}'", .{lhs.name()});
        }
    }

    // ── Expression helpers ────────────────────────────────────────────────────

    fn checkBoolExpr(tc: TypeChecker, e: *const Ast.Expr) anyerror!void {
        const t = try tc.inferExpr(e);
        if (t != .bool and t != .unknown)
            try tc.emitMismatch(spanOf(e), t, .bool);
    }

    fn inferNumericExpr(tc: TypeChecker, e: *const Ast.Expr) anyerror!Type {
        const t = try tc.inferExpr(e);
        if (!t.isNumeric() and t != .unknown)
            try tc.emitError(spanOf(e), "expected numeric type, got '{s}'", .{t.name()});
        return t;
    }

    // ── Expression type inference ─────────────────────────────────────────────

    /// Infer, record, and return the type of `expr`.
    fn inferExpr(tc: TypeChecker, expr: *const Ast.Expr) anyerror!Type {
        const t = try tc.inferExprInner(expr);
        try tc.expr_types.put(expr, t);
        return t;
    }

    fn inferExprInner(tc: TypeChecker, expr: *const Ast.Expr) anyerror!Type {
        return switch (expr.*) {
            .int_lit        => .int,
            .float_lit      => .float,
            .bool_lit       => .bool,
            .char_lit       => .char,
            .string_lit     => .string,
            .string_interp  => |e| blk: {
                // Infer sub-expression types so CodeGen can pick {s} vs {} etc.
                for (e.parts) |part| {
                    switch (part) {
                        .expr => |ex| _ = try tc.inferExpr(ex),
                        else  => {},
                    }
                }
                break :blk .string;
            },
            .nil            => .unknown, // context-dependent nilable
            .this           => if (tc.owner_sym) |s| Type{ .named = s } else .unknown,
            .zig_lit        => .unknown, // opaque backend literal
            .ident          => |*e| tc.inferIdent(e),
            .member         => |e| try tc.inferMember(e),
            .call           => |e| try tc.inferCall(e),
            .index          => |e| blk: {
                const ot = try tc.inferExpr(e.object);
                _ = try tc.inferExpr(e.index);
                // string[i] → char
                break :blk if (ot == .string) .char else .unknown;
            },
            .slice          => |e| blk: {
                const ot = try tc.inferExpr(e.object);
                if (e.start) |s| _ = try tc.inferExpr(s);
                if (e.stop)  |s| _ = try tc.inferExpr(s);
                // string[i..j] → string
                break :blk if (ot == .string) .string else .unknown;
            },
            .binary         => |e| try tc.inferBinary(e),
            .unary          => |e| try tc.inferUnary(e),
            .cast           => |e| blk: { _ = try tc.inferExpr(e.expr); break :blk tc.typeFromRef(&e.target); },
            .to_nilable     => |e| blk: { _ = try tc.inferExpr(e.expr); break :blk .unknown; },
            .to_non_nil     => |e| try tc.inferExpr(e.expr),
            .is_nil         => |e| blk: { _ = try tc.inferExpr(e.expr); break :blk .bool; },
            .orelse_        => |e| try tc.inferOrelse(e),
            .catch_         => |e| try tc.inferCatch(e),
            .if_expr        => |e| try tc.inferIfExpr(e),
            .lambda         => |e| try tc.inferLambda(e),
            .list_lit       => |e| blk: { for (e.elems) |el| _ = try tc.inferExpr(el);  break :blk .unknown; },
            .dict_lit       => |e| blk: { for (e.entries) |en| { _ = try tc.inferExpr(en.key); _ = try tc.inferExpr(en.value); } break :blk .unknown; },
            .array_lit      => |e| blk: { for (e.elems) |el| _ = try tc.inferExpr(el);  break :blk .unknown; },
            .all_any        => |e| blk: { _ = try tc.inferExpr(e.iter); _ = try tc.inferExpr(e.cond); break :blk .bool; },
            .old            => |e| try tc.inferExpr(e.expr),
            // try expr — propagates error; result type is the unwrapped value type
            .try_           => |e| try tc.inferExpr(e.expr),
        };
    }

    fn inferIdent(tc: TypeChecker, e: *const Ast.ExprIdent) Type {
        const sym = tc.resolve.exprs.get(e) orelse return .unknown;
        const t = tc.symbolType(sym);
        if (t != .unknown) return t;
        // Check if this ident is a loop variable with a known element type.
        return tc.loop_var_types.get(e.name) orelse .unknown;
    }

    fn inferMember(tc: TypeChecker, e: *Ast.ExprMember) anyerror!Type {
        const obj_type = try tc.inferExpr(e.object);
        // `len` property on strings and StringBuilder → usize (represented as .uint)
        if (std.mem.eql(u8, e.member, "len") and
            (obj_type == .string or obj_type == .string_builder)) return .uint;
        // HttpRequest field access.
        if (obj_type == .http_request) {
            if (std.mem.eql(u8, e.member, "method"))  return .string;
            if (std.mem.eql(u8, e.member, "path"))    return .string;
            if (std.mem.eql(u8, e.member, "content")) return .string;
        }
        // HttpResponse field access.
        if (obj_type == .http_response) {
            if (std.mem.eql(u8, e.member, "status")) return .uint;
            if (std.mem.eql(u8, e.member, "text"))   return .string;
        }
        // Look up the member name in the object type's own scope.
        if (obj_type == .named) {
            const sym = obj_type.named;
            if (sym.own_scope) |scope| {
                if (scope.lookupLocal(e.member)) |member_sym| {
                    return tc.symbolType(member_sym);
                }
            }
        }
        return .unknown;
    }

    /// Infer the element type that loop variables will have when iterating `iter`.
    fn inferForInElemType(tc: TypeChecker, iter: *const Ast.Expr) Type {
        // str.split(delim) / str.lines() → each element is a string
        // str.chars() → each element is a char (u21 Unicode codepoint)
        if (iter.* == .call) {
            const callee = iter.call.callee;
            if (callee.* == .member) {
                const m = callee.member.member;
                if (std.mem.eql(u8, m, "split") or std.mem.eql(u8, m, "lines")) {
                    const obj_type = tc.expr_types.get(callee.member.object) orelse .unknown;
                    if (obj_type == .string) return .string;
                }
                if (std.mem.eql(u8, m, "chars")) {
                    const obj_type = tc.expr_types.get(callee.member.object) orelse .unknown;
                    if (obj_type == .string) return .char;
                }
                // re.findAll(s) → each element is a string
                if (std.mem.eql(u8, m, "findAll")) {
                    const obj_type = tc.expr_types.get(callee.member.object) orelse .unknown;
                    if (obj_type == .regex) return .string;
                }
            }
        }
        // list.items (member access on a List(T)) → element type; currently unknown without generics tracking
        // list (bare List ident) → element type currently unknown
        // for_num loop var → int (handled at the call site)
        return .unknown;
    }

    fn inferCall(tc: TypeChecker, e: *Ast.ExprCall) anyerror!Type {
        for (e.args) |arg| _ = try tc.inferExpr(arg.value);

        // Special case: direct call of a named method — return its declared
        // return type so that callers can type-check against it.
        switch (e.callee.*) {
            .ident => |*ident| {
                if (tc.resolve.exprs.get(ident)) |sym| {
                    _ = try tc.inferExpr(e.callee);
                    if (sym.kind == .method) {
                        const decl = sym.decl.method;
                        return tc.typeFromOptRef(if (decl.return_type) |*rt| rt else null);
                    }
                    return tc.symbolType(sym);
                }
            },
            .member => |mem| {
                // File.* static methods: special-case the File builtin.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "File")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "read"))      return .string;
                    if (std.mem.eql(u8, mem.member, "readLines")) return .unknown; // List(str)
                    if (std.mem.eql(u8, mem.member, "exists"))    return .bool;
                    return .void_;
                }
                // Http.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Http")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "get"))   return .http_response;
                    if (std.mem.eql(u8, mem.member, "post"))  return .http_response;
                    if (std.mem.eql(u8, mem.member, "serve")) return .void_;
                    return .void_;
                }
                // HttpResponse.* factory methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "HttpResponse")) {
                    _ = try tc.inferExpr(mem.object);
                    return .http_response;  // ok, notFound, new, etc.
                }
                // Tcp.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Tcp")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "connect")) return .tcp_conn;
                    return .void_;
                }
                // Udp.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Udp")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "socket")) return .udp_socket;
                    return .void_;
                }
                // Regex.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Regex")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "compile")) return .regex;
                    return .void_;
                }
                // Gui.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "Gui")) {
                    _ = try tc.inferExpr(mem.object);
                    // Infer the callback arg so widget method types are checked inside it.
                    if (std.mem.eql(u8, mem.member, "run") and e.args.len >= 4)
                        _ = try tc.inferExpr(e.args[3].value);
                    return .void_;
                }
                // sys.* static methods.
                if (mem.object.* == .ident and std.mem.eql(u8, mem.object.ident.name, "sys")) {
                    _ = try tc.inferExpr(mem.object);
                    if (std.mem.eql(u8, mem.member, "getenv"))  return .unknown; // ?str
                    if (std.mem.eql(u8, mem.member, "args"))    return .unknown; // List(str)
                    if (std.mem.eql(u8, mem.member, "exit"))    return .void_;
                    if (std.mem.eql(u8, mem.member, "err"))     return .void_;
                    if (std.mem.eql(u8, mem.member, "errln"))   return .void_;
                    return .void_;
                }
                // Stdlib method call: infer return type from receiver type + method name.
                const obj_type = try tc.inferExpr(mem.object);
                // User-defined class/struct methods: look up declared return type.
                if (obj_type == .named) {
                    const class_sym = obj_type.named;
                    if (class_sym.own_scope) |scope| {
                        if (scope.lookupLocal(mem.member)) |member_sym| {
                            if (member_sym.kind == .method) {
                                const decl = member_sym.decl.method;
                                return tc.typeFromOptRef(if (decl.return_type) |*rt| rt else null);
                            }
                            return tc.symbolType(member_sym);
                        }
                    }
                }
                return tc.inferStdlibMethodType(obj_type, mem.member);
            },
            else => {},
        }
        _ = try tc.inferExpr(e.callee);
        return .unknown;
    }

    /// Return type of a stdlib method call given the receiver's inferred Type.
    fn inferStdlibMethodType(tc: TypeChecker, obj_type: Type, method: []const u8) Type {
        _ = tc;
        // String methods
        if (obj_type == .string) {
            const str_string = std.StaticStringMap(void).initComptime(&.{
                .{ "concat",    {} }, .{ "format",    {} }, .{ "trim",      {} },
                .{ "trimLeft",  {} }, .{ "trimRight", {} },
                .{ "upper",     {} }, .{ "lower",     {} }, .{ "replace",   {} }, .{ "repeat",    {} },
                .{ "padLeft",   {} }, .{ "padRight",  {} }, .{ "center",    {} }, .{ "bytes",     {} },
                .{ "join",           {} }, .{ "lines",        {} }, .{ "reverse",    {} },
                .{ "toHex",          {} }, .{ "fromHex",      {} }, .{ "chars",      {} },
            });
            const str_int = std.StaticStringMap(void).initComptime(&.{
                .{ "toInt",          {} }, .{ "indexOf",      {} }, .{ "count",      {} },
                .{ "codePointCount", {} },
            });
            const str_bool = std.StaticStringMap(void).initComptime(&.{
                .{ "contains",     {} }, .{ "startsWith",  {} }, .{ "endsWith",    {} },
                .{ "isEmpty",      {} }, .{ "isAlpha",     {} }, .{ "isNumeric",   {} },
                .{ "isValidUtf8",  {} },
            });
            if (str_string.get(method) != null) return .string;
            if (str_int.get(method)    != null) return .int;
            if (str_bool.get(method)   != null) return .bool;
            if (std.mem.eql(u8, method, "toFloat")) return .float;
        }
        // StringBuilder methods
        if (obj_type == .string_builder) {
            if (std.mem.eql(u8, method, "build")) return .string;
            if (std.mem.eql(u8, method, "len"))   return .uint;
            return .void_;  // append, appendChar, clear all return void
        }
        // TcpConn methods
        if (obj_type == .tcp_conn) {
            if (std.mem.eql(u8, method, "read")) return .string;
            return .void_;  // write, close
        }
        // UdpSocket methods
        if (obj_type == .udp_socket) {
            if (std.mem.eql(u8, method, "recv")) return .string;
            return .void_;  // send, close
        }
        // Regex methods
        if (obj_type == .regex) {
            if (std.mem.eql(u8, method, "match"))   return .bool;
            if (std.mem.eql(u8, method, "find"))    return .string;
            if (std.mem.eql(u8, method, "findAll")) return .unknown; // []const []const u8 slice — not modelled
            if (std.mem.eql(u8, method, "replace")) return .string;
            return .void_;
        }
        // Gui widget methods (on gui_context receiver)
        if (obj_type == .gui_context) {
            if (std.mem.eql(u8, method, "button"))   return .bool;
            if (std.mem.eql(u8, method, "checkbox")) return .bool;
            if (std.mem.eql(u8, method, "slider"))   return .float;
            if (std.mem.eql(u8, method, "input"))    return .string;
            // void-returning widgets
            return .void_;  // text, separator, sameLine, spacing, indent, unindent, panel, window
        }
        // toString() on any type → string
        if (std.mem.eql(u8, method, "toString")) return .string;
        // List / HashMap methods
        const count_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "count", {} },
        });
        const bool_methods = std.StaticStringMap(void).initComptime(&.{
            .{ "contains", {} },
        });
        if (count_methods.get(method) != null) return .int;
        if (bool_methods.get(method)  != null) return .bool;
        return .unknown;
    }

    fn inferBinary(tc: TypeChecker, e: *Ast.ExprBinary) anyerror!Type {
        const lt = try tc.inferExpr(e.left);
        const rt = try tc.inferExpr(e.right);

        return switch (e.op) {
            // Comparisons always produce bool.
            .eq, .ne, .lt, .le, .gt, .ge => .bool,

            // Logical: operands must be bool.
            .and_, .or_ => blk: {
                if (lt != .bool and lt != .unknown)
                    try tc.emitMismatch(spanOf(e.left), lt, .bool);
                if (rt != .bool and rt != .unknown)
                    try tc.emitMismatch(spanOf(e.right), rt, .bool);
                break :blk .bool;
            },

            // Arithmetic: operands must be numeric and the same type.
            .add, .sub, .mul, .div, .int_div, .mod, .pow => blk: {
                if (lt == .unknown or rt == .unknown) break :blk .unknown;
                if (!lt.isNumeric())
                    try tc.emitError(spanOf(e.left), "arithmetic requires numeric type, got '{s}'", .{lt.name()});
                if (!rt.isNumeric())
                    try tc.emitError(spanOf(e.right), "arithmetic requires numeric type, got '{s}'", .{rt.name()});
                if (lt.isNumeric() and rt.isNumeric() and !Type.eql(lt, rt))
                    try tc.emitError(e.span, "arithmetic operands must have the same type: '{s}' vs '{s}'", .{ lt.name(), rt.name() });
                break :blk if (lt.isNumeric()) lt else .unknown;
            },

            // Bitwise: operands must be integer family.
            .bit_and, .bit_or, .bit_xor, .shl, .shr => blk: {
                if (!lt.isIntFamily() and !lt.isUintFamily() and lt != .unknown)
                    try tc.emitError(spanOf(e.left), "bitwise operator requires integer type, got '{s}'", .{lt.name()});
                if (!rt.isIntFamily() and !rt.isUintFamily() and rt != .unknown)
                    try tc.emitError(spanOf(e.right), "bitwise operator requires integer type, got '{s}'", .{rt.name()});
                break :blk lt; // preserve the operand type
            },

            // Range: type not modelled yet.
            .dotdot => .unknown,
        };
    }

    fn inferUnary(tc: TypeChecker, e: *Ast.ExprUnary) anyerror!Type {
        const ot = try tc.inferExpr(e.operand);
        return switch (e.op) {
            .neg => blk: {
                if (!ot.isNumeric() and ot != .unknown)
                    try tc.emitError(spanOf(e.operand), "unary '-' requires numeric type, got '{s}'", .{ot.name()});
                break :blk if (ot.isNumeric()) ot else .unknown;
            },
            .not_ => blk: {
                if (ot != .bool and ot != .unknown)
                    try tc.emitMismatch(spanOf(e.operand), ot, .bool);
                break :blk .bool;
            },
            .bit_not => blk: {
                if (!ot.isIntFamily() and !ot.isUintFamily() and ot != .unknown)
                    try tc.emitError(spanOf(e.operand), "bitwise 'not' requires integer type, got '{s}'", .{ot.name()});
                break :blk ot; // preserve the operand type
            },
            .old => ot, // pre-call value — same type as operand
        };
    }

    fn inferOrelse(tc: TypeChecker, e: *Ast.ExprOrelse) anyerror!Type {
        const et = try tc.inferExpr(e.expr);
        const ft = try tc.inferExpr(e.fallback);
        // The fallback should be assignable to the non-nilable form of expr's type.
        // Since we don't model nilable types yet, just verify the fallback is compatible.
        if (et != .unknown and ft != .unknown and !Type.isAssignable(ft, et))
            try tc.emitMismatch(spanOf(e.fallback), ft, et);
        return et;
    }

    fn inferCatch(tc: TypeChecker, e: *Ast.ExprCatch) anyerror!Type {
        const et = try tc.inferExpr(e.expr);
        const ft = try tc.inferExpr(e.fallback);
        // The fallback should be assignable to the non-error form of expr's type.
        if (et != .unknown and ft != .unknown and !Type.isAssignable(ft, et))
            try tc.emitMismatch(spanOf(e.fallback), ft, et);
        return et;
    }

    fn inferIfExpr(tc: TypeChecker, e: *Ast.ExprIf) anyerror!Type {
        try tc.checkBoolExpr(e.cond);
        const tt = try tc.inferExpr(e.then_expr);
        const et = try tc.inferExpr(e.else_expr);
        // Both branches should have the same type.
        if (tt != .unknown and et != .unknown and !Type.isAssignable(et, tt))
            try tc.emitMismatch(spanOf(e.else_expr), et, tt);
        return if (tt != .unknown) tt else et;
    }

    fn inferLambda(tc: TypeChecker, e: *Ast.ExprLambda) anyerror!Type {
        const ret = tc.typeFromOptRef(if (e.return_type) |*rt| rt else null);
        const inner = tc.withReturn(ret);
        switch (e.body) {
            .expr  => |ex| _ = try inner.inferExpr(ex),
            .stmts => |ss| try inner.checkStmts(ss),
        }
        return .unknown; // function types not modelled yet
    }

    // ── Symbol type ───────────────────────────────────────────────────────────

    /// Get the value type of `sym`.
    ///
    /// - Variables and parameters → their declared type (or `unknown` if inferred).
    /// - Methods → `unknown` (use `inferCall` to get the return type at a call site).
    /// - Type symbols → `named(sym)` (the symbol represents the type itself).
    fn symbolType(tc: TypeChecker, sym: *const Symbol) Type {
        return switch (sym.kind) {
            .class, .interface, .struct_, .mixin, .enum_ => .{ .named = sym },
            .namespace_   => .unknown, // namespaces are not value-typed
            .method       => .unknown, // use inferCall to resolve the return type
            .property     => {
                const decl = sym.decl.property;
                return tc.typeFromOptRef(if (decl.type_) |*t| t else null);
            },
            .var_, .local => switch (sym.decl) {
                .var_ => |decl| {
                    // Prefer the explicitly declared type.
                    if (decl.type_) |*t| {
                        const declared = tc.typeFromRef(t);
                        if (declared != .unknown) return declared;
                    }
                    // Fall back to the type inferred from the initialiser, if any.
                    if (decl.init) |init| return tc.expr_types.get(init) orelse .unknown;
                    return .unknown;
                },
                .catch_binding => .unknown, // error-binding var — error set type deferred
                else           => .unknown,
            },
            .param => {
                const p = sym.decl.param;
                return tc.typeFromOptRef(if (p.type_) |*t| t else null);
            },
            .enum_member   => .unknown, // TODO: resolve to parent enum type
            .union_        => .{ .named = sym }, // the union type itself
            .union_variant => .unknown, // TODO: resolve to parent union type
            .module        => .unknown, // imported module — cross-file types not yet resolved
        };
    }

    // ── TypeRef → Type ────────────────────────────────────────────────────────

    fn typeFromOptRef(tc: TypeChecker, tr: ?*const Ast.TypeRef) Type {
        return if (tr) |t| tc.typeFromRef(t) else .void_;
    }

    /// Convert a `TypeRef` to a `Type` by consulting the Resolver's side-table.
    ///
    /// Compound types (`?T`, `!T`, generics) return `unknown` — they will be
    /// handled in a later pass that models nilable and error-union wrappers.
    fn typeFromRef(tc: TypeChecker, tr: *const Ast.TypeRef) Type {
        return switch (tr.*) {
            .named => |*n| blk: {
                const resolved = tc.resolve.types.get(n) orelse break :blk .unknown;
                break :blk switch (resolved) {
                    .builtin => builtinType(n.name),
                    .symbol  => |s| .{ .named = s },
                };
            },
            // Compound types deferred to a later pass.
            .nilable, .stream, .error_union, .generic => .unknown,
            .void_ => .void_,
            .same  => if (tc.owner_sym) |s| Type{ .named = s } else .unknown,
        };
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    fn emitError(tc: TypeChecker, span: Ast.Span, comptime fmt: []const u8, args: anytype) anyerror!void {
        const msg = try std.fmt.allocPrint(tc.diag_alloc, fmt, args);
        try tc.diags.append(tc.diag_alloc, .{ .span = span, .kind = .err, .message = msg });
    }

    fn emitMismatch(tc: TypeChecker, span: Ast.Span, actual: Type, expected: Type) anyerror!void {
        try tc.emitError(span, "type mismatch: expected '{s}', got '{s}'", .{ expected.name(), actual.name() });
    }
};

// ── Span extraction ───────────────────────────────────────────────────────────

fn spanOf(expr: *const Ast.Expr) Ast.Span {
    return switch (expr.*) {
        .int_lit       => |e| e.span,
        .float_lit     => |e| e.span,
        .bool_lit      => |e| e.span,
        .char_lit      => |e| e.span,
        .string_lit    => |e| e.span,
        .string_interp => |e| e.span,
        .nil           => |s| s,
        .this          => |s| s,
        .zig_lit       => |e| e.span,
        .ident         => |e| e.span,
        .member        => |e| e.span,
        .call          => |e| e.span,
        .index         => |e| e.span,
        .slice         => |e| e.span,
        .binary        => |e| e.span,
        .unary         => |e| e.span,
        .cast          => |e| e.span,
        .to_nilable    => |e| e.span,
        .to_non_nil    => |e| e.span,
        .is_nil        => |e| e.span,
        .orelse_       => |e| e.span,
        .catch_        => |e| e.span,
        .if_expr       => |e| e.span,
        .lambda        => |e| e.span,
        .list_lit      => |e| e.span,
        .dict_lit      => |e| e.span,
        .array_lit     => |e| e.span,
        .all_any       => |e| e.span,
        .old           => |e| e.span,
        .try_          => |e| e.span,
    };
}

// ── Builtin name → Type ───────────────────────────────────────────────────────

fn builtinType(n: []const u8) Type {
    if (std.mem.eql(u8, n, "StringBuilder"))  return .string_builder;
    if (std.mem.eql(u8, n, "HttpRequest"))    return .http_request;
    if (std.mem.eql(u8, n, "HttpResponse"))   return .http_response;
    if (std.mem.eql(u8, n, "TcpConn"))       return .tcp_conn;
    if (std.mem.eql(u8, n, "UdpSocket"))     return .udp_socket;
    if (std.mem.eql(u8, n, "Regex"))         return .regex;
    if (std.mem.eql(u8, n, "Gui"))          return .gui_context;
    return switch (Builtins.scalarKind(n)) {
        .int        => .int,
        .uint       => .uint,
        .float      => .float,
        .bool       => .bool,
        .char       => .char,
        .string     => .string,
        .void_      => .void_,
        .unknown    => .unknown,
        .int_n   => |bits| .{ .int_n   = bits },
        .uint_n  => |bits| .{ .uint_n  = bits },
        .float_n => |bits| .{ .float_n = bits },
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn checkSnippet(src: []const u8) anyerror!TestResult {
    const Tokenizer  = @import("Tokenizer.zig");
    const Parser     = @import("Parser.zig");
    const AstBuilder = @import("AstBuilder.zig");

    const alloc = testing.allocator;

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
    errdefer sym_arena.deinit();

    const module = try AstBuilder.build(ok, sym_arena.allocator());

    var bind = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind.deinit();

    var resolve = try Resolver.resolvePass2(module, &bind.table, alloc, alloc);

    const tc = try typeCheckPass3(module, &resolve, alloc, alloc);
    return .{ .resolve = resolve, .tc = tc, .sym_arena = sym_arena };
}

const TestResult = struct {
    resolve:   Resolver.ResolveResult,
    tc:        TypeCheckResult,
    sym_arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.tc.deinit();
        self.resolve.deinit();
        self.sym_arena.deinit();
    }
};

test "typecheck: int literal" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        return 42
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: string literal" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as String
        \\        return "hello"
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: bool literal in condition" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run
        \\        if true
        \\            pass
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: param type flows to return" {
    var tr = try checkSnippet(
        \\class Greeter
        \\    def greet(name as String) as String
        \\        return name
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: local var type matches init" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 0
        \\        return x
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: return type mismatch" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        return "oops"
        \\
    );
    defer tr.deinit();
    try testing.expect(tr.tc.hasErrors());
    try testing.expectEqual(@as(usize, 1), tr.tc.diags.len);
    try testing.expect(std.mem.indexOf(u8, tr.tc.diags[0].message, "int") != null);
    try testing.expect(std.mem.indexOf(u8, tr.tc.diags[0].message, "String") != null);
}

test "typecheck: var decl type mismatch" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run
        \\        var x as int = "hello"
        \\
    );
    defer tr.deinit();
    try testing.expect(tr.tc.hasErrors());
    try testing.expectEqual(@as(usize, 1), tr.tc.diags.len);
}

test "typecheck: arithmetic on matching types" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 1
        \\        var y as int = 2
        \\        return x + y
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: arithmetic type mismatch" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 1
        \\        var y as float = 2.0
        \\        return x + y
        \\
    );
    defer tr.deinit();
    try testing.expect(tr.tc.hasErrors());
}

test "typecheck: logical and on bools" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def run as bool
        \\        return true and false
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}

test "typecheck: call return type used in return" {
    var tr = try checkSnippet(
        \\class Foo
        \\    def id(x as int) as int
        \\        return x
        \\    def run as int
        \\        return id(1)
        \\
    );
    defer tr.deinit();
    try testing.expect(!tr.tc.hasErrors());
}
