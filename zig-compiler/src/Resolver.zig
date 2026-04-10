//! Resolver: semantic analysis Pass 2 — resolve all name references.
//!
//! Consumes the populated `SymbolTable` from Pass 1 and records:
//!
//! - Every `TypeRef.named` / `TypeRef.generic` → `ResolvedType`
//! - Every `ExprIdent` in a method/property/lambda body → `*Symbol`
//!
//! Results are stored in side-tables keyed by stable arena pointers into
//! the AST.  The AST itself is not mutated.
//!
//! Pass 2 also declares **locals** — `var`/`const` statements inside method
//! bodies were not processed by Pass 1 (which only hoists top-level names).
//! Locals are inserted into the enclosing method scope in source order, so
//! a variable is not visible before its declaration line.
//!
//! ## Usage
//!
//! ```zig
//! var result = try Resolver.resolvePass2(module, &table, gpa, gpa);
//! defer result.deinit();
//!
//! if (result.hasErrors()) { /* report diagnostics */ }
//! const sym = result.exprs.get(some_ident_ptr);
//! ```

const std      = @import("std");
const Ast      = @import("Ast.zig");
const ST       = @import("SymbolTable.zig");
const Binder   = @import("Binder.zig");
const Builtins = @import("Builtins.zig");

const Allocator   = std.mem.Allocator;
const SymbolTable = ST.SymbolTable;
const Scope       = ST.Scope;
const Symbol      = ST.Symbol;
const SymbolKind  = ST.SymbolKind;
const Diagnostic  = Binder.Diagnostic;
const DiagKind    = Binder.DiagKind;

// ── Primitive / built-in type names ───────────────────────────────────────────
// Single source of truth is Builtins.zig; BUILTINS is kept as an alias.

const BUILTINS = Builtins.NAMES;

// ── Resolution result types ───────────────────────────────────────────────────

/// What a `TypeRef.named` resolved to.
pub const ResolvedType = union(enum) {
    /// One of the language-built-in primitive types (int, bool, String, …).
    builtin,
    /// A user-defined symbol (class, interface, struct, enum, …).
    symbol: *Symbol,
};

pub const ResolveResult = struct {
    /// `NamedTypeRef` pointer → resolution.  Absence means the name failed
    /// to resolve (a diagnostic was emitted).
    types:      std.AutoHashMap(*const Ast.NamedTypeRef, ResolvedType),
    /// `ExprIdent` pointer → the symbol it refers to.  Absence = unresolved.
    exprs:      std.AutoHashMap(*const Ast.ExprIdent, *Symbol),
    diags:      []const Diagnostic,
    diag_alloc: Allocator,

    pub fn hasErrors(self: ResolveResult) bool {
        for (self.diags) |d| if (d.kind == .err) return true;
        return false;
    }

    pub fn deinit(self: *ResolveResult) void {
        for (self.diags) |d| self.diag_alloc.free(d.message);
        self.diag_alloc.free(self.diags);
        self.types.deinit();
        self.exprs.deinit();
    }
};

// ── Public entry point ────────────────────────────────────────────────────────

/// Run Pass 2 on `module` using the already-populated `table`.
///
/// - `table`      — symbol table from `bindPass1`; locals will be added to it.
/// - `map_alloc`  — owns the hash-map entries in `ResolveResult`.
/// - `diag_alloc` — owns the `diags` slice and message strings.
pub fn resolvePass2(
    module:     Ast.Module,
    table:      *SymbolTable,
    map_alloc:  Allocator,
    diag_alloc: Allocator,
) anyerror!ResolveResult {
    var types = std.AutoHashMap(*const Ast.NamedTypeRef, ResolvedType).init(map_alloc);
    var exprs = std.AutoHashMap(*const Ast.ExprIdent, *Symbol).init(map_alloc);
    var diags = std.ArrayList(Diagnostic){};

    const r = Resolver{
        .table      = table,
        .diag_alloc = diag_alloc,
        .types      = &types,
        .exprs      = &exprs,
        .diags      = &diags,
    };

    try r.walkModule(module, table.root);

    return .{
        .types      = types,
        .exprs      = exprs,
        .diags      = try diags.toOwnedSlice(diag_alloc),
        .diag_alloc = diag_alloc,
    };
}

// ── Resolver context ──────────────────────────────────────────────────────────

const Resolver = struct {
    table:      *SymbolTable,
    diag_alloc: Allocator,
    types:      *std.AutoHashMap(*const Ast.NamedTypeRef, ResolvedType),
    exprs:      *std.AutoHashMap(*const Ast.ExprIdent, *Symbol),
    diags:      *std.ArrayList(Diagnostic),

    // ── Module ────────────────────────────────────────────────────────────────

    fn walkModule(r: Resolver, module: Ast.Module, scope: *Scope) anyerror!void {
        for (module.decls) |decl| try r.walkTopDecl(decl, scope);
    }

    fn walkTopDecl(r: Resolver, decl: Ast.Decl, scope: *Scope) anyerror!void {
        switch (decl) {
            .use       => {},
            .namespace => |n| try r.walkNamespace(n, scope),
            .class     => |n| try r.walkClass(n, scope),
            .interface => |n| try r.walkInterface(n, scope),
            .struct_   => |n| try r.walkStruct(n, scope),
            .mixin     => |n| try r.walkMixin(n, scope),
            .enum_     => |n| try r.walkEnum(n, scope),
            .extend    => |n| try r.walkExtend(n, scope),
            .method    => |n| try r.walkMethod(n, scope),
            .property  => |n| try r.walkProperty(n, scope),
            .var_      => |n| try r.walkVarDecl(n, scope),
            .init      => |n| try r.walkInit(n, scope),
            .union_    => |n| try r.walkUnion(n, scope),
        }
    }

    // ── Namespace ─────────────────────────────────────────────────────────────

    fn walkNamespace(r: Resolver, n: *Ast.DeclNamespace, scope: *Scope) anyerror!void {
        const sym = scope.lookupLocal(n.name) orelse return;
        const inner = sym.own_scope orelse return;
        for (n.decls) |decl| try r.walkTopDecl(decl, inner);
    }

    // ── Type declarations ─────────────────────────────────────────────────────

    fn walkClass(r: Resolver, n: *Ast.DeclClass, scope: *Scope) anyerror!void {
        const sym   = scope.lookupLocal(n.name) orelse return;
        const inner = sym.own_scope orelse return;
        for (n.implements) |*tr| try r.resolveTypeRef(tr, scope);
        for (n.adds)       |*tr| try r.resolveTypeRef(tr, scope);
        for (n.invariants) |e|   try r.walkExpr(e, inner);
        for (n.members)    |m|   try r.walkMember(m, inner);
    }

    fn walkInterface(r: Resolver, n: *Ast.DeclInterface, scope: *Scope) anyerror!void {
        const sym   = scope.lookupLocal(n.name) orelse return;
        const inner = sym.own_scope orelse return;
        for (n.implements) |*tr| try r.resolveTypeRef(tr, scope);
        for (n.members)    |m|   try r.walkMember(m, inner);
    }

    fn walkStruct(r: Resolver, n: *Ast.DeclStruct, scope: *Scope) anyerror!void {
        const sym   = scope.lookupLocal(n.name) orelse return;
        const inner = sym.own_scope orelse return;
        for (n.implements) |*tr| try r.resolveTypeRef(tr, scope);
        for (n.invariants) |e|   try r.walkExpr(e, inner);
        for (n.members)    |m|   try r.walkMember(m, inner);
    }

    fn walkMixin(r: Resolver, n: *Ast.DeclMixin, scope: *Scope) anyerror!void {
        const sym   = scope.lookupLocal(n.name) orelse return;
        const inner = sym.own_scope orelse return;
        for (n.members) |m| try r.walkMember(m, inner);
    }

    fn walkUnion(r: Resolver, n: *Ast.DeclUnion, scope: *Scope) anyerror!void {
        // Resolve each variant's payload TypeRef so TypeChecker can infer branch binding types.
        for (n.variants) |*v| {
            if (v.payload) |*payload| try r.resolveTypeRef(payload, scope);
        }
    }

    fn walkEnum(r: Resolver, n: *Ast.DeclEnum, scope: *Scope) anyerror!void {
        if (n.base) |*b| try r.resolveTypeRef(b, scope);
        // Resolve optional explicit values for enum members.
        const sym   = scope.lookupLocal(n.name) orelse return;
        const inner = sym.own_scope orelse return;
        for (n.members) |*m| {
            if (m.value) |v| try r.walkExpr(v, inner);
        }
    }

    fn walkExtend(r: Resolver, n: *Ast.DeclExtend, scope: *Scope) anyerror!void {
        try r.resolveTypeRef(&n.target, scope);
        for (n.members) |m| switch (m) {
            .method => |meth| try r.walkExtMethod(meth, scope),
            else    => try r.walkMember(m, scope),
        };
    }

    /// Walk an extension method.  Unlike regular methods, extension methods
    /// have no Symbol entry in the scope, so we build a fresh inner scope,
    /// resolve types directly, and walk the body ourselves.
    fn walkExtMethod(r: Resolver, n: *Ast.DeclMethod, scope: *Scope) anyerror!void {
        // Resolve param and return types against the enclosing (module) scope.
        for (n.params) |*p| {
            if (p.type_) |*tr| try r.resolveTypeRef(tr, scope);
        }
        if (n.return_type) |*rt| try r.resolveTypeRef(rt, scope);

        // Build a fresh method scope and register params so the body can walk.
        const body_scope = try r.table.newScope(.method, scope);
        for (n.params) |*p| {
            const psym = try r.table.newSymbol(p.name, .param, .{ .param = p });
            _ = try body_scope.define(p.name, psym);
        }
        if (n.body) |body| try r.walkStmts(body, body_scope);
    }

    fn walkMember(r: Resolver, decl: Ast.Decl, scope: *Scope) anyerror!void {
        switch (decl) {
            .method   => |n| try r.walkMethod(n, scope),
            .property => |n| try r.walkProperty(n, scope),
            .var_     => |n| try r.walkVarDecl(n, scope),
            .init     => |n| try r.walkInit(n, scope),
            else      => {},
        }
    }

    // ── Method ────────────────────────────────────────────────────────────────

    fn walkMethod(r: Resolver, n: *Ast.DeclMethod, scope: *Scope) anyerror!void {
        const sym         = scope.lookupLocal(n.name) orelse return;
        const method_scope = sym.own_scope orelse return;

        // Resolve parameter and return types using the enclosing (class) scope
        // so that e.g. `Dog` refers to the class, not the method param.
        for (n.params) |*p| {
            if (p.type_)   |*tr| try r.resolveTypeRef(tr, scope);
            if (p.default) |d|   try r.walkExpr(d, method_scope);
        }
        if (n.return_type) |*rt| try r.resolveTypeRef(rt, scope);

        // Walk body and contracts in the method scope (params are already there).
        if (n.body) |body| try r.walkStmts(body, method_scope);
        for (n.require) |e| try r.walkExpr(e, method_scope);
        for (n.ensure)  |e| try r.walkExpr(e, method_scope);
    }

    // ── Property ──────────────────────────────────────────────────────────────

    fn walkProperty(r: Resolver, n: *Ast.DeclProperty, scope: *Scope) anyerror!void {
        if (n.type_) |*tr| try r.resolveTypeRef(tr, scope);
        // Create a fresh method scope for accessor bodies (no named params).
        if (n.getter != null or n.setter != null) {
            const acc_scope = try r.table.newScope(.method, scope);
            if (n.getter) |body| try r.walkStmts(body, acc_scope);
            if (n.setter) |body| try r.walkStmts(body, acc_scope);
        }
    }

    // ── Field / local variable ────────────────────────────────────────────────

    fn walkVarDecl(r: Resolver, n: *Ast.DeclVar, scope: *Scope) anyerror!void {
        if (n.type_) |*tr| try r.resolveTypeRef(tr, scope);
        if (n.init)  |e|   try r.walkExpr(e, scope);
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    fn walkInit(r: Resolver, n: *Ast.DeclInit, scope: *Scope) anyerror!void {
        const ctor_scope = try r.table.newScope(.method, scope);
        for (n.params) |*p| {
            if (p.type_)   |*tr| try r.resolveTypeRef(tr, scope);
            if (p.default) |d|   try r.walkExpr(d, ctor_scope);
            const psym = try r.table.newSymbol(p.name, .param, .{ .param = p });
            _ = try ctor_scope.define(p.name, psym);
        }
        if (n.body) |body| try r.walkStmts(body, ctor_scope);
        for (n.require) |e| try r.walkExpr(e, ctor_scope);
        for (n.ensure)  |e| try r.walkExpr(e, ctor_scope);
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn walkStmts(r: Resolver, stmts: []const Ast.Stmt, scope: *Scope) anyerror!void {
        for (stmts) |stmt| try r.walkStmt(stmt, scope);
    }

    fn walkStmt(r: Resolver, stmt: Ast.Stmt, scope: *Scope) anyerror!void {
        switch (stmt) {
            .if_      => |s| {
                try r.walkExpr(s.cond, scope);
                try r.walkStmts(s.then_body, scope);
                for (s.else_ifs) |ei| {
                    try r.walkExpr(ei.cond, scope);
                    try r.walkStmts(ei.body, scope);
                }
                if (s.else_body) |eb| try r.walkStmts(eb, scope);
            },
            .while_   => |s| {
                try r.walkExpr(s.cond, scope);
                try r.walkStmts(s.body, scope);
                if (s.post_body) |pb| try r.walkStmts(pb, scope);
            },
            .for_in   => |s| {
                try r.walkExpr(s.iter, scope);
                var body_scope = try r.table.newScope(.block, scope);
                for (s.vars) |vname| {
                    const sym = try r.table.arena.create(Symbol);
                    sym.* = .{ .name = vname, .kind = .local, .decl = .{ .catch_binding = s.span } };
                    _ = try body_scope.define(vname, sym);
                }
                if (s.where) |w| try r.walkExpr(w, body_scope);
                try r.walkStmts(s.body, body_scope);
            },
            .for_num  => |s| {
                try r.walkExpr(s.start, scope);
                try r.walkExpr(s.stop, scope);
                if (s.step) |st| try r.walkExpr(st, scope);
                var body_scope = try r.table.newScope(.block, scope);
                const num_sym = try r.table.arena.create(Symbol);
                num_sym.* = .{ .name = s.var_, .kind = .local, .decl = .{ .catch_binding = s.span } };
                _ = try body_scope.define(s.var_, num_sym);
                try r.walkStmts(s.body, body_scope);
            },
            .branch   => |s| {
                try r.walkExpr(s.expr, scope);
                for (s.on) |on| {
                    for (on.values) |v| try r.walkExpr(v, scope);
                    if (on.binding) |bname| {
                        // Union dispatch: bind the payload variable in a sub-scope.
                        var body_scope = try r.table.newScope(.block, scope);
                        const sym = try r.table.arena.create(Symbol);
                        sym.* = .{ .name = bname, .kind = .local, .decl = .{ .catch_binding = on.span } };
                        _ = try body_scope.define(bname, sym);
                        try r.walkStmts(on.body, body_scope);
                    } else {
                        try r.walkStmts(on.body, scope);
                    }
                }
                if (s.else_) |eb| try r.walkStmts(eb, scope);
            },
            .return_  => |s| { if (s.value) |v| try r.walkExpr(v, scope); },
            .assert   => |s| {
                try r.walkExpr(s.cond, scope);
                if (s.message) |m| try r.walkExpr(m, scope);
            },
            .print    => |s| { for (s.args) |a|   try r.walkExpr(a, scope); },
            .yield    => |s| try r.walkExpr(s.value, scope),
            .assign   => |s| {
                try r.walkExpr(s.target, scope);
                try r.walkExpr(s.value, scope);
            },
            // Local variable declaration: resolve type/init, then add to scope.
            .var_     => |n| try r.walkLocalVar(n, scope),
            .expr     => |e| try r.walkExpr(e, scope),
            .contract => |s| { for (s.exprs) |e| try r.walkExpr(e, scope); },
            .defer_   => |s| try r.walkStmt(s.body, scope),
            .with     => |s| { try r.walkExpr(s.target, scope); try r.walkStmts(s.body, scope); },
            .var_except => |s| {
                if (s.type_ref) |*tr| try r.resolveTypeRef(tr, scope);
                try r.walkExpr(s.base, scope);
                for (s.fields) |f| try r.walkExpr(f.value, scope);
                // Synthesise a DeclVar so this name is visible in subsequent code.
                const dv = try r.table.arena.create(Ast.DeclVar);
                dv.* = .{ .span = s.span, .mods = .{}, .name = s.name,
                           .type_ = s.type_ref, .init = null, .is_const = true };
                const sym = try r.table.newSymbol(s.name, .local, .{ .var_ = dv });
                _ = try scope.define(s.name, sym);
            },
            .assign_except => |s| {
                try r.walkExpr(s.target, scope);
                try r.walkExpr(s.base, scope);
                for (s.fields) |f| try r.walkExpr(f.value, scope);
            },
            .raise    => |s| {
                if (s.message) |m| try r.walkExpr(m, scope);
                if (s.details) |d| try r.walkExpr(d, scope);
            },
            .try_catch => |s| {
                try r.walkStmts(s.body, scope);
                for (s.clauses) |clause| {
                    var clause_scope = try r.table.newScope(.block, scope);
                    if (clause.binding) |bname| {
                        const sym = try r.table.arena.create(Symbol);
                        sym.* = .{ .name = bname, .kind = .local, .decl = .{ .catch_binding = clause.span } };
                        _ = try clause_scope.define(bname, sym);
                    }
                    try r.walkStmts(clause.body, clause_scope);
                }
            },
            .guard => |s| {
                try r.walkExpr(s.cond, scope);
                const guard_scope = try r.table.newScope(.block, scope);
                try r.walkStmts(s.else_body, guard_scope);
            },
            .destruct => |s| {
                try r.walkExpr(s.init, scope);
                // Register each binding name as a local in the current scope.
                for (s.names) |name| {
                    const dv = try r.table.arena.create(Ast.DeclVar);
                    dv.* = .{ .span = s.span, .mods = .{}, .name = name,
                               .type_ = null, .init = null, .is_const = true };
                    const sym = try r.table.newSymbol(name, .local, .{ .var_ = dv });
                    _ = try scope.define(name, sym);
                }
            },
            .pass, .break_, .continue_ => {},
        }
    }

    /// Declare a local variable, then resolve its type and initialiser.
    /// The variable is visible to all subsequent statements in `scope`.
    fn walkLocalVar(r: Resolver, n: *Ast.DeclVar, scope: *Scope) anyerror!void {
        // Sugar: `var x = List(int)` or `var x = HashMap(str, int)` — no `as` annotation.
        // Recognise the pattern and inject the type + replace the init with a zero-arg call.
        if (n.type_ == null) {
            if (n.init) |init| {
                if (init.* == .call and init.call.callee.* == .ident and init.call.args.len > 0) {
                    const cname = init.call.callee.ident.name;
                    if (std.mem.eql(u8, cname, "List") or std.mem.eql(u8, cname, "HashMap")) {
                        // Build TypeRef args from the call's arg idents.
                        var type_args = try r.table.arena.alloc(Ast.TypeRef, init.call.args.len);
                        for (init.call.args, 0..) |arg, i| {
                            if (arg.value.* == .ident) {
                                type_args[i] = .{ .named = .{ .name = arg.value.ident.name, .span = arg.value.ident.span } };
                            } else {
                                // Not a plain type name — bail out of sugar processing.
                                type_args = &.{};
                                break;
                            }
                        }
                        if (type_args.len == init.call.args.len) {
                            n.type_ = .{ .generic = .{
                                .span = init.call.span,
                                .name = cname,
                                .args = type_args,
                            } };
                            // Replace init with a zero-arg call so CodeGen sees `List()`.
                            const new_callee = try r.table.arena.create(Ast.Expr);
                            new_callee.* = .{ .ident = init.call.callee.ident };
                            const new_call = try r.table.arena.create(Ast.ExprCall);
                            new_call.* = .{
                                .span      = init.call.span,
                                .callee    = new_callee,
                                .type_args = &.{},
                                .args      = &.{},
                            };
                            const new_init = try r.table.arena.create(Ast.Expr);
                            new_init.* = .{ .call = new_call };
                            n.init = new_init;
                        }
                    }
                }
            }
        }
        if (n.type_) |*tr| try r.resolveTypeRef(tr, scope);
        if (n.init)  |e|   try r.walkExpr(e, scope);
        const sym = try r.table.newSymbol(n.name, .local, .{ .var_ = n });
        _ = try scope.define(n.name, sym);
    }

    // ── Expressions ───────────────────────────────────────────────────────────

    fn walkExpr(r: Resolver, expr: *const Ast.Expr, scope: *Scope) anyerror!void {
        switch (expr.*) {
            .ident         => |*e| try r.resolveIdent(e, scope),
            .member        => |e| try r.walkExpr(e.object, scope),
            .call          => |e| {
                try r.walkExpr(e.callee, scope);
                for (e.args) |a| try r.walkExpr(a.value, scope);
            },
            .index         => |e| {
                try r.walkExpr(e.object, scope);
                try r.walkExpr(e.index, scope);
            },
            .slice         => |e| {
                try r.walkExpr(e.object, scope);
                if (e.start) |s| try r.walkExpr(s, scope);
                if (e.stop)  |s| try r.walkExpr(s, scope);
            },
            .binary        => |e| {
                try r.walkExpr(e.left, scope);
                try r.walkExpr(e.right, scope);
            },
            .unary         => |e| try r.walkExpr(e.operand, scope),
            .cast          => |e| {
                try r.walkExpr(e.expr, scope);
                try r.resolveTypeRef(&e.target, scope);
            },
            .to_nilable    => |e| try r.walkExpr(e.expr, scope),
            .to_non_nil    => |e| try r.walkExpr(e.expr, scope),
            .is_nil        => |e| try r.walkExpr(e.expr, scope),
            .orelse_       => |e| {
                try r.walkExpr(e.expr, scope);
                try r.walkExpr(e.fallback, scope);
            },
            .catch_        => |e| {
                try r.walkExpr(e.expr, scope);
                // If there's an error binding, add it to a sub-scope.
                if (e.err_var) |ev| {
                    const catch_scope = try r.table.newScope(.block, scope);
                    const esym = try r.table.newSymbol(ev, .local, .{ .catch_binding = e.span });
                    _ = try catch_scope.define(ev, esym);
                    try r.walkExpr(e.fallback, catch_scope);
                } else {
                    try r.walkExpr(e.fallback, scope);
                }
            },
            .if_expr       => |e| {
                try r.walkExpr(e.cond, scope);
                try r.walkExpr(e.then_expr, scope);
                try r.walkExpr(e.else_expr, scope);
            },
            .lambda        => |e| try r.walkLambda(e, scope),
            .list_lit      => |e| {
                if (e.elem_type) |*tr| try r.resolveTypeRef(tr, scope);
                for (e.elems) |el| try r.walkExpr(el, scope);
            },
            .dict_lit      => |e| {
                for (e.entries) |en| {
                    try r.walkExpr(en.key, scope);
                    try r.walkExpr(en.value, scope);
                }
            },
            .array_lit     => |e| { for (e.elems) |el| try r.walkExpr(el, scope); },
            .all_any       => |e| {
                try r.walkExpr(e.iter, scope);
                try r.walkExpr(e.cond, scope);
            },
            .old           => |e| try r.walkExpr(e.expr, scope),
            .try_          => |e| try r.walkExpr(e.expr, scope),
            .tuple_lit     => |e| { for (e.elems) |el| try r.walkExpr(el, scope); },
            .type_check    => |e| try r.walkExpr(e.expr, scope),
            .string_interp => |e| {
                for (e.parts) |p| switch (p) {
                    .expr    => |ex| try r.walkExpr(ex, scope),
                    .literal, .format => {},
                };
            },
            // Atomic — nothing to resolve.
            .int_lit, .float_lit, .bool_lit, .char_lit,
            .string_lit, .zig_lit, .nil, .this => {},
        }
    }

    fn walkLambda(r: Resolver, e: *Ast.ExprLambda, outer: *Scope) anyerror!void {
        const lambda_scope = try r.table.newScope(.method, outer);

        // --- Params ---
        var lambda_local = std.StringHashMap(void).init(r.diag_alloc);
        defer lambda_local.deinit();

        for (e.params) |*p| {
            if (p.type_)   |*tr| try r.resolveTypeRef(tr, outer);
            if (p.default) |d|   try r.walkExpr(d, lambda_scope);
            const psym = try r.table.newSymbol(p.name, .param, .{ .param = p });
            _ = try lambda_scope.define(p.name, psym);
            try lambda_local.put(p.name, {});
        }

        // --- Capture vars: inits/types resolved in OUTER scope; vars
        //     become fields of the lambda struct, visible inside the body. ---
        for (e.capture) |cv| {
            if (cv.type_) |*tr| try r.resolveTypeRef(tr, outer);
            if (cv.init)  |init| try r.walkExpr(init, outer);
            const csym = try r.table.newSymbol(cv.name, .local, .{ .var_ = cv });
            _ = try lambda_scope.define(cv.name, csym);
            try lambda_local.put(cv.name, {});
        }

        if (e.return_type) |*rt| try r.resolveTypeRef(rt, outer);

        // --- Body ---
        switch (e.body) {
            .expr  => |ex| try r.walkExpr(ex, lambda_scope),
            .stmts => |ss| try r.walkStmts(ss, lambda_scope),
        }

        // --- Implicit capture injection ---
        // Scan the body for references to outer-scope locals/params that are not
        // already in lambda_local (explicit captures or params).  For each one,
        // synthesise a DeclVar and extend e.capture so CodeGen emits the struct
        // field and initialiser automatically — no `capture` block needed in source.
        {
            var free_names = std.ArrayList([]const u8){};
            defer free_names.deinit(r.diag_alloc);
            var free_seen = std.StringHashMap(void).init(r.diag_alloc);
            defer free_seen.deinit();
            // Walk body with a CLONE of lambda_local so var decls inside stmt bodies
            // are tracked correctly without polluting the outer lambda_local.
            var scan_local = try lambda_local.clone();
            defer scan_local.deinit();
            switch (e.body) {
                .expr  => |ex| try r.collectFreeVars(ex, &scan_local, &free_names, &free_seen),
                .stmts => |ss| for (ss) |stmt| try r.collectFreeVarsStmt(stmt, &scan_local, &free_names, &free_seen),
            }
            if (free_names.items.len > 0) {
                const new_caps = try r.table.arena.alloc(*Ast.DeclVar, e.capture.len + free_names.items.len);
                for (e.capture, 0..) |cv, i| new_caps[i] = cv;
                for (free_names.items, e.capture.len..) |fname, i| {
                    // Synthesise an init ExprIdent that references the outer variable.
                    const init_expr = try r.table.arena.create(Ast.Expr);
                    init_expr.* = .{ .ident = .{ .name = fname, .span = e.span } };
                    const dv = try r.table.arena.create(Ast.DeclVar);
                    dv.* = .{
                        .span     = e.span,
                        .mods     = .{},
                        .name     = fname,
                        .type_    = null,
                        .init     = init_expr,
                        .is_const = true,
                    };
                    new_caps[i] = dv;
                    // Register in lambda_scope so the body can see it (already walked,
                    // but needed so checkCaptureBoundary below finds it in lambda_local).
                    try lambda_local.put(fname, {});
                }
                e.capture = new_caps;
            }
        }

        // --- Capture enforcement ---
        // After auto-injection above, only genuinely illegal cross-boundary refs remain.
        switch (e.body) {
            .expr  => |ex| try r.checkCaptureBoundary(ex, &lambda_local),
            .stmts => |ss| for (ss) |stmt| try r.checkCaptureBoundaryStmt(stmt, &lambda_local),
        }
    }

    /// Collect all ExprIdent references in `expr` that resolve to outer-scope
    /// locals or params not yet in `local`.  Results are appended to `out`
    /// (deduplicated via `seen`).
    fn collectFreeVars(
        r: Resolver,
        expr: *const Ast.Expr,
        local: *const std.StringHashMap(void),
        out:   *std.ArrayList([]const u8),
        seen:  *std.StringHashMap(void),
    ) anyerror!void {
        switch (expr.*) {
            .ident => |*e| {
                if (r.exprs.get(e)) |sym| {
                    if ((sym.kind == .local or sym.kind == .param) and
                        !local.contains(e.name) and
                        !seen.contains(e.name))
                    {
                        try seen.put(e.name, {});
                        try out.append(r.diag_alloc, e.name);
                    }
                }
            },
            .member        => |e| try r.collectFreeVars(e.object, local, out, seen),
            .call          => |e| {
                try r.collectFreeVars(e.callee, local, out, seen);
                for (e.args) |a| try r.collectFreeVars(a.value, local, out, seen);
            },
            .index         => |e| {
                try r.collectFreeVars(e.object, local, out, seen);
                try r.collectFreeVars(e.index, local, out, seen);
            },
            .binary        => |e| {
                try r.collectFreeVars(e.left, local, out, seen);
                try r.collectFreeVars(e.right, local, out, seen);
            },
            .unary         => |e| try r.collectFreeVars(e.operand, local, out, seen),
            .cast          => |e| try r.collectFreeVars(e.expr, local, out, seen),
            .to_nilable    => |e| try r.collectFreeVars(e.expr, local, out, seen),
            .to_non_nil    => |e| try r.collectFreeVars(e.expr, local, out, seen),
            .is_nil        => |e| try r.collectFreeVars(e.expr, local, out, seen),
            .orelse_       => |e| {
                try r.collectFreeVars(e.expr, local, out, seen);
                try r.collectFreeVars(e.fallback, local, out, seen);
            },
            .catch_        => |e| {
                try r.collectFreeVars(e.expr, local, out, seen);
                try r.collectFreeVars(e.fallback, local, out, seen);
            },
            .if_expr       => |e| {
                try r.collectFreeVars(e.cond, local, out, seen);
                try r.collectFreeVars(e.then_expr, local, out, seen);
                try r.collectFreeVars(e.else_expr, local, out, seen);
            },
            .all_any       => |e| {
                try r.collectFreeVars(e.iter, local, out, seen);
                try r.collectFreeVars(e.cond, local, out, seen);
            },
            .list_lit      => |e| { for (e.elems) |el| try r.collectFreeVars(el, local, out, seen); },
            .array_lit     => |e| { for (e.elems) |el| try r.collectFreeVars(el, local, out, seen); },
            .dict_lit      => |e| {
                for (e.entries) |en| {
                    try r.collectFreeVars(en.key, local, out, seen);
                    try r.collectFreeVars(en.value, local, out, seen);
                }
            },
            // Nested lambdas have their own boundary — don't recurse into them.
            .lambda => {},
            .try_          => |e| try r.collectFreeVars(e.expr, local, out, seen),
            .tuple_lit     => |e| { for (e.elems) |el| try r.collectFreeVars(el, local, out, seen); },
            .type_check    => |e| try r.collectFreeVars(e.expr, local, out, seen),
            // Atomics: nothing to collect.
            .int_lit, .float_lit, .bool_lit, .char_lit,
            .string_lit, .zig_lit, .nil, .this,
            .old, .string_interp, .slice => {},
        }
    }

    /// Statement-level free-variable collector.  Tracks var decls progressively
    /// so inner-lambda-body locals don't get flagged as free variables.
    fn collectFreeVarsStmt(
        r: Resolver,
        stmt: Ast.Stmt,
        local: *std.StringHashMap(void),
        out:   *std.ArrayList([]const u8),
        seen:  *std.StringHashMap(void),
    ) anyerror!void {
        switch (stmt) {
            .var_    => |n| {
                if (n.init) |e| try r.collectFreeVars(e, local, out, seen);
                try local.put(n.name, {});
            },
            .assign  => |s| {
                try r.collectFreeVars(s.target, local, out, seen);
                try r.collectFreeVars(s.value, local, out, seen);
            },
            .return_ => |s| { if (s.value) |v| try r.collectFreeVars(v, local, out, seen); },
            .print   => |s| { for (s.args) |a| try r.collectFreeVars(a, local, out, seen); },
            .expr    => |e| try r.collectFreeVars(e, local, out, seen),
            .if_     => |s| {
                try r.collectFreeVars(s.cond, local, out, seen);
                for (s.then_body) |st| try r.collectFreeVarsStmt(st, local, out, seen);
                for (s.else_ifs)  |ei| {
                    try r.collectFreeVars(ei.cond, local, out, seen);
                    for (ei.body) |st| try r.collectFreeVarsStmt(st, local, out, seen);
                }
                if (s.else_body) |eb| for (eb) |st| try r.collectFreeVarsStmt(st, local, out, seen);
            },
            .while_  => |s| {
                try r.collectFreeVars(s.cond, local, out, seen);
                for (s.body) |st| try r.collectFreeVarsStmt(st, local, out, seen);
            },
            .for_in  => |s| {
                try r.collectFreeVars(s.iter, local, out, seen);
                for (s.body) |st| try r.collectFreeVarsStmt(st, local, out, seen);
            },
            .for_num => |s| {
                try r.collectFreeVars(s.start, local, out, seen);
                try r.collectFreeVars(s.stop, local, out, seen);
                for (s.body) |st| try r.collectFreeVarsStmt(st, local, out, seen);
            },
            .branch  => |s| {
                try r.collectFreeVars(s.expr, local, out, seen);
                for (s.on) |on| {
                    for (on.values) |v| try r.collectFreeVars(v, local, out, seen);
                    for (on.body)   |st| try r.collectFreeVarsStmt(st, local, out, seen);
                }
                if (s.else_) |eb| for (eb) |st| try r.collectFreeVarsStmt(st, local, out, seen);
            },
            .assert  => |s| {
                try r.collectFreeVars(s.cond, local, out, seen);
                if (s.message) |m| try r.collectFreeVars(m, local, out, seen);
            },
            // raise / try_catch / guard have sub-expressions we skip for now;
            // they're unusual inside lambdas and can be revisited when needed.
            else => {},
        }
    }

    /// Walk every ExprIdent in `expr` and error if it resolves across the
    /// lambda boundary without being declared in the `capture` block.
    fn checkCaptureBoundary(
        r: Resolver,
        expr: *const Ast.Expr,
        lambda_local: *const std.StringHashMap(void),
    ) anyerror!void {
        switch (expr.*) {
            .ident => |*e| {
                if (r.exprs.get(e)) |sym| {
                    if ((sym.kind == .local or sym.kind == .param) and
                        !lambda_local.contains(e.name))
                    {
                        const msg = try std.fmt.allocPrint(
                            r.diag_alloc,
                            "'{s}' must be declared in a `capture` block to use it inside a lambda",
                            .{e.name},
                        );
                        try r.diags.append(r.diag_alloc, .{
                            .span = e.span, .kind = .err, .message = msg,
                        });
                    }
                }
            },
            .member        => |e| try r.checkCaptureBoundary(e.object, lambda_local),
            .call          => |e| {
                try r.checkCaptureBoundary(e.callee, lambda_local);
                for (e.args) |a| try r.checkCaptureBoundary(a.value, lambda_local);
            },
            .index         => |e| {
                try r.checkCaptureBoundary(e.object, lambda_local);
                try r.checkCaptureBoundary(e.index, lambda_local);
            },
            .binary        => |e| {
                try r.checkCaptureBoundary(e.left, lambda_local);
                try r.checkCaptureBoundary(e.right, lambda_local);
            },
            .unary         => |e| try r.checkCaptureBoundary(e.operand, lambda_local),
            .cast          => |e| try r.checkCaptureBoundary(e.expr, lambda_local),
            .to_nilable    => |e| try r.checkCaptureBoundary(e.expr, lambda_local),
            .to_non_nil    => |e| try r.checkCaptureBoundary(e.expr, lambda_local),
            .is_nil        => |e| try r.checkCaptureBoundary(e.expr, lambda_local),
            .orelse_       => |e| {
                try r.checkCaptureBoundary(e.expr, lambda_local);
                try r.checkCaptureBoundary(e.fallback, lambda_local);
            },
            .catch_        => |e| {
                try r.checkCaptureBoundary(e.expr, lambda_local);
                try r.checkCaptureBoundary(e.fallback, lambda_local);
            },
            .if_expr       => |e| {
                try r.checkCaptureBoundary(e.cond, lambda_local);
                try r.checkCaptureBoundary(e.then_expr, lambda_local);
                try r.checkCaptureBoundary(e.else_expr, lambda_local);
            },
            .all_any       => |e| {
                try r.checkCaptureBoundary(e.iter, lambda_local);
                try r.checkCaptureBoundary(e.cond, lambda_local);
            },
            .list_lit      => |e| { for (e.elems) |el| try r.checkCaptureBoundary(el, lambda_local); },
            .array_lit     => |e| { for (e.elems) |el| try r.checkCaptureBoundary(el, lambda_local); },
            .dict_lit      => |e| {
                for (e.entries) |en| {
                    try r.checkCaptureBoundary(en.key, lambda_local);
                    try r.checkCaptureBoundary(en.value, lambda_local);
                }
            },
            // Nested lambdas have their own capture boundary — don't recurse.
            .lambda => {},
            .try_          => |e| try r.checkCaptureBoundary(e.expr, lambda_local),
            .tuple_lit     => |e| { for (e.elems) |el| try r.checkCaptureBoundary(el, lambda_local); },
            .type_check    => |e| try r.checkCaptureBoundary(e.expr, lambda_local),
            // Atomics: nothing to check.
            .int_lit, .float_lit, .bool_lit, .char_lit,
            .string_lit, .zig_lit, .nil, .this,
            .old, .string_interp, .slice => {},
        }
    }

    fn checkCaptureBoundaryStmt(
        r: Resolver,
        stmt: Ast.Stmt,
        lambda_local: *std.StringHashMap(void),
    ) anyerror!void {
        switch (stmt) {
            .var_    => |n| {
                if (n.init) |e| try r.checkCaptureBoundary(e, lambda_local);
                // Register this name so later uses inside the lambda body are not
                // flagged as illegal captures — the var is local to the lambda itself.
                try lambda_local.put(n.name, {});
            },
            .assign  => |s| {
                try r.checkCaptureBoundary(s.target, lambda_local);
                try r.checkCaptureBoundary(s.value, lambda_local);
            },
            .return_ => |s| { if (s.value) |v| try r.checkCaptureBoundary(v, lambda_local); },
            .print   => |s| { for (s.args) |a| try r.checkCaptureBoundary(a, lambda_local); },
            .expr    => |e| try r.checkCaptureBoundary(e, lambda_local),
            .if_     => |s| {
                try r.checkCaptureBoundary(s.cond, lambda_local);
                for (s.then_body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
                for (s.else_ifs)  |ei| {
                    try r.checkCaptureBoundary(ei.cond, lambda_local);
                    for (ei.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
                }
                if (s.else_body) |eb| for (eb) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .while_  => |s| {
                try r.checkCaptureBoundary(s.cond, lambda_local);
                for (s.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .for_in  => |s| {
                try r.checkCaptureBoundary(s.iter, lambda_local);
                for (s.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .for_num => |s| {
                try r.checkCaptureBoundary(s.start, lambda_local);
                try r.checkCaptureBoundary(s.stop, lambda_local);
                for (s.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .branch  => |s| {
                try r.checkCaptureBoundary(s.expr, lambda_local);
                for (s.on) |on| {
                    for (on.values) |v| try r.checkCaptureBoundary(v, lambda_local);
                    for (on.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
                }
                if (s.else_) |eb| for (eb) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .assert  => |s| {
                try r.checkCaptureBoundary(s.cond, lambda_local);
                if (s.message) |m| try r.checkCaptureBoundary(m, lambda_local);
            },
            .yield   => |s| try r.checkCaptureBoundary(s.value, lambda_local),
            .defer_  => |s| try r.checkCaptureBoundaryStmt(s.body, lambda_local),
            .with    => |s| {
                try r.checkCaptureBoundary(s.target, lambda_local);
                for (s.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .var_except    => |s| {
                try r.checkCaptureBoundary(s.base, lambda_local);
                for (s.fields) |f| try r.checkCaptureBoundary(f.value, lambda_local);
            },
            .assign_except => |s| {
                try r.checkCaptureBoundary(s.target, lambda_local);
                try r.checkCaptureBoundary(s.base, lambda_local);
                for (s.fields) |f| try r.checkCaptureBoundary(f.value, lambda_local);
            },
            .raise    => |s| {
                if (s.message) |m| try r.checkCaptureBoundary(m, lambda_local);
                if (s.details) |d| try r.checkCaptureBoundary(d, lambda_local);
            },
            .try_catch => |s| {
                for (s.body)    |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
                for (s.clauses) |cl| for (cl.body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .guard => |s| {
                try r.checkCaptureBoundary(s.cond, lambda_local);
                for (s.else_body) |st| try r.checkCaptureBoundaryStmt(st, lambda_local);
            },
            .destruct => |s| try r.checkCaptureBoundary(s.init, lambda_local),
            .contract, .pass, .break_, .continue_ => {},
        }
    }

    // ── Type-reference resolution ─────────────────────────────────────────────

    fn resolveTypeRef(r: Resolver, tr: *const Ast.TypeRef, scope: *Scope) anyerror!void {
        switch (tr.*) {
            .named       => |*n| try r.resolveNamedRef(n, scope),
            .nilable     => |inner| try r.resolveTypeRef(inner, scope),
            .stream      => |inner| try r.resolveTypeRef(inner, scope),
            .error_union => |inner| try r.resolveTypeRef(inner, scope),
            .generic     => |*g| {
                if (scope.lookup(g.name) == null and BUILTINS.get(g.name) == null)
                    try r.emitUnresolved(g.span, g.name);
                for (g.args) |*arg| try r.resolveTypeRef(arg, scope);
            },
            .void_, .same => {},
            .tuple => |*ttr| { for (ttr.elems) |*el| try r.resolveTypeRef(el, scope); },
        }
    }

    fn resolveNamedRef(r: Resolver, n: *const Ast.NamedTypeRef, scope: *Scope) anyerror!void {
        if (BUILTINS.get(n.name) != null or Builtins.isDynamicSizedNumeric(n.name)) {
            try r.types.put(n, .builtin);
            return;
        }
        if (scope.lookup(n.name)) |sym| {
            try r.types.put(n, .{ .symbol = sym });
        } else {
            try r.emitUnresolved(n.span, n.name);
        }
    }

    // ── Identifier resolution ─────────────────────────────────────────────────

    fn resolveIdent(r: Resolver, e: *const Ast.ExprIdent, scope: *Scope) anyerror!void {
        if (scope.lookup(e.name)) |sym| {
            try r.exprs.put(e, sym);
        } else if (BUILTINS.get(e.name) != null) {
            // Stdlib type names used as constructor expressions (e.g. List(), HashMap())
            // are valid — no error, and no symbol to record.
        } else {
            try r.emitUnresolved(e.span, e.name);
        }
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    fn emitUnresolved(r: Resolver, span: Ast.Span, name: []const u8) anyerror!void {
        const msg = try std.fmt.allocPrint(r.diag_alloc, "'{s}' is not defined", .{name});
        try r.diags.append(r.diag_alloc, .{ .span = span, .kind = .err, .message = msg });
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn resolveSnippet(src: []const u8) anyerror!TestResult {
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
    var bind_result = try Binder.bindPass1(module, sym_arena.allocator(), alloc);
    defer bind_result.deinit();

    const result = try resolvePass2(module, &bind_result.table, alloc, alloc);
    return .{ .result = result, .sym_arena = sym_arena };
}

const TestResult = struct {
    result:    ResolveResult,
    sym_arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.result.deinit();
        self.sym_arena.deinit();
    }
};

test "resolve: primitive type in field" {
    var tr = try resolveSnippet(
        \\class Point
        \\    var x as int
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());
    // The 'int' TypeRef should be in the resolved-types map as a builtin.
    try testing.expect(tr.result.types.count() == 1);
    var it0 = tr.result.types.iterator();
    const entry = it0.next().?;
    try testing.expectEqual(ResolvedType.builtin, entry.value_ptr.*);
}

test "resolve: class reference in implements" {
    var tr = try resolveSnippet(
        \\interface Printable
        \\    def render
        \\class Doc
        \\    var name as String
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());
}

test "resolve: method param type and return type" {
    var tr = try resolveSnippet(
        \\class Greeter
        \\    def greet(name as String) as String
        \\        return name
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());
    // 'name' ident in return should resolve to the param symbol.
    try testing.expect(tr.result.exprs.count() == 1);
    var it1 = tr.result.exprs.iterator();
    const sym = it1.next().?.value_ptr.*;
    try testing.expectEqual(SymbolKind.param, sym.kind);
}

test "resolve: local variable visible after declaration" {
    var tr = try resolveSnippet(
        \\class Foo
        \\    def run as int
        \\        var x as int = 0
        \\        return x
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());
    // 'x' in return resolves to the local.
    try testing.expect(tr.result.exprs.count() == 1);
    var it2 = tr.result.exprs.iterator();
    const sym = it2.next().?.value_ptr.*;
    try testing.expectEqual(SymbolKind.local, sym.kind);
}

test "resolve: unknown type emits error" {
    var tr = try resolveSnippet(
        \\class Foo
        \\    var x as NoSuchType
        \\
    );
    defer tr.deinit();

    try testing.expect(tr.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), tr.result.diags.len);
    try testing.expect(std.mem.indexOf(u8, tr.result.diags[0].message, "NoSuchType") != null);
}

test "resolve: unknown ident in body emits error" {
    var tr = try resolveSnippet(
        \\class Foo
        \\    def run as int
        \\        return missing
        \\
    );
    defer tr.deinit();

    try testing.expect(tr.result.hasErrors());
    try testing.expect(std.mem.indexOf(u8, tr.result.diags[0].message, "missing") != null);
}

test "resolve: cross-class reference" {
    var tr = try resolveSnippet(
        \\class Animal
        \\    var name as String
        \\class Zoo
        \\    var resident as Animal
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());
    // 'Animal' TypeRef should resolve to the class symbol.
    var found_animal = false;
    var it = tr.result.types.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .symbol => |sym| if (std.mem.eql(u8, sym.name, "Animal")) { found_animal = true; },
            .builtin => {},
        }
    }
    try testing.expect(found_animal);
}
