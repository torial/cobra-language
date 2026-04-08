//! Zebra Abstract Syntax Tree node types.
//!
//! ## Allocation model
//!
//! All nodes are arena-allocated: one `std.heap.ArenaAllocator` per
//! compilation unit, freed in bulk after code generation.  No node has a
//! `deinit` method.  Pointers into the arena remain valid until the arena
//! is freed.
//!
//! The entry point for a compilation unit is `Module` — a flat list of
//! top-level declarations.
//!
//! ## Source locations
//!
//! Every node carries a `Span` covering its first and last source token.
//! Use the `span` field when reporting diagnostics.
//!
//! ## Naming convention
//!
//! - `Decl*`  — declarations (class, method, var, …)
//! - `Stmt*`  — statements (if, while, return, …)
//! - `Expr*`  — expressions (literals, calls, binary ops, …)
//! - `TypeRef` — a type expression (not a declaration)

const std = @import("std");

// ── Source location ───────────────────────────────────────────────────────────

/// Source range covered by a node — from the first token's start to the
/// last token's end.  All values are 1-based.
pub const Span = struct {
    line:     u32,
    col:      u16,
    end_line: u32,
    end_col:  u16,
};

// ── Top-level ─────────────────────────────────────────────────────────────────

/// A single Zebra source file.
pub const Module = struct {
    /// Path of the source file (owned by the arena or a static string).
    file: []const u8,
    decls: []const Decl,
};

// ── Declarations ──────────────────────────────────────────────────────────────

pub const Decl = union(enum) {
    use: *DeclUse,
    namespace: *DeclNamespace,
    class: *DeclClass,
    interface: *DeclInterface,
    struct_: *DeclStruct,
    mixin: *DeclMixin,
    enum_: *DeclEnum,
    method: *DeclMethod,
    property: *DeclProperty,
    var_: *DeclVar,
    init: *DeclInit,
    extend: *DeclExtend,
    union_: *DeclUnion,
};

/// `use Foo.Bar` — module import directive.
pub const DeclUse = struct {
    span: Span,
    /// Full dotted path as raw text, e.g. `"System.Collections"`.
    path: []const u8,
};

/// `namespace Foo` — groups declarations under a dotted namespace name.
pub const DeclNamespace = struct {
    span:  Span,
    name:  []const u8,
    decls: []const Decl,
};

// ── Error type for AstBuilder ─────────────────────────────────────────────────

/// Errors that can occur while lowering the CST to an AST.
pub const BuildError = std.mem.Allocator.Error;

// ── Modifiers ─────────────────────────────────────────────────────────────────

/// Visibility / behaviour modifiers that can appear on declarations.
pub const Modifiers = packed struct {
    public: bool = false,
    private: bool = false,
    protected: bool = false,
    internal: bool = false,
    abstract: bool = false,
    shared: bool = false, // type-associated (not instance)
    readonly: bool = false,
    extern_: bool = false,
};

// ── Type declarations ─────────────────────────────────────────────────────────

pub const DeclClass = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    /// `implements IFoo, IBar`
    implements: []const TypeRef,
    /// `adds Mixin`
    adds: []const TypeRef,
    /// `invariant` block (contract).
    invariants: []const *Expr,
    members: []const Decl,
};

pub const DeclInterface = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    /// `implements` other interfaces.
    implements: []const TypeRef,
    members: []const Decl,
};

pub const DeclStruct = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    implements: []const TypeRef,
    invariants: []const *Expr,
    members: []const Decl,
};

pub const DeclMixin = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    members: []const Decl,
};

pub const DeclEnum = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    /// Optional base type (e.g. `int`).
    base: ?TypeRef,
    members: []const EnumMember,
};

pub const EnumMember = struct {
    span: Span,
    name: []const u8,
    /// Optional explicit value.
    value: ?*Expr,
};

/// `extend Foo` — adds methods to an existing type.
pub const DeclExtend = struct {
    span: Span,
    target: TypeRef,
    members: []const Decl,
};

/// `union Shape` — a discriminated union type (tagged union).
pub const DeclUnion = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    variants: []const UnionVariant,
};

/// A single variant of a discriminated union.
pub const UnionVariant = struct {
    span: Span,
    name: []const u8,
    /// Payload type — nil for unit variants (no payload).
    payload: ?TypeRef,
};

// ── Member declarations ───────────────────────────────────────────────────────

pub const DeclMethod = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    type_params: []const []const u8,
    params: []const Param,
    return_type: ?TypeRef,
    /// Contract block.
    require: []const *Expr,
    ensure: []const *Expr,
    body: ?[]const Stmt,
    /// `is test` — marks this as a unit test method.
    is_test: bool,
    /// `throws` annotation — method may propagate errors.
    throws: bool,
};

pub const DeclProperty = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    type_: ?TypeRef,
    /// `get` accessor body — nil means abstract / auto.
    getter: ?[]const Stmt,
    /// `set` accessor body — nil means read-only or abstract.
    setter: ?[]const Stmt,
};

pub const DeclVar = struct {
    span: Span,
    mods: Modifiers,
    name: []const u8,
    /// `as T` — nil means inferred.
    type_: ?TypeRef,
    /// Initialiser expression.
    init: ?*Expr,
    /// `const` instead of `var`.
    is_const: bool,
};

/// `cue init(...)` — constructor.
pub const DeclInit = struct {
    span: Span,
    mods: Modifiers,
    params: []const Param,
    require: []const *Expr,
    ensure: []const *Expr,
    body: ?[]const Stmt,
};

// ── Parameters ────────────────────────────────────────────────────────────────

pub const ParamMode = enum {
    normal,
    vari, // variadic
};

pub const Param = struct {
    span: Span,
    mode: ParamMode,
    name: []const u8,
    type_: ?TypeRef,
    default: ?*Expr,
};

// ── Type references ───────────────────────────────────────────────────────────

/// A type expression as it appears in source (e.g. `String?`, `List<of int>`).
/// This is not a resolved type — resolution happens during binding.
pub const TypeRef = union(enum) {
    /// Primitive or named: `int`, `String`, `Foo`
    named: NamedTypeRef,
    /// `T?` — nilable wrapper.
    nilable: *TypeRef,
    /// `T*` — stream / generator.
    stream: *TypeRef,
    /// `!T` — error union (this operation can fail).
    error_union: *TypeRef,
    /// `List<of T>`, `Dictionary<of K, V>`, etc.
    generic: GenericTypeRef,
    /// `void` (explicit return type)
    void_: void,
    /// `same` (return type = declaring type)
    same: void,
    /// `(T1, T2, …)` — tuple type with two or more element types.
    tuple: TupleTypeRef,
};

pub const NamedTypeRef = struct {
    span: Span,
    name: []const u8,
};

pub const GenericTypeRef = struct {
    span: Span,
    name: []const u8,
    args: []const TypeRef,
};

pub const TupleTypeRef = struct {
    span:  Span,
    elems: []const TypeRef,
};


// ── Statements ────────────────────────────────────────────────────────────────

pub const Stmt = union(enum) {
    if_: *StmtIf,
    while_: *StmtWhile,
    for_in: *StmtForIn,
    for_num: *StmtForNum,
    branch: *StmtBranch,
    return_: *StmtReturn,
    assert: *StmtAssert,
    print: *StmtPrint,
    pass: Span,
    break_: Span,
    continue_: Span,
    yield: *StmtYield,
    assign: *StmtAssign,
    var_: *DeclVar,     // local variable declaration
    expr: *Expr,        // expression statement
    contract: *StmtContract,
    defer_: *StmtDefer,
    with: *StmtWith,    // with obj eol Block — contextual self
    var_except: *StmtVarExcept,   // var id = base except ...
    assign_except: *StmtAssignExcept, // target = base except ...
    raise: *StmtRaise,            // raise [msg [, details]]
    try_catch: *StmtTryCatch,     // try eol Block CatchClauseList
    guard: *StmtGuard,            // guard cond else { block | stmt }
    destruct: *StmtDestruct,      // var (x, y) = expr
};

pub const StmtIf = struct {
    span: Span,
    cond: *Expr,
    then_body: []const Stmt,
    /// Each subsequent `else if`.
    else_ifs: []const ElseIf,
    /// Final `else`.
    else_body: ?[]const Stmt,
};

pub const ElseIf = struct {
    span: Span,
    cond: *Expr,
    body: []const Stmt,
};

pub const StmtWhile = struct {
    span: Span,
    cond: *Expr,
    /// `post` body (runs after each iteration if no break).
    post_body: ?[]const Stmt,
    body: []const Stmt,
};

pub const StmtForIn = struct {
    span: Span,
    /// Loop variable(s).
    vars: []const []const u8,
    iter: *Expr,
    where: ?*Expr,
    body: []const Stmt,
};

pub const StmtForNum = struct {
    span: Span,
    var_: []const u8,
    /// `start : stop` or `start : stop : step`.
    start: *Expr,
    stop: *Expr,
    step: ?*Expr,
    body: []const Stmt,
};

pub const BranchOn = struct {
    span: Span,
    values: []const *Expr,
    body: []const Stmt,
    /// For union dispatch: `on Shape.circle as radius` — binding name for the payload.
    binding: ?[]const u8 = null,
};

pub const StmtBranch = struct {
    span: Span,
    expr: *Expr,
    on: []const BranchOn,
    else_: ?[]const Stmt,
};

pub const StmtReturn = struct {
    span: Span,
    value: ?*Expr,
};

pub const StmtAssert = struct {
    span: Span,
    cond: *Expr,
    message: ?*Expr,
};

pub const StmtPrint = struct {
    span: Span,
    args: []const *Expr,
};

pub const StmtYield = struct {
    span: Span,
    value: *Expr,
};

pub const StmtDefer = struct {
    span: Span,
    /// `true` → `errdefer` (runs only on error exit), `false` → `defer` (always).
    is_err: bool,
    body: Stmt,
};

/// `with target eol Block` — contextual self block.
/// Inside the body, bare name assignments desugar to `target.name = value`.
pub const StmtWith = struct {
    span: Span,
    target: *Expr,
    body: []const Stmt,
};

/// `guard cond else { block | stmt }` — early-exit: if cond is false, run else body.
pub const StmtGuard = struct {
    span: Span,
    cond: *Expr,
    /// The else body — one or more statements (block form or single inline stmt).
    else_body: []const Stmt,
};

/// `var (x, y, z) = expr` or `var {a, b} = expr` — destructuring declaration.
/// For tuple form, each name binds to the positional element (`._dt.@"0"` etc.).
/// For struct form, each name binds to the same-named field (`._dt.name` etc.).
pub const StmtDestruct = struct {
    span:  Span,
    /// Binding names in declaration order.
    names: []const []const u8,
    init:  *Expr,
    /// Whether this is a tuple destructure `(x, y)` or struct destructure `{x, y}`.
    kind: enum { tuple, struct_ } = .tuple,
};

/// `raise [msg] [, details] eol` — raise an error.
pub const StmtRaise = struct {
    span: Span,
    /// Error message / value.  Nil → re-raise current error.
    message: ?*Expr,
    /// Optional detail payload (e.g. `ErrorInfo(T)` struct).
    details: ?*Expr,
};

/// `try eol Block CatchClauseList` — try/catch block.
pub const StmtTryCatch = struct {
    span: Span,
    body: []const Stmt,
    clauses: []const CatchClause,
};

/// A single `catch` clause.
pub const CatchClause = struct {
    span: Span,
    /// Binding name for the error value (the `e` in `catch |e|`).  Nil for catch-all.
    binding: ?[]const u8,
    /// Type filter for the binding (the `T` in `catch |e as T|`).  Nil for untyped.
    type_: ?TypeRef,
    body: []const Stmt,
};

/// A field override entry in an `except` struct-update.
pub const ExceptField = struct {
    span: Span,
    name: []const u8,
    value: *Expr,
};

/// `var id [as T] = base except eol indent fields dedent`
/// Desugars to: block that copies `base`, assigns each field, yields result.
pub const StmtVarExcept = struct {
    span: Span,
    name: []const u8,
    type_ref: ?TypeRef,
    base: *Expr,
    fields: []const ExceptField,
};

/// `target = base except eol indent fields dedent`
pub const StmtAssignExcept = struct {
    span: Span,
    target: *Expr,
    op: AssignOp,
    base: *Expr,
    fields: []const ExceptField,
};

pub const StmtAssign = struct {
    span: Span,
    target: *Expr,
    /// `=` `+=` `-=` etc.  `.assign` means plain `=`.
    op: AssignOp,
    value: *Expr,
};

pub const AssignOp = enum {
    assign,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    slashslash_eq,
    percent_eq,
    starstar_eq,
    ampersand_eq,
    vertical_bar_eq,
    caret_eq,
    double_lt_eq,
    double_gt_eq,
    question_eq,
};

/// A `require` / `ensure` / `invariant` block attached to a method or class.
pub const ContractKind = enum { require, ensure, invariant };

pub const StmtContract = struct {
    span: Span,
    kind: ContractKind,
    exprs: []const *Expr,
};

// ── Expressions ───────────────────────────────────────────────────────────────

pub const Expr = union(enum) {
    int_lit: ExprIntLit,
    float_lit: ExprFloatLit,
    bool_lit: ExprBoolLit,
    char_lit: ExprCharLit,
    string_lit: ExprStringLit,
    string_interp: ExprStringInterp,
    nil: Span,
    this: Span,
    ident: ExprIdent,
    member: *ExprMember,
    call: *ExprCall,
    index: *ExprIndex,
    slice: *ExprSlice,
    binary: *ExprBinary,
    unary: *ExprUnary,
    cast: *ExprCast,
    to_nilable: *ExprToNilable,
    to_non_nil: *ExprToNonNil,
    is_nil: *ExprIsNil,
    orelse_: *ExprOrelse,
    catch_: *ExprCatch,
    if_expr: *ExprIf,
    lambda: *ExprLambda,
    list_lit: *ExprListLit,
    dict_lit: *ExprDictLit,
    array_lit: *ExprArrayLit,
    all_any: *ExprAllAny,
    old: *ExprOld,     // old expr — pre-call value in `ensure` contracts
    zig_lit: ExprZigLit, // zig'...' / zig"..." backend literal
    try_: *ExprTry,    // try expr — propagate error upward
    tuple_lit: *ExprTuple,  // (a, b, c) — tuple literal
};

// ── Literal expressions ───────────────────────────────────────────────────────

pub const IntBase = enum { decimal, hex };

pub const ExprIntLit = struct {
    span: Span,
    text: []const u8, // raw source text; interpreter/codegen parses the value
    base: IntBase,
};

pub const ExprFloatLit = struct {
    span: Span,
    text: []const u8,
};

pub const ExprBoolLit = struct {
    span: Span,
    value: bool,
};

pub const ExprCharLit = struct {
    span: Span,
    text: []const u8, // raw source including quotes
};

pub const StringKind = enum {
    plain, // "hello"
    raw, // r"hello"
    nosub, // ns"hello"
    zig, // zig"hello" — backend (Zig) literal
};

pub const ExprStringLit = struct {
    span: Span,
    kind: StringKind,
    text: []const u8, // raw source including quotes
};

/// A string with `${expr}` interpolations.
///
/// `parts` alternates between literal segments and interpolated expressions.
/// The first and last elements are always `StringPart.literal` (possibly
/// with empty text for strings that start or end with an interpolation).
pub const ExprStringInterp = struct {
    span: Span,
    parts: []const StringPart,
};

pub const StringPart = union(enum) {
    /// A literal segment of text (between interpolations).
    literal: []const u8,
    /// An interpolated expression.
    expr: *Expr,
    /// A format specification following an expression: `:[fmt]`.
    format: []const u8,
};

// ── Identifier and access expressions ────────────────────────────────────────

pub const ExprIdent = struct {
    span: Span,
    name: []const u8,
};

pub const ExprMember = struct {
    span: Span,
    object: *Expr,
    member: []const u8,
};

// ── Call expression ───────────────────────────────────────────────────────────

pub const Arg = struct {
    span: Span,
    /// Named argument label, nil for positional.
    name: ?[]const u8,
    value: *Expr,
};

pub const ExprCall = struct {
    span: Span,
    callee: *Expr,
    type_args: []const TypeRef, // `<of T>` explicit type arguments
    args: []const Arg,
};

// ── Index and slice ───────────────────────────────────────────────────────────

pub const ExprIndex = struct {
    span: Span,
    object: *Expr,
    index: *Expr,
};

pub const ExprSlice = struct {
    span: Span,
    object: *Expr,
    start: ?*Expr,
    stop: ?*Expr,
};

// ── Binary and unary operators ────────────────────────────────────────────────

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    int_div,
    mod,
    pow,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    dotdot, // range / spread
};

pub const ExprBinary = struct {
    span: Span,
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
};

pub const UnaryOp = enum {
    neg,     // -x
    not_,    // not x
    bit_not, // ~x
    old,     // old x  (contract pre-call value)
};

pub const ExprUnary = struct {
    span: Span,
    op: UnaryOp,
    operand: *Expr,
};

// ── Cast and nil operators ────────────────────────────────────────────────────

/// `expr to T`
pub const ExprCast = struct {
    span: Span,
    expr: *Expr,
    target: TypeRef,
};

/// `expr to?` — return nilable, nil if cast fails.
pub const ExprToNilable = struct {
    span: Span,
    expr: *Expr,
};

/// `expr to !` — assert non-nil / non-zero.
pub const ExprToNonNil = struct {
    span: Span,
    expr: *Expr,
};

/// `expr?` — true if expr is nil.
pub const ExprIsNil = struct {
    span: Span,
    expr: *Expr,
};

/// `expr orelse fallback` — evaluates to `fallback` when `expr` is nil or an error.
pub const ExprOrelse = struct {
    span: Span,
    expr: *Expr,
    fallback: *Expr,
};

/// `expr catch fallback` or `expr catch |e| fallback` — recover from an error union.
pub const ExprCatch = struct {
    span: Span,
    expr: *Expr,
    /// Binding name for the error value, e.g. `e` in `catch |e| ...`.  Nil for unbound form.
    err_var: ?[]const u8,
    fallback: *Expr,
};

// ── Control-flow expressions ──────────────────────────────────────────────────

/// `if(cond, then_expr, else_expr)` — ternary expression form.
pub const ExprIf = struct {
    span: Span,
    cond: *Expr,
    then_expr: *Expr,
    else_expr: *Expr,
};

/// Anonymous method / lambda.
pub const ExprLambda = struct {
    span: Span,
    params: []const Param,
    return_type: ?TypeRef,
    body: LambdaBody,
    /// Capture declarations (only non-empty for statement-body lambdas with a `capture` block).
    capture: []const *DeclVar,
};

pub const LambdaBody = union(enum) {
    /// Single expression: `def(x) = x + 1`
    expr: *Expr,
    /// Statement block: `def(x)\n    return x + 1`
    stmts: []const Stmt,
};

// ── Collection literals ───────────────────────────────────────────────────────

/// `List<of T>(a, b, c)` or a list comprehension.
pub const ExprListLit = struct {
    span: Span,
    elem_type: ?TypeRef,
    elems: []const *Expr,
};

pub const DictEntry = struct {
    key: *Expr,
    value: *Expr,
};

/// `{k: v, ...}` dictionary literal.
pub const ExprDictLit = struct {
    span: Span,
    entries: []const DictEntry,
};

/// `@[a, b, c]` array literal.
pub const ExprArrayLit = struct {
    span: Span,
    elems: []const *Expr,
};

// ── Comprehensions ────────────────────────────────────────────────────────────

pub const AllAnyKind = enum { all, any };

/// `all x in list where x > 0` or `any x in list where x > 0`
pub const ExprAllAny = struct {
    span: Span,
    kind: AllAnyKind,
    var_: []const u8,
    iter: *Expr,
    cond: *Expr,
};

// ── Contract expression ───────────────────────────────────────────────────────

/// `old expr` — refers to the pre-call value of an expression (in `ensure`).
pub const ExprOld = struct {
    span: Span,
    expr: *Expr,
};

/// `zig'...'` or `zig"..."` — inline backend (Zig) literal string.
pub const ExprZigLit = struct {
    span: Span,
    text: []const u8, // raw source including the zig prefix and quotes
};

/// `try expr` — propagate an error-union result upward (expression form).
/// If `expr` is an error, returns the error from the enclosing function.
pub const ExprTry = struct {
    span: Span,
    expr: *Expr,
};

/// `(a, b, c)` — tuple literal with two or more elements.
pub const ExprTuple = struct {
    span:  Span,
    elems: []const *Expr,
};

// ── Arena helpers ─────────────────────────────────────────────────────────────

/// Allocate a single node into the arena and return a pointer to it.
/// Use this in AstBuilder to create child nodes.
pub fn alloc(arena: std.mem.Allocator, comptime T: type, value: T) !*T {
    const p = try arena.create(T);
    p.* = value;
    return p;
}

/// Dupe a slice into the arena.
pub fn dupeSlice(arena: std.mem.Allocator, comptime T: type, items: []const T) ![]T {
    return arena.dupe(T, items);
}
