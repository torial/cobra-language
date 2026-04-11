//! Zebra grammar for the Earley parser.
//!
//! This file defines the complete nonterminal set and grammar rules for the
//! Zebra language subset targeted by Milestone 1.  The grammar is compiled
//! at compile time via `earley.defineGrammar` and produces a zero-runtime-cost
//! `Grammar(TokenKind)` constant.
//!
//! ## Scope
//!
//! Covers: `use`, `namespace`, `class`, `interface`, `struct`, `mixin`, `enum`,
//! `extend`, `sig`, `def`, `pro`, `get`/`set`, `var`/`const`, `cue init`,
//! all statement forms, full expression grammar with precedence, string
//! interpolation, `all`/`any` comprehensions, and contract sub-blocks.
//!
//! Not yet covered: generic class/method declarations (`<of T>`).
//!
//! ## Usage
//!
//! ```zig
//! const G = @import("ZebraGrammar.zig");
//! const nullable = try earley.computeNullable(TokenKind, G.grammar, alloc);
//! var parser = earley.Parser(TokenKind).init(&G.grammar, &nullable, alloc);
//! var result = try parser.parse(token_kinds);
//! ```

const earley = @import("earley");

/// Re-exported so consumers of this module can reference the token type
/// without a separate import.
pub const TokenKind = @import("Token.zig").TokenKind;

// ── Nonterminal enum ──────────────────────────────────────────────────────────

/// Every nonterminal in the Zebra grammar.
/// Ordering within groups is for readability only; the ordinal values are
/// what the Earley library uses internally.
pub const NT = enum {
    // ── Program ────────────────────────────────────────────────────────────
    Program,
    TopDeclList,  // zero or more top-level declarations
    TopDecl,

    // ── Use directive ──────────────────────────────────────────────────────
    UseDecl,
    UsePath,      // dotted name: id | UsePath . id

    // ── Namespace ──────────────────────────────────────────────────────────
    NamespaceDecl,

    // ── Modifier list ──────────────────────────────────────────────────────
    ModList,      // zero or more modifiers

    // ── Attribute clauses (is / has) ───────────────────────────────────────
    IsClauseOpt,  // optional `is IsAttrList`
    IsAttrList,   // one or more is-attributes (left-recursive)
    IsAttrItem,   // single is-attribute keyword or id
    HasOpt,       // optional `has HasAttrListNE`
    HasAttrListNE,
    HasAttrItem,  // id | at_id | open_call(args)

    // ── Type declarations ──────────────────────────────────────────────────
    ClassDecl,
    ClassHeader,         // optional implements/adds
    ImplementsClauseOpt,
    AddsClauseOpt,
    TypeRefListNE,       // comma-separated type references (≥1)
    TypeParam,           // single type parameter: `T` or `T where T implements Interface`
    TypeParamListNE,     // comma-separated TypeParams (≥1) in class(T, U) decls
    GenericConstruct,    // ClassName(TypeArgs)(ValueArgs) — generic class instantiation

    InterfaceDecl,
    InterfaceHeader,     // optional inherits list

    StructDecl,
    StructHeader,

    MixinDecl,

    EnumDecl,
    EnumMemberList,
    EnumMember,

    // ── Extend declarations ────────────────────────────────────────────────
    ExtendDecl,

    // ── At-directives (@foo, @foo(args)) ──────────────────────────────────
    AtDirective,

    // ── Member declarations ────────────────────────────────────────────────
    MemberDeclList,      // zero or more members
    MemberDecl,

    MethodDecl,
    ReturnAnnotOpt,      // optional `as TypeRef`

    PropDecl,
    ProDecl,             // pro id [as T] [from var|id] [PropBodyOpt]
    PropBodyOpt,         // ε | indent PropBodyListNE dedent
    PropBodyListNE,      // one or more get/set sub-blocks
    PropBodyItem,        // kw_get eol Block | kw_set eol Block

    VarMemberDecl,
    VarTypeOpt,          // optional `as TypeRef`
    VarInitOpt,          // optional `= Expr`

    InitDecl,            // cue init(...)

    // ── Grouped member blocks ──────────────────────────────────────────────
    SharedGroupDecl,     // shared eol indent MemberDeclList dedent
    TestMemberDecl,      // test eol indent StmtList dedent
    InvariantDecl,       // invariant eol indent StmtList dedent

    // ── Contract sub-blocks (require/ensure/body/test inside methods) ──────
    ContractBlock,         // indent ContractClauseListNE dedent
    ContractClauseListNE,  // one or more contract clauses
    ContractClause,

    // ── Parameters ────────────────────────────────────────────────────────
    ParamList,           // possibly empty
    ParamListNE,         // non-empty, comma-separated
    Param,
    ParamModeOpt,        // optional vari prefix

    // ── Type references ────────────────────────────────────────────────────
    TypeRef,

    // ── Block and statements ───────────────────────────────────────────────
    Block,               // indent StmtList dedent
    StmtList,            // one or more statements

    Stmt,

    StmtReturn,
    StmtPrint,
    StmtPass,
    StmtBreak,
    StmtContinue,
    StmtAssert,
    StmtYield,

    StmtIf,
    IfTail,              // zero or more else-if clauses, optional else
    ElseIfClause,
    ElseClauseOpt,

    StmtWhile,
    StmtPostWhile,       // post while Expr eol Block  (do-while form)

    StmtForIn,
    StmtForNum,
    ForVarList,          // id | ForVarList , id

    StmtBranch,
    BranchOnList,        // one or more on-clauses
    BranchOnClause,
    BranchElseOpt,

    StmtAssign,          // Expr AssignOp Expr eol
    AssignOp,

    StmtLocalVar,        // var/const inside a method body
    StmtLocalVarLambda,  // var/const = def(...) eol Block  (statement-body lambda)
    StmtDestruct,        // var ( IdListNE ) = Expr eol  — tuple destructuring
    StmtDestructStruct,  // var { IdListNE } = Expr eol  — struct field destructuring
    IdListNE,            // non-empty comma-separated id list (for destructuring)
    StmtExpr,            // expression used as a statement

    StmtExpect,          // expect TypeRef , Expr eol
    StmtLock,            // lock Expr eol Block
    StmtDefer,           // defer Stmt | errdefer Stmt

    // ── Lambda expressions ─────────────────────────────────────────────────
    LambdaExpr,       // def(params) [as T] = Expr  |  def(params) [as T] eol Block
    LambdaBlockExpr,  // def(params) [as T] eol indent CaptureOpt StmtList dedent (block-body as Atom)
    LambdaBody,       // = Expr eol  |  eol Block
    LambdaExprBody,   // = Expr eol (expression-body form)
    LambdaStmtBody,   // eol indent CaptureOpt StmtList dedent (statement-body form)
    CaptureOpt,       // ε | CaptureBlock
    CaptureBlock,     // kw_capture eol indent CaptureVarList dedent
    CaptureVarList,   // one or more var/const declarations
    CaptureVar,       // var/const id [as TypeRef] [= Expr] eol

    // ── with contextual-self block ─────────────────────────────────────────
    StmtWith,         // with Expr eol Block

    // ── scoped arena allocation block ─────────────────────────────────────
    StmtArenaScope,   // arena eol Block

    // ── except struct-update expression ───────────────────────────────────
    ExceptFieldList,  // one or more field assignments
    ExceptField,      // id = Expr eol

    // ── Expressions ────────────────────────────────────────────────────────
    // Each level handles one precedence band; lower number = lower precedence.
    Expr,     // pipeline (->)  or  or  orelse  catch
    Expr2,    // and
    Expr3,    // not  (right-recursive)
    Expr4,    // ==  <>  <  >  <=  >=  is  in  not in
    Expr5,    // +  -
    Expr6,    // *  /  //  %
    Expr7,    // **
    Expr8,    // unary -  ~
    Expr9,    // postfix: .member  .call()  [index]  to T  to?  to!
    Atom,     // literals, identifiers, grouped expr, string, array

    // ── pipeline operator (->)  ────────────────────────────────────────────
    PipelineCall,     // open_call ArgList rparen  (the RHS of a pipeline step)

    // ── all / any comprehension ────────────────────────────────────────────
    AllAnyExpr,  // all/any for ForVarList in Expr get Expr

    // ── Argument list ──────────────────────────────────────────────────────
    ArgList,    // possibly empty
    ArgListNE,  // non-empty, comma-separated

    // ── Expression list (for print, branch on, etc.) ───────────────────────
    ExprList,    // possibly empty
    ExprListNE,  // non-empty

    // ── Aspect declarations ────────────────────────────────────────────────────
    AspectDecl,
    AspectBodyListNE,  // one or more advice clauses
    AspectBodyItem,    // on before | on after[(result)] | on around | on error[(e)]

    // ── Weaves clause and project-level weave ─────────────────────────────────
    WeavesOpt,    // optional `weaves TypeRefListNE` on class/method
    WeaveDecl,    // top-level: weaves Aspect to all def|class Pattern

    // ── String interpolation ───────────────────────────────────────────────
    InterpBodyS,   // body of single-quoted interpolated string
    InterpBodyD,   // body of double-quoted interpolated string
    InterpRestS,   // optional tail of single-quoted interp string
    InterpRestD,   // optional tail of double-quoted interp string
    InterpExprS,   // expr (with optional format spec) inside single-quoted
    InterpExprD,   // expr (with optional format spec) inside double-quoted

    // ── Discriminated union types ──────────────────────────────────────────
    DeclUnion,          // union Name eol indent UnionVariantList dedent
    SigDecl,            // sig Name(ParamList) as TypeRef eol  — named function-type alias
    UnionVariantList,   // one or more variants
    UnionVariant,       // id eol  |  id as TypeRef eol

    // ── Guard statements ──────────────────────────────────────────────────
    StmtGuard,          // guard Expr else eol Block  (block form)
    StmtGuardInline,    // guard Expr else, Stmt       (inline form)

    // ── Error propagation / try-catch ─────────────────────────────────────
    ThrowsOpt,          // ε | kw_throws  (method annotation)
    StmtRaise,          // raise [Expr [, Expr]] eol
    StmtTryCatch,       // try eol Block CatchClauseList
    CatchClauseList,    // one or more catch clauses
    CatchClause,        // catch [|id [as T]|] eol Block
};

// ── Grammar constant ──────────────────────────────────────────────────────────

/// The compiled Zebra grammar.  Zero runtime cost; pass `&grammar` to the
/// Earley parser.  Do not call `.deinit()`.
pub const grammar = earley.defineGrammar(TokenKind, NT, .Program, rules);

// ── Symbol shorthands ─────────────────────────────────────────────────────────

const Sym  = earley.GrammarSym(TokenKind, NT);
const Rule = earley.GrammarRule(TokenKind, NT);

/// Terminal symbol.
fn t(tok: TokenKind) Sym { return .{ .t = tok }; }
/// Nonterminal symbol.
fn n(nn: NT) Sym { return .{ .nt = nn }; }

// ── Rule table ────────────────────────────────────────────────────────────────
//
// Sections follow the NT enum order.  Each section is a comptime slice
// concatenated into the final `rules` constant at the bottom of the file.

// ── Program ───────────────────────────────────────────────────────────────────

const program_rules: []const Rule = &.{
    .{ .lhs = .Program,     .rhs = &.{ n(.TopDeclList), t(.eof) } },
    .{ .lhs = .TopDeclList, .rhs = &.{} }, // ε
    .{ .lhs = .TopDeclList, .rhs = &.{ n(.TopDeclList), n(.TopDecl) } },
    .{ .lhs = .TopDeclList, .rhs = &.{ n(.TopDeclList), t(.eol) } }, // blank lines
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.UseDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.NamespaceDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.ClassDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.InterfaceDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.StructDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.MixinDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.EnumDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.ExtendDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.AtDirective) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.AspectDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.WeaveDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.DeclUnion) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.SigDecl) } },
    .{ .lhs = .TopDecl,     .rhs = &.{ n(.MethodDecl) } }, // top-level free function
};

// ── Use directive ─────────────────────────────────────────────────────────────

const use_rules: []const Rule = &.{
    .{ .lhs = .UseDecl, .rhs = &.{ t(.kw_use), n(.UsePath), t(.eol) } },
    // use Mod exposing Name1, Name2, ...
    .{ .lhs = .UseDecl, .rhs = &.{ t(.kw_use), n(.UsePath), t(.kw_exposing), n(.IdListNE), t(.eol) } },
    .{ .lhs = .UsePath, .rhs = &.{ t(.id) } },
    .{ .lhs = .UsePath, .rhs = &.{ n(.UsePath), t(.dot), t(.id) } },
};

// ── Namespace ─────────────────────────────────────────────────────────────────

const namespace_rules: []const Rule = &.{
    // namespace Foo[.Bar]  eol  indent  TopDeclList  dedent
    .{ .lhs = .NamespaceDecl, .rhs = &.{
        t(.kw_namespace), n(.UsePath), t(.eol),
        t(.indent), n(.TopDeclList), t(.dedent),
    } },
};

// ── Modifiers ─────────────────────────────────────────────────────────────────

const mod_rules: []const Rule = &.{
    .{ .lhs = .ModList, .rhs = &.{} }, // ε
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_public) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_private) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_protected) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_internal) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_abstract) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_shared) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_readonly) } },
    .{ .lhs = .ModList, .rhs = &.{ n(.ModList), t(.kw_extern) } },
};

// ── is-clause and has-clause ──────────────────────────────────────────────────
//
// `is shared`, `is abstract`, `is override`, …  appear after method/property
// signatures and on class/interface headers.
// `has deprecated`, `has [Serializable, Conditional]` appear on members.

const is_clause_rules: []const Rule = &.{
    .{ .lhs = .IsClauseOpt, .rhs = &.{} }, // ε
    .{ .lhs = .IsClauseOpt, .rhs = &.{ t(.kw_is), n(.IsAttrList) } },

    .{ .lhs = .IsAttrList, .rhs = &.{ n(.IsAttrItem) } },
    .{ .lhs = .IsAttrList, .rhs = &.{ n(.IsAttrList), n(.IsAttrItem) } },

    // Any modifier keyword or bare id is a valid is-attribute.
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_shared) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_abstract) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_extern) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_readonly) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_public) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_private) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_protected) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.kw_internal) } },
    .{ .lhs = .IsAttrItem, .rhs = &.{ t(.id) } },
};

const has_rules: []const Rule = &.{
    .{ .lhs = .HasOpt, .rhs = &.{} }, // ε
    .{ .lhs = .HasOpt, .rhs = &.{ t(.kw_has), n(.HasAttrListNE) } },

    .{ .lhs = .HasAttrListNE, .rhs = &.{ n(.HasAttrItem) } },
    .{ .lhs = .HasAttrListNE, .rhs = &.{ n(.HasAttrListNE), t(.comma), n(.HasAttrItem) } },

    .{ .lhs = .HasAttrItem, .rhs = &.{ t(.id) } },
    .{ .lhs = .HasAttrItem, .rhs = &.{ t(.at_id) } },
    // attribute call: @Deprecated("since 2.0")
    .{ .lhs = .HasAttrItem, .rhs = &.{ t(.at_id), t(.lparen), n(.ArgList), t(.rparen) } },
    // plain name call: Conditional("DEBUG")
    .{ .lhs = .HasAttrItem, .rhs = &.{ t(.open_call), n(.ArgList), t(.rparen) } },
};

// ── Type references ───────────────────────────────────────────────────────────

const type_rules: []const Rule = &.{
    // Error union: !T  (bang prefix)
    .{ .lhs = .TypeRef, .rhs = &.{ t(.bang), n(.TypeRef) } },
    // Heap-indirection pointer: ^T  (breaks recursive struct size cycles)
    .{ .lhs = .TypeRef, .rhs = &.{ t(.caret), n(.TypeRef) } },
    // Named types (identifiers and keywords that name types)
    .{ .lhs = .TypeRef, .rhs = &.{ t(.id) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_int) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_uint) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_float) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_bool) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_char) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_same) } },
    // Sized types: int32, uint64, float32 etc. (tokenizer emits int_size/uint_size/float_size)
    .{ .lhs = .TypeRef, .rhs = &.{ t(.int_size) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.uint_size) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.float_size) } },
    // Arbitrary-width forms: int(N), uint(N), float(N) — N is an integer literal
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_int),   t(.lparen), t(.integer_lit), t(.rparen) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_uint),  t(.lparen), t(.integer_lit), t(.rparen) } },
    .{ .lhs = .TypeRef, .rhs = &.{ t(.kw_float), t(.lparen), t(.integer_lit), t(.rparen) } },
    // Qualified: Namespace.Type
    .{ .lhs = .TypeRef, .rhs = &.{ n(.TypeRef), t(.dot), t(.id) } },
    // T?  — nilable
    .{ .lhs = .TypeRef, .rhs = &.{ n(.TypeRef), t(.question) } },
    // T*  — stream / generator
    .{ .lhs = .TypeRef, .rhs = &.{ n(.TypeRef), t(.star) } },

    // Generic type: Name(T) or Name(K, V) — tokenizer emits open_call for id+(
    .{ .lhs = .TypeRef, .rhs = &.{ t(.open_call), n(.TypeRefListNE), t(.rparen) } },

    // Tuple type: (T1, T2) or (T1, T2, T3, …)
    // lparen TypeRef comma TypeRefListNE rparen
    .{ .lhs = .TypeRef, .rhs = &.{ t(.lparen), n(.TypeRef), t(.comma), n(.TypeRefListNE), t(.rparen) } },

    // Comma-separated list of type references (for implements/adds)
    .{ .lhs = .TypeRefListNE, .rhs = &.{ n(.TypeRef) } },
    .{ .lhs = .TypeRefListNE, .rhs = &.{ n(.TypeRefListNE), t(.comma), n(.TypeRef) } },

    // Single type parameter: plain `T` or constrained `T where T implements Interface`
    .{ .lhs = .TypeParam, .rhs = &.{ t(.id) } },
    .{ .lhs = .TypeParam, .rhs = &.{ t(.id), t(.kw_where), t(.id), t(.kw_implements), t(.id) } },
    // Comma-separated list of type parameters in class(T, U) or class(T where T implements I)
    .{ .lhs = .TypeParamListNE, .rhs = &.{ n(.TypeParam) } },
    .{ .lhs = .TypeParamListNE, .rhs = &.{ n(.TypeParamListNE), t(.comma), n(.TypeParam) } },
};

// ── Class declaration ─────────────────────────────────────────────────────────

const class_rules: []const Rule = &.{
    // Non-generic class: class Dog implements IAnimal
    .{ .lhs = .ClassDecl, .rhs = &.{
        n(.ModList), t(.kw_class), t(.id),
        n(.ClassHeader), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },
    // Generic class: class Stack(T) or class Pair(A, B)
    // Tokenizer emits `open_call` for `ClassName(` (identifier fused with open paren).
    .{ .lhs = .ClassDecl, .rhs = &.{
        n(.ModList), t(.kw_class), t(.open_call), n(.TypeParamListNE), t(.rparen),
        n(.ClassHeader), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },

    // ClassHeader = optional implements + adds
    .{ .lhs = .ClassHeader, .rhs = &.{
        n(.ImplementsClauseOpt), n(.AddsClauseOpt),
    } },

    .{ .lhs = .ImplementsClauseOpt,  .rhs = &.{} }, // ε
    .{ .lhs = .ImplementsClauseOpt,  .rhs = &.{ t(.kw_implements), n(.TypeRefListNE) } },
    .{ .lhs = .AddsClauseOpt,        .rhs = &.{} }, // ε
    .{ .lhs = .AddsClauseOpt,        .rhs = &.{ t(.kw_adds),       n(.TypeRefListNE) } },
};

// ── Interface declaration ─────────────────────────────────────────────────────

const interface_rules: []const Rule = &.{
    .{ .lhs = .InterfaceDecl, .rhs = &.{
        n(.ModList), t(.kw_interface), t(.id),
        n(.InterfaceHeader), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },
    .{ .lhs = .InterfaceHeader, .rhs = &.{} }, // ε — no parents
    .{ .lhs = .InterfaceHeader, .rhs = &.{ t(.kw_implements), n(.TypeRefListNE) } },
};

// ── Struct declaration ────────────────────────────────────────────────────────

const struct_rules: []const Rule = &.{
    .{ .lhs = .StructDecl, .rhs = &.{
        n(.ModList), t(.kw_struct), t(.id),
        n(.StructHeader), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },
    .{ .lhs = .StructHeader, .rhs = &.{} }, // ε
    .{ .lhs = .StructHeader, .rhs = &.{ t(.kw_implements), n(.TypeRefListNE) } },
};

// ── Mixin declaration ─────────────────────────────────────────────────────────

const mixin_rules: []const Rule = &.{
    .{ .lhs = .MixinDecl, .rhs = &.{
        n(.ModList), t(.kw_mixin), t(.id), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },
};

// ── Enum declaration ──────────────────────────────────────────────────────────

const enum_rules: []const Rule = &.{
    .{ .lhs = .EnumDecl, .rhs = &.{
        n(.ModList), t(.kw_enum), t(.id), t(.eol),
        t(.indent), n(.EnumMemberList), t(.dedent),
    } },
    .{ .lhs = .EnumMemberList, .rhs = &.{ n(.EnumMember) } },
    .{ .lhs = .EnumMemberList, .rhs = &.{ n(.EnumMemberList), n(.EnumMember) } },
    .{ .lhs = .EnumMemberList, .rhs = &.{ n(.EnumMemberList), t(.eol) } }, // blank lines
    // Plain member: red
    .{ .lhs = .EnumMember,     .rhs = &.{ t(.id), t(.eol) } },
    // Valued member: red = 1
    .{ .lhs = .EnumMember,     .rhs = &.{ t(.id), t(.assign), n(.Expr), t(.eol) } },
    // Payload member: circle(radius as float)  — sum type / discriminated union
    // open_call absorbs `name(` as a single token, matching the method-call pattern.
    .{ .lhs = .EnumMember,     .rhs = &.{ t(.open_call), n(.ParamList), t(.rparen), t(.eol) } },
};

// ── Member declarations ───────────────────────────────────────────────────────

const member_rules: []const Rule = &.{
    .{ .lhs = .MemberDeclList, .rhs = &.{} }, // ε — empty body
    .{ .lhs = .MemberDeclList, .rhs = &.{ n(.MemberDeclList), n(.MemberDecl) } },
    .{ .lhs = .MemberDeclList, .rhs = &.{ n(.MemberDeclList), t(.eol) } }, // blank lines

    .{ .lhs = .MemberDecl, .rhs = &.{ n(.MethodDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.VarMemberDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.InitDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.PropDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.ProDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.SharedGroupDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.TestMemberDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.InvariantDecl) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.AtDirective) } },
    .{ .lhs = .MemberDecl, .rhs = &.{ n(.AspectDecl) } },
    // `is shared` (and other is-attributes) as a bare member declaration
    .{ .lhs = .MemberDecl, .rhs = &.{ t(.kw_is), n(.IsAttrList), t(.eol) } },
};

// ── Method declaration ────────────────────────────────────────────────────────
//
// Two forms:
//   def foo(params) as T   — open_call token covers the identifier + (
//   def foo as T           — no-arg form using bare id token

const method_rules: []const Rule = &.{
    // With parameters: open_call absorbs `(`; `)` is a separate rparen token.
    .{ .lhs = .MethodDecl, .rhs = &.{
        n(.ModList), t(.kw_def), t(.open_call),
        n(.ParamList), t(.rparen),
        n(.ReturnAnnotOpt), n(.ThrowsOpt), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
    } },
    .{ .lhs = .MethodDecl, .rhs = &.{
        n(.ModList), t(.kw_def), t(.open_call),
        n(.ParamList), t(.rparen),
        n(.ReturnAnnotOpt), n(.ThrowsOpt), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol), n(.Block),
    } },
    .{ .lhs = .MethodDecl, .rhs = &.{
        n(.ModList), t(.kw_def), t(.open_call),
        n(.ParamList), t(.rparen),
        n(.ReturnAnnotOpt), n(.ThrowsOpt), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol), n(.ContractBlock),
    } },
    // No-arg form: bare id, no parens.
    .{ .lhs = .MethodDecl, .rhs = &.{
        n(.ModList), t(.kw_def), t(.id),
        n(.ReturnAnnotOpt), n(.ThrowsOpt), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
    } },
    .{ .lhs = .MethodDecl, .rhs = &.{
        n(.ModList), t(.kw_def), t(.id),
        n(.ReturnAnnotOpt), n(.ThrowsOpt), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol), n(.Block),
    } },
    .{ .lhs = .MethodDecl, .rhs = &.{
        n(.ModList), t(.kw_def), t(.id),
        n(.ReturnAnnotOpt), n(.ThrowsOpt), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol), n(.ContractBlock),
    } },

    .{ .lhs = .ReturnAnnotOpt, .rhs = &.{} }, // ε
    .{ .lhs = .ReturnAnnotOpt, .rhs = &.{ t(.kw_as), n(.TypeRef) } },

    .{ .lhs = .ThrowsOpt, .rhs = &.{} }, // ε
    .{ .lhs = .ThrowsOpt, .rhs = &.{ t(.kw_throws) } },
};

// ── Property declarations (get / set) ─────────────────────────────────────────

const prop_rules: []const Rule = &.{
    // get foo as T  (read-only property)
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_get), t(.id), n(.ReturnAnnotOpt), n(.IsClauseOpt), n(.HasOpt), t(.eol),
    } },
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_get), t(.id), n(.ReturnAnnotOpt), n(.IsClauseOpt), n(.HasOpt), t(.eol), n(.Block),
    } },
    // get foo from var [as T]  — backed by implicit _foo var
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_get), t(.id), t(.kw_from), t(.kw_var), n(.ReturnAnnotOpt), t(.eol),
    } },
    // get foo from _bar [as T]  — backed by named var
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_get), t(.id), t(.kw_from), t(.id), n(.ReturnAnnotOpt), t(.eol),
    } },

    // set foo(value as T)  (write accessor with explicit param)
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_set), t(.open_call), n(.Param), t(.rparen),
        n(.IsClauseOpt), n(.HasOpt), t(.eol),
    } },
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_set), t(.open_call), n(.Param), t(.rparen),
        n(.IsClauseOpt), n(.HasOpt), t(.eol), n(.Block),
    } },
    // set foo  (implicit value param)
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_set), t(.id), n(.IsClauseOpt), n(.HasOpt), t(.eol),
    } },
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_set), t(.id), n(.IsClauseOpt), n(.HasOpt), t(.eol), n(.Block),
    } },
    // set foo from _bar  — backed by named var
    .{ .lhs = .PropDecl, .rhs = &.{
        n(.ModList), t(.kw_set), t(.id), t(.kw_from), t(.id), t(.eol),
    } },

    // pro foo [as T] [from var|id]  — full property (with optional get/set body)
    // Handled in pro_rules below.
};

// ── Pro property declarations ─────────────────────────────────────────────────
//
// `pro` declares a full read-write property, optionally backed by a var.
//
//   pro age as int            — abstract/auto property, no body
//   pro age from var          — backed by implicit _age var, auto accessors
//   pro age from var as int   — same, with explicit type
//   pro age from _storage     — backed by named var
//   pro age as int            — full body with explicit get/set blocks
//       get
//           return _age
//       set
//           _age = value

const pro_rules: []const Rule = &.{
    // No body (abstract or auto-property)
    .{ .lhs = .ProDecl, .rhs = &.{
        n(.ModList), t(.kw_pro), t(.id), n(.ReturnAnnotOpt), n(.IsClauseOpt), n(.HasOpt), t(.eol),
    } },
    // With get/set body
    .{ .lhs = .ProDecl, .rhs = &.{
        n(.ModList), t(.kw_pro), t(.id), n(.ReturnAnnotOpt), n(.IsClauseOpt), n(.HasOpt), t(.eol), n(.PropBodyOpt),
    } },
    // from var [as T]  — auto-backed
    .{ .lhs = .ProDecl, .rhs = &.{
        n(.ModList), t(.kw_pro), t(.id), t(.kw_from), t(.kw_var), n(.ReturnAnnotOpt), t(.eol),
    } },
    // from named var [as T]
    .{ .lhs = .ProDecl, .rhs = &.{
        n(.ModList), t(.kw_pro), t(.id), t(.kw_from), t(.id), n(.ReturnAnnotOpt), t(.eol),
    } },

    // PropBodyOpt — optional get/set sub-blocks
    .{ .lhs = .PropBodyOpt, .rhs = &.{} }, // ε
    .{ .lhs = .PropBodyOpt, .rhs = &.{ t(.indent), n(.PropBodyListNE), t(.dedent) } },

    .{ .lhs = .PropBodyListNE, .rhs = &.{ n(.PropBodyItem) } },
    .{ .lhs = .PropBodyListNE, .rhs = &.{ n(.PropBodyListNE), n(.PropBodyItem) } },

    // Each accessor is a keyword followed by its own block
    .{ .lhs = .PropBodyItem, .rhs = &.{ t(.kw_get), t(.eol), n(.Block) } },
    .{ .lhs = .PropBodyItem, .rhs = &.{ t(.kw_set), t(.eol), n(.Block) } },
};

// ── Var / const member declarations ──────────────────────────────────────────

const var_member_rules: []const Rule = &.{
    .{ .lhs = .VarMemberDecl, .rhs = &.{
        n(.ModList), t(.kw_var), t(.id), n(.VarTypeOpt), n(.VarInitOpt), t(.eol),
    } },
    .{ .lhs = .VarMemberDecl, .rhs = &.{
        n(.ModList), t(.kw_const), t(.id), n(.VarTypeOpt), t(.assign), n(.Expr), t(.eol),
    } },

    .{ .lhs = .VarTypeOpt, .rhs = &.{} }, // ε
    .{ .lhs = .VarTypeOpt, .rhs = &.{ t(.kw_as), n(.TypeRef) } },

    .{ .lhs = .VarInitOpt, .rhs = &.{} }, // ε
    .{ .lhs = .VarInitOpt, .rhs = &.{ t(.assign), n(.Expr) } },
};

// ── Constructor declaration ───────────────────────────────────────────────────

const init_rules: []const Rule = &.{
    .{ .lhs = .InitDecl, .rhs = &.{
        n(.ModList), t(.kw_cue), t(.open_call),
        n(.ParamList), t(.rparen), t(.eol),
    } },
    .{ .lhs = .InitDecl, .rhs = &.{
        n(.ModList), t(.kw_cue), t(.open_call),
        n(.ParamList), t(.rparen), t(.eol), n(.Block),
    } },
};

// ── Extend declarations ───────────────────────────────────────────────────────
//
// extend String
//     def doubleLength as int
//         ...

const extend_rules: []const Rule = &.{
    .{ .lhs = .ExtendDecl, .rhs = &.{
        n(.ModList), t(.kw_extend), n(.TypeRef), n(.IsClauseOpt), n(.HasOpt), n(.WeavesOpt), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },
};

// ── At-directives ─────────────────────────────────────────────────────────────
//
// @hidden
// @conditional("DEBUG")

const at_directive_rules: []const Rule = &.{
    .{ .lhs = .AtDirective, .rhs = &.{ t(.at_id), t(.eol) } },
    .{ .lhs = .AtDirective, .rhs = &.{ t(.at_id), t(.lparen), n(.ArgList), t(.rparen), t(.eol) } },
};

// ── Grouped member blocks ─────────────────────────────────────────────────────
//
// shared
//     def main
//         pass
//
// test
//     assert .x == 1
//
// invariant
//     x > 0

const group_member_rules: []const Rule = &.{
    .{ .lhs = .SharedGroupDecl, .rhs = &.{
        t(.kw_shared), t(.eol),
        t(.indent), n(.MemberDeclList), t(.dedent),
    } },
    .{ .lhs = .TestMemberDecl, .rhs = &.{
        t(.kw_test), t(.eol),
        t(.indent), n(.StmtList), t(.dedent),
    } },
    .{ .lhs = .InvariantDecl, .rhs = &.{
        t(.kw_invariant), t(.eol),
        t(.indent), n(.StmtList), t(.dedent),
    } },
};

// ── Contract sub-blocks ───────────────────────────────────────────────────────
//
// def square(x as int) as int
//     require
//         x > 0
//     body
//         return x * x
//     ensure
//         result > 0
//     test
//         assert .square(5) == 25

const contract_rules: []const Rule = &.{
    .{ .lhs = .ContractBlock,         .rhs = &.{ t(.indent), n(.ContractClauseListNE), t(.dedent) } },
    .{ .lhs = .ContractClauseListNE,  .rhs = &.{ n(.ContractClause) } },
    .{ .lhs = .ContractClauseListNE,  .rhs = &.{ n(.ContractClauseListNE), n(.ContractClause) } },
    .{ .lhs = .ContractClause,        .rhs = &.{ t(.kw_require),   t(.eol), n(.Block) } },
    .{ .lhs = .ContractClause,        .rhs = &.{ t(.kw_ensure),    t(.eol), n(.Block) } },
    .{ .lhs = .ContractClause,        .rhs = &.{ t(.kw_body),      t(.eol), n(.Block) } },
    .{ .lhs = .ContractClause,        .rhs = &.{ t(.kw_test),      t(.eol), n(.Block) } },
};

// ── Aspect declarations ───────────────────────────────────────────────────────
//
// aspect Logging
//     on before
//         print 'entering [method.name]'
//     on after(result)
//         print 'returning [result]'
//     on around
//         result = proceed()
//         return result
//     on error(e)
//         print 'error: [e]'
//
// The advice clause names (before, after, around, error) are plain identifiers
// in the grammar — the semantic layer validates which names are legal.
// `proceed()` inside `on around` desugars to a call through to the real method;
// it uses the existing open_call grammar path (no special token needed).

const aspect_rules: []const Rule = &.{
    .{ .lhs = .AspectDecl, .rhs = &.{
        t(.kw_aspect), t(.id), t(.eol),
        t(.indent), n(.AspectBodyListNE), t(.dedent),
    } },

    .{ .lhs = .AspectBodyListNE, .rhs = &.{ n(.AspectBodyItem) } },
    .{ .lhs = .AspectBodyListNE, .rhs = &.{ n(.AspectBodyListNE), n(.AspectBodyItem) } },

    // on before / on after / on around  (plain id clause name, no binding param)
    .{ .lhs = .AspectBodyItem, .rhs = &.{ t(.kw_on), t(.id), t(.eol), n(.Block) } },
    // on after(result) / on around(x)
    //   `after(` tokenizes as a single open_call token (identifier + no-space `(`).
    .{ .lhs = .AspectBodyItem, .rhs = &.{
        t(.kw_on), t(.open_call), t(.id), t(.rparen), t(.eol), n(.Block),
    } },
    // on error  (`error` is a keyword, so it's kw_error not id)
    .{ .lhs = .AspectBodyItem, .rhs = &.{ t(.kw_on), t(.kw_error), t(.eol), n(.Block) } },
    // on error(e)  (kw_error followed by lparen, not open_call)
    .{ .lhs = .AspectBodyItem, .rhs = &.{
        t(.kw_on), t(.kw_error), t(.lparen), t(.id), t(.rparen), t(.eol), n(.Block),
    } },
};

// ── Weaves clause and project-level weave declarations ───────────────────────
//
// Method/class level:
//   def save(data as String) weaves Logging
//   class Repository weaves Logging, Timing
//
// Project level (in project.zbr or build config):
//   weaves Logging to all def 'save*'
//   weaves Timing  to all class '*Repository'

const weave_rules: []const Rule = &.{
    // Nullable clause on declarations
    .{ .lhs = .WeavesOpt, .rhs = &.{} }, // ε
    .{ .lhs = .WeavesOpt, .rhs = &.{ t(.kw_weaves), n(.TypeRefListNE) } },

    // Project-level: weaves Aspect to all def Pattern
    .{ .lhs = .WeaveDecl, .rhs = &.{
        t(.kw_weaves), n(.TypeRef), t(.kw_to), t(.kw_all), t(.kw_def), n(.Atom), t(.eol),
    } },
    // Project-level: weaves Aspect to all class Pattern
    .{ .lhs = .WeaveDecl, .rhs = &.{
        t(.kw_weaves), n(.TypeRef), t(.kw_to), t(.kw_all), t(.kw_class), n(.Atom), t(.eol),
    } },
    // Project-level: weaves Aspect to all public def Pattern
    .{ .lhs = .WeaveDecl, .rhs = &.{
        t(.kw_weaves), n(.TypeRef), t(.kw_to), t(.kw_all), t(.kw_public), t(.kw_def), n(.Atom), t(.eol),
    } },
};

// ── Parameters ────────────────────────────────────────────────────────────────

const param_rules: []const Rule = &.{
    .{ .lhs = .ParamList,   .rhs = &.{} }, // ε
    .{ .lhs = .ParamList,   .rhs = &.{ n(.ParamListNE) } },
    .{ .lhs = .ParamListNE, .rhs = &.{ n(.Param) } },
    .{ .lhs = .ParamListNE, .rhs = &.{ n(.ParamListNE), t(.comma), n(.Param) } },

    // ParamModeOpt: optional vari prefix
    .{ .lhs = .ParamModeOpt, .rhs = &.{} }, // ε
    .{ .lhs = .ParamModeOpt, .rhs = &.{ t(.kw_vari) } },

    // param : [mode] name [as Type] [= default]
    .{ .lhs = .Param, .rhs = &.{ n(.ParamModeOpt), t(.id) } },
    .{ .lhs = .Param, .rhs = &.{ n(.ParamModeOpt), t(.id), t(.kw_as), n(.TypeRef) } },
    .{ .lhs = .Param, .rhs = &.{
        n(.ParamModeOpt), t(.id), t(.assign), n(.Expr),
    } },
    .{ .lhs = .Param, .rhs = &.{
        n(.ParamModeOpt), t(.id), t(.kw_as), n(.TypeRef), t(.assign), n(.Expr),
    } },
};

// ── Block ─────────────────────────────────────────────────────────────────────

const block_rules: []const Rule = &.{
    .{ .lhs = .Block,    .rhs = &.{ t(.indent), n(.StmtList), t(.dedent) } },
    .{ .lhs = .StmtList, .rhs = &.{ n(.Stmt) } },
    .{ .lhs = .StmtList, .rhs = &.{ n(.StmtList), n(.Stmt) } },
    .{ .lhs = .StmtList, .rhs = &.{ n(.StmtList), t(.eol) } }, // blank lines
};

// ── Statements ────────────────────────────────────────────────────────────────

const stmt_rules: []const Rule = &.{
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtReturn) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtPrint) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtPass) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtBreak) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtContinue) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtAssert) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtYield) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtIf) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtWhile) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtPostWhile) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtForIn) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtForNum) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtBranch) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtLocalVar) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtLocalVarLambda) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtDestruct) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtDestructStruct) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtAssign) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtExpr) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtExpect) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtLock) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtDefer) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtWith) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtArenaScope) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtRaise) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtTryCatch) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtGuard) } },
    .{ .lhs = .Stmt, .rhs = &.{ n(.StmtGuardInline) } },

    // Simple one-liner statements
    .{ .lhs = .StmtReturn,   .rhs = &.{ t(.kw_return), t(.eol) } },
    .{ .lhs = .StmtReturn,   .rhs = &.{ t(.kw_return), n(.Expr), t(.eol) } },
    .{ .lhs = .StmtPrint,    .rhs = &.{ t(.kw_print), n(.ExprList), t(.eol) } },
    .{ .lhs = .StmtPass,     .rhs = &.{ t(.kw_pass), t(.eol) } },
    .{ .lhs = .StmtBreak,    .rhs = &.{ t(.kw_break), t(.eol) } },
    .{ .lhs = .StmtContinue, .rhs = &.{ t(.kw_continue), t(.eol) } },
    .{ .lhs = .StmtAssert,   .rhs = &.{ t(.kw_assert), n(.Expr), t(.eol) } },
    .{ .lhs = .StmtAssert,   .rhs = &.{ t(.kw_assert), n(.Expr), t(.comma), n(.Expr), t(.eol) } },
    .{ .lhs = .StmtYield,    .rhs = &.{ t(.kw_yield), n(.Expr), t(.eol) } },

    // if / else if / else
    .{ .lhs = .StmtIf, .rhs = &.{ t(.kw_if), n(.Expr), t(.eol), n(.Block), n(.IfTail) } },
    .{ .lhs = .IfTail, .rhs = &.{} }, // ε — no else
    .{ .lhs = .IfTail, .rhs = &.{ n(.ElseIfClause), n(.IfTail) } },
    .{ .lhs = .IfTail, .rhs = &.{ n(.ElseClauseOpt) } },
    .{ .lhs = .ElseIfClause,  .rhs = &.{ t(.kw_else), t(.kw_if), n(.Expr), t(.eol), n(.Block) } },
    .{ .lhs = .ElseClauseOpt, .rhs = &.{} }, // ε
    .{ .lhs = .ElseClauseOpt, .rhs = &.{ t(.kw_else), t(.eol), n(.Block) } },

    // while [post]
    .{ .lhs = .StmtWhile, .rhs = &.{ t(.kw_while), n(.Expr), t(.eol), n(.Block) } },
    .{ .lhs = .StmtWhile, .rhs = &.{
        t(.kw_while), n(.Expr), t(.eol), n(.Block),
        t(.kw_post), t(.eol), n(.Block),
    } },
    // while var id = Expr, Expr eol Block — bind-and-guard form
    .{ .lhs = .StmtWhile, .rhs = &.{
        t(.kw_while), t(.kw_var), t(.id), t(.assign), n(.Expr), t(.comma), n(.Expr), t(.eol), n(.Block),
    } },

    // post while  (do-while: body executes, then condition is checked)
    .{ .lhs = .StmtPostWhile, .rhs = &.{ t(.kw_post), t(.kw_while), n(.Expr), t(.eol), n(.Block) } },

    // for x in collection
    .{ .lhs = .StmtForIn, .rhs = &.{
        t(.kw_for), n(.ForVarList), t(.kw_in), n(.Expr), t(.eol), n(.Block),
    } },
    .{ .lhs = .ForVarList, .rhs = &.{ t(.id) } },
    .{ .lhs = .ForVarList, .rhs = &.{ n(.ForVarList), t(.comma), t(.id) } },

    // for i in start:stop[:step]
    .{ .lhs = .StmtForNum, .rhs = &.{
        t(.kw_for), t(.id), t(.kw_in), n(.Expr), t(.colon), n(.Expr), t(.eol), n(.Block),
    } },
    .{ .lhs = .StmtForNum, .rhs = &.{
        t(.kw_for), t(.id), t(.kw_in),
        n(.Expr), t(.colon), n(.Expr), t(.colon), n(.Expr),
        t(.eol), n(.Block),
    } },

    // branch x \n on ... on ... [else ...]
    .{ .lhs = .StmtBranch, .rhs = &.{
        t(.kw_branch), n(.Expr), t(.eol),
        t(.indent), n(.BranchOnList), n(.BranchElseOpt), t(.dedent),
    } },
    .{ .lhs = .BranchOnList,   .rhs = &.{ n(.BranchOnClause) } },
    .{ .lhs = .BranchOnList,   .rhs = &.{ n(.BranchOnList), n(.BranchOnClause) } },
    .{ .lhs = .BranchOnList,   .rhs = &.{ n(.BranchOnList), t(.eol) } }, // blank lines between/after on-clauses
    // Normal block form: on expr_list eol Block
    .{ .lhs = .BranchOnClause, .rhs = &.{ t(.kw_on), n(.ExprListNE), t(.eol), n(.Block) } },
    // Inline form: on expr_list, stmt  (single-statement body on same line via comma)
    .{ .lhs = .BranchOnClause, .rhs = &.{ t(.kw_on), n(.ExprListNE), t(.comma), n(.Stmt) } },
    // Short return form: on expr return expr eol  (no comma or block needed)
    .{ .lhs = .BranchOnClause, .rhs = &.{ t(.kw_on), n(.Expr), t(.kw_return), n(.Expr), t(.eol) } },
    // Union binding form: on Expr as id eol Block  (for discriminated union dispatch)
    .{ .lhs = .BranchOnClause, .rhs = &.{ t(.kw_on), n(.Expr), t(.kw_as), t(.id), t(.eol), n(.Block) } },
    // Guarded binding form: on Expr as id if Expr eol Block
    .{ .lhs = .BranchOnClause, .rhs = &.{ t(.kw_on), n(.Expr), t(.kw_as), t(.id), t(.kw_if), n(.Expr), t(.eol), n(.Block) } },
    // Guarded non-binding form: on ExprListNE if Expr eol Block
    .{ .lhs = .BranchOnClause, .rhs = &.{ t(.kw_on), n(.ExprListNE), t(.kw_if), n(.Expr), t(.eol), n(.Block) } },
    .{ .lhs = .BranchElseOpt,  .rhs = &.{} }, // ε
    .{ .lhs = .BranchElseOpt,  .rhs = &.{ t(.kw_else), t(.eol), n(.Block) } },
    // Inline else: else, stmt
    .{ .lhs = .BranchElseOpt,  .rhs = &.{ t(.kw_else), t(.comma), n(.Stmt) } },

    // local var / const
    .{ .lhs = .StmtLocalVar, .rhs = &.{
        t(.kw_var), t(.id), n(.VarTypeOpt), n(.VarInitOpt), t(.eol),
    } },
    .{ .lhs = .StmtLocalVar, .rhs = &.{
        t(.kw_const), t(.id), n(.VarTypeOpt), t(.assign), n(.Expr), t(.eol),
    } },

    // destructuring: var (x, y) = expr  (tuple positional)
    .{ .lhs = .StmtDestruct, .rhs = &.{
        t(.kw_var), t(.lparen), n(.IdListNE), t(.rparen), t(.assign), n(.Expr), t(.eol),
    } },
    // struct destructuring: var {name, age} = expr  (field-name bindings)
    .{ .lhs = .StmtDestructStruct, .rhs = &.{
        t(.kw_var), t(.lcurly), n(.IdListNE), t(.rcurly), t(.assign), n(.Expr), t(.eol),
    } },
    .{ .lhs = .IdListNE, .rhs = &.{ t(.id) } },
    .{ .lhs = .IdListNE, .rhs = &.{ n(.IdListNE), t(.comma), t(.id) } },

    // assignment: target op value
    .{ .lhs = .StmtAssign, .rhs = &.{ n(.Expr), n(.AssignOp), n(.Expr), t(.eol) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.assign) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.plus_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.minus_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.star_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.slash_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.slashslash_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.percent_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.starstar_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.ampersand_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.vertical_bar_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.caret_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.double_lt_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.double_gt_equals) } },
    .{ .lhs = .AssignOp,   .rhs = &.{ t(.question_equals) } },

    // expression statement (call, etc.)
    .{ .lhs = .StmtExpr, .rhs = &.{ n(.Expr), t(.eol) } },

    // expect ExcType, expr  — assert an expression throws
    .{ .lhs = .StmtExpect, .rhs = &.{ t(.kw_expect), n(.TypeRef), t(.comma), n(.Expr), t(.eol) } },

    // lock obj eol Block
    .{ .lhs = .StmtLock, .rhs = &.{ t(.kw_lock), n(.Expr), t(.eol), n(.Block) } },

    // defer / errdefer — run on scope exit (/ error exit only)
    // The body is a single Stmt (which may itself be a block-form statement).
    .{ .lhs = .StmtDefer,    .rhs = &.{ t(.kw_defer),    n(.Stmt) } },
    .{ .lhs = .StmtDefer,    .rhs = &.{ t(.kw_errdefer), n(.Stmt) } },

    // with obj eol Block — contextual self
    .{ .lhs = .StmtWith,       .rhs = &.{ t(.kw_with),  n(.Expr), t(.eol), n(.Block) } },
    .{ .lhs = .StmtArenaScope, .rhs = &.{ t(.kw_arena), t(.eol), n(.Block) } },

    // guard Expr else eol Block     — block form: guard x > 0 else\n    return
    // guard Expr else, Stmt         — inline form: guard x > 0 else, return
    .{ .lhs = .StmtGuard,       .rhs = &.{ t(.kw_guard), n(.Expr), t(.kw_else), t(.eol), n(.Block) } },
    .{ .lhs = .StmtGuardInline, .rhs = &.{ t(.kw_guard), n(.Expr), t(.kw_else), t(.comma), n(.Stmt) } },

    // raise [msg] [, details] eol
    .{ .lhs = .StmtRaise, .rhs = &.{ t(.kw_raise), t(.eol) } },
    .{ .lhs = .StmtRaise, .rhs = &.{ t(.kw_raise), n(.Expr), t(.eol) } },
    .{ .lhs = .StmtRaise, .rhs = &.{ t(.kw_raise), n(.Expr), t(.comma), n(.Expr), t(.eol) } },

    // try eol Block CatchClauseList
    .{ .lhs = .StmtTryCatch, .rhs = &.{ t(.kw_try), t(.eol), n(.Block), n(.CatchClauseList) } },
    .{ .lhs = .CatchClauseList, .rhs = &.{ n(.CatchClause) } },
    .{ .lhs = .CatchClauseList, .rhs = &.{ n(.CatchClauseList), n(.CatchClause) } },
    // catch — catch-all, no binding
    .{ .lhs = .CatchClause, .rhs = &.{ t(.kw_catch), t(.eol), n(.Block) } },
    // catch |e| — untyped binding
    .{ .lhs = .CatchClause, .rhs = &.{
        t(.kw_catch), t(.vertical_bar), t(.id), t(.vertical_bar), t(.eol), n(.Block),
    } },
    // catch |e as ErrorInfo(ParseError)| — typed binding
    .{ .lhs = .CatchClause, .rhs = &.{
        t(.kw_catch), t(.vertical_bar), t(.id), t(.kw_as), n(.TypeRef), t(.vertical_bar), t(.eol), n(.Block),
    } },
};

// ── Expressions ───────────────────────────────────────────────────────────────
//
// Precedence from lowest to highest:
//   Expr  → or
//   Expr2 → and
//   Expr3 → not (right-recursive unary)
//   Expr4 → comparisons
//   Expr5 → additive
//   Expr6 → multiplicative
//   Expr7 → exponentiation
//   Expr8 → unary prefix
//   Expr9 → postfix / member / call / index / cast
//   Atom  → primary

const expr_rules: []const Rule = &.{
    // Expr → pipeline (lowest precedence), then or / orelse / catch
    // a -> f(args)  left-associative; RHS must be a call expression
    .{ .lhs = .Expr,  .rhs = &.{ n(.Expr), t(.arrow), n(.PipelineCall) } },
    // PipelineCall: open_call ArgList rparen  (captures `f(args)` on RHS)
    .{ .lhs = .PipelineCall, .rhs = &.{ t(.open_call), n(.ArgList), t(.rparen) } },
    // member call: obj.method(args) on RHS of pipeline
    .{ .lhs = .PipelineCall, .rhs = &.{ n(.Expr9), t(.dot), t(.open_call), n(.ArgList), t(.rparen) } },

    // Expr → or / orelse / catch
    .{ .lhs = .Expr,  .rhs = &.{ n(.Expr), t(.kw_or),     n(.Expr2) } },
    // orelse — optional/error-union fallback: `foo() orelse default`
    .{ .lhs = .Expr,  .rhs = &.{ n(.Expr), t(.kw_orelse), n(.Expr2) } },
    // catch — error-union recovery: `foo() catch 0`
    .{ .lhs = .Expr,  .rhs = &.{ n(.Expr), t(.kw_catch),  n(.Expr2) } },
    // catch with binding: `foo() catch |e| handleErr(e)`
    // `|` is vertical_bar token; binding var is a plain id
    .{ .lhs = .Expr,  .rhs = &.{
        n(.Expr), t(.kw_catch), t(.vertical_bar), t(.id), t(.vertical_bar), n(.Expr2),
    } },
    .{ .lhs = .Expr,  .rhs = &.{ n(.Expr2) } },

    // Expr2 → and
    .{ .lhs = .Expr2, .rhs = &.{ n(.Expr2), t(.kw_and), n(.Expr3) } },
    .{ .lhs = .Expr2, .rhs = &.{ n(.Expr3) } },

    // Expr3 → not (right-recursive)
    .{ .lhs = .Expr3, .rhs = &.{ t(.kw_not), n(.Expr3) } },
    .{ .lhs = .Expr3, .rhs = &.{ n(.Expr4) } },

    // Expr4 → comparisons
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.eq),            n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.ne),            n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.bang_equals),  n(.Expr5) } }, // != alias for <>

    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.lt),            n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.gt),            n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.le),            n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.ge),            n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.kw_is),         n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.kw_in),         n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr4), t(.kw_not), t(.kw_in), n(.Expr5) } },
    .{ .lhs = .Expr4, .rhs = &.{ n(.Expr5) } },

    // Expr5 → additive, and range (`a..b` — used in branch on-clauses and literals)
    .{ .lhs = .Expr5, .rhs = &.{ n(.Expr5), t(.plus),   n(.Expr6) } },
    .{ .lhs = .Expr5, .rhs = &.{ n(.Expr5), t(.minus),  n(.Expr6) } },
    .{ .lhs = .Expr5, .rhs = &.{ n(.Expr6), t(.dotdot), n(.Expr6) } }, // range: a..b
    .{ .lhs = .Expr5, .rhs = &.{ n(.Expr6) } },

    // Expr6 → multiplicative
    .{ .lhs = .Expr6, .rhs = &.{ n(.Expr6), t(.star),       n(.Expr7) } },
    .{ .lhs = .Expr6, .rhs = &.{ n(.Expr6), t(.slash),      n(.Expr7) } },
    .{ .lhs = .Expr6, .rhs = &.{ n(.Expr6), t(.slashslash), n(.Expr7) } },
    .{ .lhs = .Expr6, .rhs = &.{ n(.Expr6), t(.percent),    n(.Expr7) } },
    .{ .lhs = .Expr6, .rhs = &.{ n(.Expr7) } },

    // Expr7 → exponentiation (left-associative in Zebra)
    .{ .lhs = .Expr7, .rhs = &.{ n(.Expr7), t(.starstar), n(.Expr8) } },
    .{ .lhs = .Expr7, .rhs = &.{ n(.Expr8) } },

    // Expr8 → unary prefix
    .{ .lhs = .Expr8, .rhs = &.{ t(.minus),   n(.Expr9) } },
    .{ .lhs = .Expr8, .rhs = &.{ t(.tilde),   n(.Expr9) } },
    // old — refers to pre-call value in contract `ensure` clauses
    .{ .lhs = .Expr8, .rhs = &.{ t(.kw_old),  n(.Expr9) } },
    // try expr — propagate error upward (expression form)
    .{ .lhs = .Expr8, .rhs = &.{ t(.kw_try),  n(.Expr8) } },
    .{ .lhs = .Expr8, .rhs = &.{ n(.Expr9) } },

    // Expr9 → postfix: member access, chained call, index, cast
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.dot), t(.id) } },                             // obj.member
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.dot), t(.integer_lit) } },                    // tuple.0  tuple.1
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.dot), t(.open_call), n(.ArgList), t(.rparen) } }, // obj.method(args)
    // Allow keyword names as method-call targets: obj.get(args)  obj.post(args)
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.dot), t(.kw_get),  t(.lparen), n(.ArgList), t(.rparen) } }, // obj.get(args)
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.dot), t(.kw_post), t(.lparen), n(.ArgList), t(.rparen) } }, // obj.post(args)
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.lbracket), n(.Expr), t(.rbracket) } },        // obj[index]
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.lbracket), n(.Expr), t(.dotdot), n(.Expr), t(.rbracket) } }, // obj[start..stop]
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.kw_to), n(.TypeRef) } },                       // expr to T
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.toq) } },                                      // expr to?
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.kw_to), t(.bang) } },                          // expr to!  (non-nil assert)
    .{ .lhs = .Expr9, .rhs = &.{ n(.Expr9), t(.question) } },                                 // expr?  (propagate error — sugar for try expr)
    .{ .lhs = .Expr9, .rhs = &.{ n(.Atom) } },

    // Lambda expression: def(params) [as T] = Expr  (expression-body, single line)
    .{ .lhs = .Atom, .rhs = &.{ n(.LambdaExpr) } },
    // Block-body lambda as argument: def(params) [as T] eol indent CaptureOpt StmtList dedent
    .{ .lhs = .Atom, .rhs = &.{ n(.LambdaBlockExpr) } },

    // Atom → primary expressions
    // — Numeric literals
    .{ .lhs = .Atom, .rhs = &.{ t(.integer_lit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.integer_lit_explicit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.hex_lit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.hex_lit_unsign) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.hex_lit_explicit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.float_lit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.float_lit_exp) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.fractional_lit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.decimal_lit) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.number_lit) } },
    // — Boolean / nil
    .{ .lhs = .Atom, .rhs = &.{ t(.kw_true) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.kw_false) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.kw_nil) } },
    // — Self-reference
    .{ .lhs = .Atom, .rhs = &.{ t(.kw_this) } },
    // — Identifier
    .{ .lhs = .Atom, .rhs = &.{ t(.id) } },
    // — Self-member access: .foo  .foo(args)  (implicit `this`)
    .{ .lhs = .Atom, .rhs = &.{ t(.dot), t(.id) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.dot), t(.open_call), n(.ArgList), t(.rparen) } },
    // — Call: open_call consumes the `(`; args follow; `)` is rparen
    .{ .lhs = .Atom, .rhs = &.{ t(.open_call), n(.ArgList), t(.rparen) } },
    // Generic construction: Stack(int)() or Stack(int)(5)
    // The tokenizer emits `open_call` for `Stack(`, then TypeRefListNE for type args,
    // then `rparen` closing the type args, then `lparen` (standalone) for value args.
    // Unambiguous because `lparen` after `rparen` never appears in regular call syntax.
    .{ .lhs = .Atom, .rhs = &.{ n(.GenericConstruct) } },
    .{ .lhs = .GenericConstruct, .rhs = &.{ t(.open_call), n(.TypeRefListNE), t(.rparen), t(.lparen), t(.rparen) } },
    .{ .lhs = .GenericConstruct, .rhs = &.{ t(.open_call), n(.TypeRefListNE), t(.rparen), t(.lparen), n(.ArgList), t(.rparen) } },
    // — Grouped expression
    .{ .lhs = .Atom, .rhs = &.{ t(.lparen), n(.Expr), t(.rparen) } },
    // — Tuple literal: (a, b)  (a, b, c)  …
    .{ .lhs = .Atom, .rhs = &.{ t(.lparen), n(.Expr), t(.comma), n(.ExprListNE), t(.rparen) } },
    // — Ternary if(cond, then, else): kw_if followed by lparen (not open_call since `if` is a keyword)
    .{ .lhs = .Atom, .rhs = &.{
        t(.kw_if), t(.lparen), n(.Expr), t(.comma), n(.Expr), t(.comma), n(.Expr), t(.rparen),
    } },
    // — Array literal @[...]
    .{ .lhs = .Atom, .rhs = &.{ t(.at_lbracket), n(.ArgList), t(.rbracket) } },
    // — Char literals: c'A'  c"A"
    .{ .lhs = .Atom, .rhs = &.{ t(.char_lit_single) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.char_lit_double) } },
    // — String literals (all forms)
    .{ .lhs = .Atom, .rhs = &.{ t(.string_single) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.string_double) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.string_nosub_single) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.string_nosub_double) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.string_raw_single) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.string_raw_double) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.zig_single) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.zig_double) } },
    .{ .lhs = .Atom, .rhs = &.{ t(.doc_string_line) } },
    // — Interpolated strings
    .{ .lhs = .Atom, .rhs = &.{
        t(.string_start_single), n(.InterpBodyS), t(.string_stop_single),
    } },
    .{ .lhs = .Atom, .rhs = &.{
        t(.string_start_double), n(.InterpBodyD), t(.string_stop_double),
    } },
    // — all / any comprehensions
    .{ .lhs = .Atom, .rhs = &.{ n(.AllAnyExpr) } },
};

// ── All / any comprehensions ──────────────────────────────────────────────────
//
// all for s in list get s > 0
// any for s in list get s > 0

const all_any_rules: []const Rule = &.{
    .{ .lhs = .AllAnyExpr, .rhs = &.{
        t(.kw_all), t(.kw_for), n(.ForVarList), t(.kw_in), n(.Expr), t(.kw_get), n(.Expr),
    } },
    .{ .lhs = .AllAnyExpr, .rhs = &.{
        t(.kw_any), t(.kw_for), n(.ForVarList), t(.kw_in), n(.Expr), t(.kw_get), n(.Expr),
    } },
};

// ── String interpolation ──────────────────────────────────────────────────────
//
// For  "hello ${name}!"  the token stream is:
//   string_start_double  Expr...  rcurly_special  string_stop_double
//
// For  "a ${x} b ${y} c"  it is:
//   string_start_double  Expr  rcurly_special
//   string_part_double   Expr  rcurly_special
//   string_stop_double
//
// InterpBodyS/D:  first interpolation segment (Expr + optional format + ])
// InterpRestS/D:  remaining segments (part + Expr + format? + ]) or ε

const interp_rules: []const Rule = &.{
    // Single-quoted interpolation
    .{ .lhs = .InterpBodyS, .rhs = &.{ n(.InterpExprS), t(.rcurly_special), n(.InterpRestS) } },
    .{ .lhs = .InterpRestS, .rhs = &.{} }, // ε — next token will be string_stop_single
    .{ .lhs = .InterpRestS, .rhs = &.{
        t(.string_part_single), n(.InterpExprS), t(.rcurly_special), n(.InterpRestS),
    } },
    .{ .lhs = .InterpExprS, .rhs = &.{ n(.Expr) } },
    .{ .lhs = .InterpExprS, .rhs = &.{ n(.Expr), t(.string_part_format) } },

    // Double-quoted interpolation
    .{ .lhs = .InterpBodyD, .rhs = &.{ n(.InterpExprD), t(.rcurly_special), n(.InterpRestD) } },
    .{ .lhs = .InterpRestD, .rhs = &.{} }, // ε
    .{ .lhs = .InterpRestD, .rhs = &.{
        t(.string_part_double), n(.InterpExprD), t(.rcurly_special), n(.InterpRestD),
    } },
    .{ .lhs = .InterpExprD, .rhs = &.{ n(.Expr) } },
    .{ .lhs = .InterpExprD, .rhs = &.{ n(.Expr), t(.string_part_format) } },
};

// ── Argument and expression lists ─────────────────────────────────────────────

const list_rules: []const Rule = &.{
    // ArgList — for function calls
    .{ .lhs = .ArgList,   .rhs = &.{} }, // ε — no arguments
    .{ .lhs = .ArgList,   .rhs = &.{ n(.ArgListNE) } },
    .{ .lhs = .ArgListNE, .rhs = &.{ n(.Expr) } },
    .{ .lhs = .ArgListNE, .rhs = &.{ n(.ArgListNE), t(.comma), n(.Expr) } },
    // Named argument: label: Expr
    .{ .lhs = .ArgListNE, .rhs = &.{ t(.id), t(.colon), n(.Expr) } },
    .{ .lhs = .ArgListNE, .rhs = &.{ n(.ArgListNE), t(.comma), t(.id), t(.colon), n(.Expr) } },

    // ExprList — for print, branch on, etc.
    .{ .lhs = .ExprList,   .rhs = &.{} }, // ε
    .{ .lhs = .ExprList,   .rhs = &.{ n(.ExprListNE) } },
    .{ .lhs = .ExprListNE, .rhs = &.{ n(.Expr) } },
    .{ .lhs = .ExprListNE, .rhs = &.{ n(.ExprListNE), t(.comma), n(.Expr) } },
};

// ── Lambda expressions ────────────────────────────────────────────────────────
//
// Expression-body (single line, works anywhere an Atom is valid):
//   def(params) [as T] = Expr
//
// Statement-body (multi-line, only valid as RHS of var/const declaration):
//   handled by extra StmtLocalVar rules below.

const lambda_rules: []const Rule = &.{
    // def(params) [as T] = Expr  — expression-body lambda
    .{ .lhs = .LambdaExpr, .rhs = &.{
        t(.kw_def), t(.lparen), n(.ParamList), t(.rparen), n(.ReturnAnnotOpt),
        t(.assign), n(.Expr),
    } },
    // def(params) [as T] eol indent CaptureOpt StmtList dedent  — block-body lambda as arg
    .{ .lhs = .LambdaBlockExpr, .rhs = &.{
        t(.kw_def), t(.lparen), n(.ParamList), t(.rparen), n(.ReturnAnnotOpt),
        t(.eol), t(.indent), n(.CaptureOpt), n(.StmtList), t(.dedent),
    } },
};

// ── Capture block (inside statement-body lambdas) ─────────────────────────────

const capture_rules: []const Rule = &.{
    .{ .lhs = .CaptureOpt,     .rhs = &.{} }, // ε
    .{ .lhs = .CaptureOpt,     .rhs = &.{ n(.CaptureBlock) } },
    .{ .lhs = .CaptureBlock,   .rhs = &.{
        t(.kw_capture), t(.eol), t(.indent), n(.CaptureVarList), t(.dedent),
    } },
    .{ .lhs = .CaptureVarList, .rhs = &.{ n(.CaptureVar) } },
    .{ .lhs = .CaptureVarList, .rhs = &.{ n(.CaptureVarList), n(.CaptureVar) } },
    // var id [as TypeRef] [= Expr] eol
    .{ .lhs = .CaptureVar,     .rhs = &.{
        t(.kw_var), t(.id), n(.VarTypeOpt), n(.VarInitOpt), t(.eol),
    } },
    // const id [as TypeRef] = Expr eol
    .{ .lhs = .CaptureVar,     .rhs = &.{
        t(.kw_const), t(.id), n(.VarTypeOpt), t(.assign), n(.Expr), t(.eol),
    } },
};

// Statement-body lambdas as var/const RHS.
// Token stream: kw_var id VarTypeOpt assign kw_def lparen params rparen ReturnAnnotOpt
//               eol indent CaptureOpt StmtList dedent
const lambda_stmt_rules: []const Rule = &.{
    .{ .lhs = .StmtLocalVarLambda, .rhs = &.{
        t(.kw_var), t(.id), n(.VarTypeOpt),
        t(.assign), t(.kw_def), t(.lparen), n(.ParamList), t(.rparen), n(.ReturnAnnotOpt),
        t(.eol), t(.indent), n(.CaptureOpt), n(.StmtList), t(.dedent),
    } },
    .{ .lhs = .StmtLocalVarLambda, .rhs = &.{
        t(.kw_const), t(.id), n(.VarTypeOpt),
        t(.assign), t(.kw_def), t(.lparen), n(.ParamList), t(.rparen), n(.ReturnAnnotOpt),
        t(.eol), t(.indent), n(.CaptureOpt), n(.StmtList), t(.dedent),
    } },
};

// ── Union declarations ────────────────────────────────────────────────────────
//
// union Shape
//     circle as float    — variant with payload type
//     rect as Rect
//     point              — variant with no payload

const sig_rules: []const Rule = &.{
    // sig Name(params) as RetType eol  — named function-type alias (delegate)
    // Name( is one open_call token (identifier immediately followed by `(`).
    .{ .lhs = .SigDecl, .rhs = &.{ t(.kw_sig), t(.open_call), n(.ParamList), t(.rparen), n(.ReturnAnnotOpt), t(.eol) } },
};

const union_rules: []const Rule = &.{
    .{ .lhs = .DeclUnion, .rhs = &.{
        n(.ModList), t(.kw_union), t(.id), t(.eol),
        t(.indent), n(.UnionVariantList), t(.dedent),
    } },
    .{ .lhs = .UnionVariantList, .rhs = &.{ n(.UnionVariant) } },
    .{ .lhs = .UnionVariantList, .rhs = &.{ n(.UnionVariantList), n(.UnionVariant) } },
    .{ .lhs = .UnionVariantList, .rhs = &.{ n(.UnionVariantList), t(.eol) } }, // blank lines
    // plain variant (no payload): name eol
    .{ .lhs = .UnionVariant, .rhs = &.{ t(.id), t(.eol) } },
    // typed variant: name as TypeRef eol
    .{ .lhs = .UnionVariant, .rhs = &.{ t(.id), t(.kw_as), n(.TypeRef), t(.eol) } },
};

// ── except struct-update ──────────────────────────────────────────────────────
//
// var updated = original except
//     count = original.count + 1
//     name = "new"
//
// Grammar adds extra StmtLocalVar and StmtAssign rules that match
//   ... Expr kw_except eol indent ExceptFieldList dedent
// No ambiguity: after the RHS Expr the parser sees kw_except vs eol.

const except_rules: []const Rule = &.{
    // var id [as T] = Expr except eol indent ExceptFieldList dedent
    .{ .lhs = .StmtLocalVar, .rhs = &.{
        t(.kw_var), t(.id), n(.VarTypeOpt), t(.assign), n(.Expr),
        t(.kw_except), t(.eol), t(.indent), n(.ExceptFieldList), t(.dedent),
    } },
    // id = Expr except eol indent ExceptFieldList dedent
    .{ .lhs = .StmtAssign, .rhs = &.{
        n(.Expr), n(.AssignOp), n(.Expr),
        t(.kw_except), t(.eol), t(.indent), n(.ExceptFieldList), t(.dedent),
    } },
    // field list
    .{ .lhs = .ExceptFieldList, .rhs = &.{ n(.ExceptField) } },
    .{ .lhs = .ExceptFieldList, .rhs = &.{ n(.ExceptFieldList), n(.ExceptField) } },
    // id = Expr eol
    .{ .lhs = .ExceptField, .rhs = &.{ t(.id), t(.assign), n(.Expr), t(.eol) } },
};

// ── Combined rule table ───────────────────────────────────────────────────────

/// All grammar rules, concatenated at compile time.
const rules: []const Rule = program_rules ++
    use_rules ++
    namespace_rules ++
    mod_rules ++
    is_clause_rules ++
    has_rules ++
    type_rules ++
    class_rules ++
    interface_rules ++
    struct_rules ++
    mixin_rules ++
    enum_rules ++
    extend_rules ++
    at_directive_rules ++
    member_rules ++
    method_rules ++
    prop_rules ++
    pro_rules ++
    var_member_rules ++
    init_rules ++
    group_member_rules ++
    contract_rules ++
    aspect_rules ++
    weave_rules ++
    param_rules ++
    block_rules ++
    stmt_rules ++
    expr_rules ++
    all_any_rules ++
    interp_rules ++
    list_rules ++
    lambda_rules ++
    capture_rules ++
    lambda_stmt_rules ++
    union_rules ++
    sig_rules ++
    except_rules;
