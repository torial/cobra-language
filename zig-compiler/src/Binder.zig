//! Binder: semantic analysis Pass 1 — forward-declare all named symbols.
//!
//! ## What Pass 1 does
//!
//! Walk the AST and register every named declaration in the `SymbolTable`
//! **before** resolving any type references or expression names.  After Pass 1:
//!
//! - Every class / interface / struct / mixin / enum is in the module scope.
//! - Every namespace groups its children in a child scope.
//! - Every method, property, and field is in its owning type's scope.
//! - Every method parameter is in the method's own scope.
//! - Every enum member is in the enum's own scope.
//!
//! Forward-declaring everything first means Pass 2 (name resolution) can
//! resolve forward references and mutually recursive types without any
//! ordering constraints.
//!
//! ## Diagnostics
//!
//! Pass 1 emits `Diagnostic` errors for duplicate declarations.  It does
//! **not** emit errors for unresolved names — that is Pass 2's job.
//!
//! ## Usage
//!
//! ```zig
//! var sym_arena = std.heap.ArenaAllocator.init(gpa);
//! defer sym_arena.deinit();
//!
//! var result = try Binder.bindPass1(module, sym_arena.allocator(), gpa);
//! defer result.deinit();
//!
//! for (result.diags) |d| { /* report errors */ }
//! const table = result.table;
//! ```

const std = @import("std");
const Ast = @import("Ast.zig");
const ST  = @import("SymbolTable.zig");

const Allocator   = std.mem.Allocator;
const SymbolTable = ST.SymbolTable;
const Scope       = ST.Scope;
const Symbol      = ST.Symbol;
const SymbolKind  = ST.SymbolKind;
const DeclRef     = ST.DeclRef;

// ── Diagnostics ───────────────────────────────────────────────────────────────

pub const DiagKind = enum { err, warn };

pub const Diagnostic = struct {
    span:    Ast.Span,
    kind:    DiagKind,
    /// Human-readable message.  Allocated into the `diag_alloc` passed to
    /// `bindPass1` — freed when the caller frees `BindResult.diags`.
    message: []const u8,
};

// ── Result ────────────────────────────────────────────────────────────────────

pub const BindResult = struct {
    table:      SymbolTable,
    diags:      []const Diagnostic,
    /// Allocator that owns `diags` and each `Diagnostic.message`.  Stored so
    /// that `deinit` can free without the caller threading the allocator back in.
    diag_alloc: Allocator,

    pub fn hasErrors(self: BindResult) bool {
        for (self.diags) |d| if (d.kind == .err) return true;
        return false;
    }

    pub fn deinit(self: BindResult) void {
        for (self.diags) |d| self.diag_alloc.free(d.message);
        self.diag_alloc.free(self.diags);
    }
};

// ── Public entry point ────────────────────────────────────────────────────────

/// Run Pass 1 on `module`.
///
/// - `sym_arena` — owns all `Symbol` and `Scope` objects.
/// - `diag_alloc` — owns the `diags` slice and message strings in `BindResult`.
pub fn bindPass1(module: Ast.Module, sym_arena: Allocator, diag_alloc: Allocator) anyerror!BindResult {
    var table = try SymbolTable.init(sym_arena);
    var diags = std.ArrayList(Diagnostic){};
    const b = Binder{ .table = &table, .diag_alloc = diag_alloc, .diags = &diags };
    try b.declareModule(module, table.root);
    return .{
        .table      = table,
        .diags      = try diags.toOwnedSlice(diag_alloc),
        .diag_alloc = diag_alloc,
    };
}

// ── Binder context ────────────────────────────────────────────────────────────

const Binder = struct {
    table:      *SymbolTable,
    diag_alloc: Allocator,
    diags:      *std.ArrayList(Diagnostic),

    // ── Module ────────────────────────────────────────────────────────────────

    fn declareModule(b: Binder, module: Ast.Module, scope: *Scope) anyerror!void {
        for (module.decls) |decl| try b.declareTopDecl(decl, scope);
    }

    // ── Top-level declarations ────────────────────────────────────────────────

    fn declareTopDecl(b: Binder, decl: Ast.Decl, scope: *Scope) anyerror!void {
        switch (decl) {
            .use       => |u| try b.declareUse(u, scope),
            .namespace => |n| try b.declareNamespace(n, scope),
            .class     => |n| try b.declareClass(n, scope),
            .interface => |n| try b.declareInterface(n, scope),
            .struct_   => |n| try b.declareStruct_(n, scope),
            .mixin     => |n| try b.declareMixin(n, scope),
            .enum_     => |n| try b.declareEnum_(n, scope),
            .extend    => {},  // target type not yet resolved; handled in Pass 2
            .method    => |n| try b.declareMethod(n, scope),
            .property  => |n| try b.declareProperty(n, scope),
            .var_      => |n| try b.declareVar_(n, scope),
            .init      => {},  // constructors have no name to declare
            .union_    => |n| try b.declareUnion(n, scope),
            .sig_      => |n| try b.declareSig(n, scope),
        }
    }

    // ── Namespace ─────────────────────────────────────────────────────────────

    fn declareNamespace(b: Binder, n: *Ast.DeclNamespace, scope: *Scope) anyerror!void {
        const sym = try b.table.newSymbol(n.name, .namespace_, .{ .namespace_ = n });
        // If the namespace already exists (split across files), reuse its scope.
        if (try scope.define(n.name, sym)) |existing| {
            if (existing.kind == .namespace_ and existing.own_scope != null) {
                // Merge into the existing namespace scope.
                for (n.decls) |decl| try b.declareTopDecl(decl, existing.own_scope.?);
                return;
            }
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        const ns_scope = try b.table.newScope(.namespace_, scope);
        sym.own_scope = ns_scope;
        for (n.decls) |decl| try b.declareTopDecl(decl, ns_scope);
    }

    // ── Type declarations ─────────────────────────────────────────────────────

    fn declareClass(b: Binder, n: *Ast.DeclClass, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .class, .{ .class = n });
        const inner = try b.table.newScope(.type_, scope);
        sym.own_scope = inner;
        if (try scope.define(n.name, sym)) |_| {
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        for (n.members) |m| try b.declareMember(m, inner);
    }

    fn declareInterface(b: Binder, n: *Ast.DeclInterface, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .interface, .{ .interface = n });
        const inner = try b.table.newScope(.type_, scope);
        sym.own_scope = inner;
        if (try scope.define(n.name, sym)) |_| {
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        for (n.members) |m| try b.declareMember(m, inner);
    }

    fn declareStruct_(b: Binder, n: *Ast.DeclStruct, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .struct_, .{ .struct_ = n });
        const inner = try b.table.newScope(.type_, scope);
        sym.own_scope = inner;
        if (try scope.define(n.name, sym)) |_| {
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        for (n.members) |m| try b.declareMember(m, inner);
    }

    fn declareMixin(b: Binder, n: *Ast.DeclMixin, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .mixin, .{ .mixin = n });
        const inner = try b.table.newScope(.type_, scope);
        sym.own_scope = inner;
        if (try scope.define(n.name, sym)) |_| {
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        for (n.members) |m| try b.declareMember(m, inner);
    }

    fn declareEnum_(b: Binder, n: *Ast.DeclEnum, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .enum_, .{ .enum_ = n });
        const inner = try b.table.newScope(.type_, scope);
        sym.own_scope = inner;
        if (try scope.define(n.name, sym)) |_| {
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        for (n.members) |*m| {
            const msym = try b.table.newSymbol(m.name, .enum_member, .{ .enum_member = m });
            if (try inner.define(m.name, msym)) |_|
                try b.emitDuplicateError(m.span, m.name);
        }
    }

    fn declareUnion(b: Binder, n: *Ast.DeclUnion, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .union_, .{ .union_ = n });
        const inner = try b.table.newScope(.type_, scope);
        sym.own_scope = inner;
        if (try scope.define(n.name, sym)) |_| {
            try b.emitDuplicateError(n.span, n.name);
            return;
        }
        for (n.variants) |*v| {
            const vsym = try b.table.newSymbol(v.name, .union_variant, .{ .union_variant = v });
            if (try inner.define(v.name, vsym)) |_|
                try b.emitDuplicateError(v.span, v.name);
        }
    }

    fn declareSig(b: Binder, n: *Ast.DeclSig, scope: *Scope) anyerror!void {
        const sym = try b.table.newSymbol(n.name, .sig_, .{ .sig_ = n });
        if (try scope.define(n.name, sym)) |_|
            try b.emitDuplicateError(n.span, n.name);
    }

    fn declareUse(b: Binder, n: *Ast.DeclUse, scope: *Scope) anyerror!void {
        // Register the last path segment as a module alias so Resolver doesn't
        // flag it as undefined.  e.g. `use Math.Utils` → alias `Utils`.
        const last_dot = std.mem.lastIndexOf(u8, n.path, ".");
        const alias = if (last_dot) |d| n.path[d + 1 ..] else n.path;
        const sym = try b.table.newSymbol(alias, .module, .{ .use = n });
        if (try scope.define(alias, sym)) |_| {
            try b.emitDuplicateError(n.span, alias);
        }
        // For selective imports (`use Mod exposing Name1, Name2`), register each
        // exposed name as an additional `.module` symbol so ident/type-ref resolution
        // doesn't error on bare `Name1` usage.  The same `DeclUse` pointer is stored
        // so CodeGen can recover the module alias from `sym.decl.use.path`.
        for (n.exposing) |exp_name| {
            if (std.mem.eql(u8, exp_name, alias)) continue; // already registered above
            const exp_sym = try b.table.newSymbol(exp_name, .module, .{ .use = n });
            _ = try scope.define(exp_name, exp_sym);
        }
    }

    // ── Member declarations ───────────────────────────────────────────────────

    fn declareMember(b: Binder, decl: Ast.Decl, scope: *Scope) anyerror!void {
        switch (decl) {
            .method   => |n| try b.declareMethod(n, scope),
            .property => |n| try b.declareProperty(n, scope),
            .var_     => |n| try b.declareVar_(n, scope),
            .init     => {},  // constructors are unnamed
            else      => {},  // nested types etc. handled as top-level when needed
        }
    }

    fn declareMethod(b: Binder, n: *Ast.DeclMethod, scope: *Scope) anyerror!void {
        const sym   = try b.table.newSymbol(n.name, .method, .{ .method = n });
        const inner = try b.table.newScope(.method, scope);
        sym.own_scope = inner;
        // Methods may be overloaded — only flag a conflict if the existing
        // symbol is not also a method.
        if (try scope.define(n.name, sym)) |existing| {
            if (existing.kind != .method)
                try b.emitDuplicateError(n.span, n.name);
            // Overloaded methods: keep first registration; Pass 2 will collect
            // all overloads when resolving calls.
        }
        // Declare parameters in the method's own scope.
        for (n.params) |*p| {
            const psym = try b.table.newSymbol(p.name, .param, .{ .param = p });
            if (try inner.define(p.name, psym)) |_|
                try b.emitDuplicateError(p.span, p.name);
        }
    }

    fn declareProperty(b: Binder, n: *Ast.DeclProperty, scope: *Scope) anyerror!void {
        const sym = try b.table.newSymbol(n.name, .property, .{ .property = n });
        if (try scope.define(n.name, sym)) |_|
            try b.emitDuplicateError(n.span, n.name);
    }

    fn declareVar_(b: Binder, n: *Ast.DeclVar, scope: *Scope) anyerror!void {
        const kind: SymbolKind = if (scope.kind == .method or scope.kind == .block) .local else .var_;
        const sym = try b.table.newSymbol(n.name, kind, .{ .var_ = n });
        if (try scope.define(n.name, sym)) |_|
            try b.emitDuplicateError(n.span, n.name);
    }

    // ── Diagnostic helpers ────────────────────────────────────────────────────

    fn emitDuplicateError(b: Binder, span: Ast.Span, name: []const u8) anyerror!void {
        const msg = try std.fmt.allocPrint(b.diag_alloc, "'{s}' is already defined in this scope", .{name});
        try b.diags.append(b.diag_alloc, .{ .span = span, .kind = .err, .message = msg });
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Shared test helper: parse a snippet and run Pass 1.
const TestResult = struct {
    result: BindResult,
    sym_arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.result.deinit();
        self.sym_arena.deinit();
    }
};

fn bindSnippet(src: []const u8) anyerror!TestResult {
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
    const result = try bindPass1(module, sym_arena.allocator(), alloc);
    return .{ .result = result, .sym_arena = sym_arena };
}

test "bind: simple class" {
    var tr = try bindSnippet(
        \\class Dog
        \\    var name as String
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());

    const dog = tr.result.table.root.lookupLocal("Dog");
    try testing.expect(dog != null);
    try testing.expectEqual(SymbolKind.class, dog.?.kind);

    // 'name' is a member of Dog's scope
    const dog_scope = dog.?.own_scope.?;
    const name_sym = dog_scope.lookupLocal("name");
    try testing.expect(name_sym != null);
    try testing.expectEqual(SymbolKind.var_, name_sym.?.kind);
}

test "bind: method with params" {
    var tr = try bindSnippet(
        \\class Greeter
        \\    def greet(name as String) as String
        \\        return name
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());

    const greeter = tr.result.table.root.lookupLocal("Greeter");
    try testing.expect(greeter != null);

    const greeter_scope = greeter.?.own_scope.?;
    const greet = greeter_scope.lookupLocal("greet");
    try testing.expect(greet != null);
    try testing.expectEqual(SymbolKind.method, greet.?.kind);

    // 'name' param is in the method's own scope
    const method_scope = greet.?.own_scope.?;
    const param = method_scope.lookupLocal("name");
    try testing.expect(param != null);
    try testing.expectEqual(SymbolKind.param, param.?.kind);
}

test "bind: namespace contains class" {
    var tr = try bindSnippet(
        \\namespace Animals
        \\    class Cat
        \\        var age as int
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());

    const animals = tr.result.table.root.lookupLocal("Animals");
    try testing.expect(animals != null);
    try testing.expectEqual(SymbolKind.namespace_, animals.?.kind);

    const ns_scope = animals.?.own_scope.?;
    const cat = ns_scope.lookupLocal("Cat");
    try testing.expect(cat != null);
    try testing.expectEqual(SymbolKind.class, cat.?.kind);
}

test "bind: enum members in enum scope" {
    var tr = try bindSnippet(
        \\enum Color
        \\    Red
        \\    Green
        \\    Blue
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());

    const color = tr.result.table.root.lookupLocal("Color");
    try testing.expect(color != null);
    try testing.expectEqual(SymbolKind.enum_, color.?.kind);

    const enum_scope = color.?.own_scope.?;
    try testing.expect(enum_scope.lookupLocal("Red")   != null);
    try testing.expect(enum_scope.lookupLocal("Green") != null);
    try testing.expect(enum_scope.lookupLocal("Blue")  != null);
}

test "bind: duplicate class name emits error" {
    var tr = try bindSnippet(
        \\class Foo
        \\    var x as int
        \\class Foo
        \\    var y as int
        \\
    );
    defer tr.deinit();

    try testing.expect(tr.result.hasErrors());
    try testing.expectEqual(@as(usize, 1), tr.result.diags.len);
    try testing.expect(std.mem.indexOf(u8, tr.result.diags[0].message, "Foo") != null);
}

test "bind: scope chain lookup" {
    var tr = try bindSnippet(
        \\class Outer
        \\    def check(x as int) as bool
        \\        return x > 0
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());

    // 'Outer' is visible from root
    try testing.expect(tr.result.table.root.lookup("Outer") != null);

    // 'check' is not in root scope
    try testing.expect(tr.result.table.root.lookupLocal("check") == null);

    // 'check' is visible from Outer's scope
    const outer_scope = tr.result.table.root.lookupLocal("Outer").?.own_scope.?;
    try testing.expect(outer_scope.lookup("check") != null);

    // 'x' param is visible from method scope
    const method_scope = outer_scope.lookupLocal("check").?.own_scope.?;
    try testing.expect(method_scope.lookup("x") != null);
    // and from Outer's scope via chain? No — params are only in method scope
    try testing.expect(outer_scope.lookupLocal("x") == null);
}

test "bind: multiple classes in one module" {
    var tr = try bindSnippet(
        \\class Point
        \\    var x as int
        \\    var y as int
        \\class Circle
        \\    var center as Point
        \\    var radius as float
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());
    try testing.expect(tr.result.table.root.lookupLocal("Point")  != null);
    try testing.expect(tr.result.table.root.lookupLocal("Circle") != null);
}

test "bind: interface with method signatures" {
    var tr = try bindSnippet(
        \\interface Drawable
        \\    def draw
        \\    def resize(factor as float)
        \\
    );
    defer tr.deinit();

    try testing.expect(!tr.result.hasErrors());

    const drawable = tr.result.table.root.lookupLocal("Drawable");
    try testing.expect(drawable != null);
    try testing.expectEqual(SymbolKind.interface, drawable.?.kind);

    const scope = drawable.?.own_scope.?;
    try testing.expect(scope.lookupLocal("draw")   != null);
    try testing.expect(scope.lookupLocal("resize") != null);
}

