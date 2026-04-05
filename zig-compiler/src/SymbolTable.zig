//! Symbol table for the Zebra semantic analysis phase.
//!
//! ## Structure
//!
//! The symbol table is a **scope tree**: each `Scope` has a parent pointer and
//! a name→symbol map.  Lookup walks the parent chain, giving standard lexical
//! scoping behaviour.
//!
//! Every named entity in the source (class, method, variable, …) is
//! represented by a `Symbol`.  Type declarations (classes, interfaces, …) and
//! methods own a child `Scope` where their members and parameters live.
//!
//! ## Allocation
//!
//! All `Scope` and `Symbol` objects are allocated into a caller-supplied
//! arena.  The caller frees the arena when the compilation unit is complete.
//! Individual scopes and symbols are never explicitly freed.
//!
//! ## Usage
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(gpa);
//! defer arena.deinit();
//!
//! var table = try SymbolTable.init(arena.allocator());
//! // … binding pass populates it …
//! const sym = table.root.lookup("MyClass");
//! ```

const std = @import("std");
const Ast = @import("Ast.zig");

const Allocator = std.mem.Allocator;

// ── Scope kind ────────────────────────────────────────────────────────────────

pub const ScopeKind = enum {
    /// Top-level module scope — holds namespace and type declarations.
    module,
    /// A `namespace Foo` block — child of module or another namespace.
    namespace_,
    /// Body of a class / interface / struct / mixin / enum.
    type_,
    /// Method or property body — parameters and locals live here.
    method,
    /// Inner block inside a method (if/while/for body).
    block,
};

// ── Symbol kind ───────────────────────────────────────────────────────────────

pub const SymbolKind = enum {
    namespace_,
    class,
    interface,
    struct_,
    mixin,
    enum_,
    /// Regular method (`def`).
    method,
    /// Property (`get`/`set`/`pro`).
    property,
    /// Field / member variable (`var` or `const`).
    var_,
    /// Method parameter.
    param,
    /// Local variable declared inside a method body.
    local,
    /// Named constant inside an `enum` body.
    enum_member,
    /// Variant of a discriminated union (`union` type body).
    union_variant,
    /// Discriminated union type.
    union_,
    /// Imported module alias introduced by a `use` directive.
    module,
};

// ── Declaration reference ─────────────────────────────────────────────────────
//
// Each symbol holds a typed pointer back into the AST so that later passes
// can retrieve the full declaration (modifiers, type annotations, body, …).

pub const DeclRef = union(enum) {
    namespace_:  *Ast.DeclNamespace,
    class:       *Ast.DeclClass,
    interface:   *Ast.DeclInterface,
    struct_:     *Ast.DeclStruct,
    mixin:       *Ast.DeclMixin,
    enum_:       *Ast.DeclEnum,
    extend:      *Ast.DeclExtend,
    method:      *Ast.DeclMethod,
    property:    *Ast.DeclProperty,
    var_:        *Ast.DeclVar,
    /// Points into the owning `DeclMethod.params` slice (stable, arena-owned).
    param:         *const Ast.Param,
    /// Points into the owning `DeclEnum.members` slice.
    enum_member:   *const Ast.EnumMember,
    /// Implicit error-binding variable introduced by `catch |e| ...`.
    /// Stores the span of the catch expression for diagnostic purposes.
    catch_binding: Ast.Span,
    /// Points into the owning `DeclUnion.variants` slice.
    union_variant: *const Ast.UnionVariant,
    /// Discriminated union type declaration.
    union_:        *Ast.DeclUnion,
    /// `use` directive — the alias names the imported module.
    use:           *Ast.DeclUse,
};

// ── Symbol ────────────────────────────────────────────────────────────────────

pub const Symbol = struct {
    name:      []const u8,
    kind:      SymbolKind,
    decl:      DeclRef,
    /// The scope owned by this symbol, if any.
    ///
    /// Set for types (class/interface/struct/mixin/enum), namespaces, and
    /// methods.  The owned scope is where the symbol's members / parameters
    /// are declared.
    own_scope: ?*Scope = null,
};

// ── Scope ─────────────────────────────────────────────────────────────────────

pub const Scope = struct {
    kind:    ScopeKind,
    parent:  ?*Scope,
    symbols: std.StringHashMap(*Symbol),

    /// Define `sym` under `name` in this scope.
    ///
    /// Returns `null` on success.  Returns the **existing** symbol if the
    /// name is already taken (caller decides whether that is an error).
    pub fn define(self: *Scope, name: []const u8, sym: *Symbol) !?*Symbol {
        const r = try self.symbols.getOrPut(name);
        if (r.found_existing) return r.value_ptr.*;
        r.value_ptr.* = sym;
        return null;
    }

    /// Look up `name` in this scope and all enclosing scopes.
    pub fn lookup(self: *const Scope, name: []const u8) ?*Symbol {
        var s: ?*const Scope = self;
        while (s) |scope| {
            if (scope.symbols.get(name)) |sym| return sym;
            s = scope.parent;
        }
        return null;
    }

    /// Look up `name` in this scope only (no parent chain).
    pub fn lookupLocal(self: *const Scope, name: []const u8) ?*Symbol {
        return self.symbols.get(name);
    }
};

// ── SymbolTable ───────────────────────────────────────────────────────────────

pub const SymbolTable = struct {
    root:  *Scope,
    arena: Allocator,

    /// Create a new symbol table.  `arena` must outlive the table.
    pub fn init(arena: Allocator) !SymbolTable {
        const root = try arena.create(Scope);
        root.* = .{
            .kind    = .module,
            .parent  = null,
            .symbols = std.StringHashMap(*Symbol).init(arena),
        };
        return .{ .root = root, .arena = arena };
    }

    /// Allocate a new child scope under `parent`.
    pub fn newScope(self: *SymbolTable, kind: ScopeKind, parent: *Scope) !*Scope {
        const scope = try self.arena.create(Scope);
        scope.* = .{
            .kind    = kind,
            .parent  = parent,
            .symbols = std.StringHashMap(*Symbol).init(self.arena),
        };
        return scope;
    }

    /// Allocate a new symbol.  Caller must call `scope.define()` to insert it.
    pub fn newSymbol(self: *SymbolTable, name: []const u8, kind: SymbolKind, decl: DeclRef) !*Symbol {
        const sym = try self.arena.create(Symbol);
        sym.* = .{ .name = name, .kind = kind, .decl = decl };
        return sym;
    }
};
