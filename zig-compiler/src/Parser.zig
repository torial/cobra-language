//! Zebra parser: token stream → concrete parse tree.
//!
//! Wires the Earley library to the Zebra grammar:
//!
//!   1. Extract `TokenKind` values from the source `Token` array.
//!   2. Compute the nullable set (which nonterminals can derive ε).
//!   3. Run the Earley recogniser.
//!   4. If accepted, extract a concrete syntax tree via the SPPF.
//!   5. If rejected, report the furthest token position the parser reached.
//!
//! ## Usage
//!
//! ```zig
//! const Parser = @import("Parser.zig");
//!
//! var result = try Parser.parse(tokens, allocator);  // tokens from Tokenizer.tokenize
//! defer result.deinit();
//!
//! switch (result) {
//!     .ok  => |*ok|  { _ = ok.tree.root; },
//!     .err => |*err| { std.debug.print("parse error near token {}\n", .{err.error_pos}); },
//! }
//! ```

const std    = @import("std");
const earley = @import("earley");

const TokenMod  = @import("Token.zig");
const Token     = TokenMod.Token;
const TokenKind = TokenMod.TokenKind;
const kindsOf   = TokenMod.kindsOf;
const G         = @import("ZebraGrammar.zig");

const Allocator = std.mem.Allocator;

// ── Re-exports ────────────────────────────────────────────────────────────────

pub const ParseTree = earley.ParseTree(TokenKind);
pub const TreeNode  = earley.TreeNode(TokenKind);

// ── Result types ──────────────────────────────────────────────────────────────

/// A successful parse.
///
/// `tree` is the concrete syntax tree (left-associative disambiguation).
/// `tokens` is a non-owning pointer back into the caller's token buffer — it
/// is stable as long as the caller holds that buffer.
pub const ParseSuccess = struct {
    tree:   ParseTree,
    tokens: []const Token,

    pub fn deinit(self: *ParseSuccess) void {
        self.tree.deinit();
    }
};

/// A parse failure.
///
/// `error_pos` is the index (into `tokens`) of the furthest token the Earley
/// chart managed to process.  It is the most precise error-location signal
/// available without full error-recovery.
pub const ParseError = struct {
    /// Index of the first unparseable token.  Equal to `tokens.len` when the
    /// parser accepted a prefix but expected more input.
    error_pos: u32,
    tokens:    []const Token,
};

pub const ParseResult = union(enum) {
    ok:  ParseSuccess,
    err: ParseError,

    pub fn deinit(self: *ParseResult) void {
        switch (self.*) {
            .ok  => |*s| s.deinit(),
            .err => {},
        }
    }

    pub fn isOk(self: ParseResult) bool {
        return self == .ok;
    }
};

// ── parse ─────────────────────────────────────────────────────────────────────

/// Parse a Zebra source file's token stream into a concrete syntax tree.
///
/// `tokens` is the output of `Tokenizer.tokenize`.  It must remain live until
/// the returned `ParseResult` is deinitialized.
///
/// `alloc` is used for the Earley chart, nullable bit-set, and parse-tree
/// nodes.  All per-parse memory is freed when you call `result.deinit()`.
pub fn parse(tokens: []const Token, alloc: Allocator) !ParseResult {
    // 1. Strip location metadata — Earley only needs the kind sequence.
    const kinds = try kindsOf(tokens, alloc);
    defer alloc.free(kinds);

    // 2. Compute which grammar nonterminals are nullable (derive ε).
    //    One pass over the grammar; cheap relative to parsing.
    var nullable = try earley.computeNullable(TokenKind, G.grammar, alloc);
    defer nullable.deinit(alloc);

    // 3. Run the Earley recogniser.
    const p = earley.Parser(TokenKind).init(&G.grammar, &nullable, alloc);
    var outcome = try p.parse(kinds);
    defer outcome.deinit();

    if (!outcome.accepted) {
        const error_pos = furthestPos(&outcome.chart, @intCast(kinds.len));
        return .{ .err = .{ .error_pos = error_pos, .tokens = tokens } };
    }

    // 4. Extract the parse tree from the Earley chart via the SPPF.
    //    Left-associative disambiguation: for `a + b + c`, prefer `(a+b)+c`.
    const sppf = earley.Sppf(TokenKind).init(&outcome.chart, &G.grammar, kinds);
    const tree  = try sppf.buildTree(.left_assoc, alloc);

    return .{ .ok = .{ .tree = tree, .tokens = tokens } };
}

// ── Error location heuristic ──────────────────────────────────────────────────

/// Return the index of the last Earley set that contained at least one item.
///
/// The Earley algorithm fills sets left to right; the rightmost non-empty set
/// is the furthest point in the input at which the parse was still viable.
/// For a rejected input this is always ≤ token_count.
fn furthestPos(chart: *const earley.Chart, token_count: u32) u32 {
    // chart.setCount() is the number of sets opened: 0..=token_count for a
    // complete run, possibly fewer if the parser short-circuited.
    const n = @min(chart.setCount(), token_count + 1);
    var i: u32 = n;
    while (i > 0) {
        i -= 1;
        if (chart.getSet(i).len > 0) return i;
    }
    return 0;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing   = std.testing;
const Tokenizer = @import("Tokenizer.zig");

// ── Test helpers ───────────────────────────────────────────────────────────────

/// Tokenize `src`, parse it, and assert the result was accepted.
/// Prints the offending token kind + position on unexpected rejection.
fn expectAccepts(src: []const u8) !void {
    const tokens = try Tokenizer.tokenize(src, testing.allocator);
    defer testing.allocator.free(tokens);
    var result = try parse(tokens, testing.allocator);
    defer result.deinit();
    if (!result.isOk()) {
        const e = result.err;
        const kind_str: []const u8 = if (e.error_pos < e.tokens.len)
            @tagName(e.tokens[e.error_pos].kind)
        else
            "(past end)";
        std.debug.print(
            "expected accept, got error at pos {} ({s})\n",
            .{ e.error_pos, kind_str },
        );
    }
    try testing.expect(result.isOk());
}

/// Tokenize `src`, parse it, and assert the result was rejected.
fn expectRejects(src: []const u8) !void {
    const tokens = try Tokenizer.tokenize(src, testing.allocator);
    defer testing.allocator.free(tokens);
    var result = try parse(tokens, testing.allocator);
    defer result.deinit();
    try testing.expect(!result.isOk());
}

// ── Acceptance: program-level structure ───────────────────────────────────────

test "parse: empty program" {
    // Tokenizer always appends eof; grammar: Program → TopDeclList(ε) eof
    try expectAccepts("");
}

test "parse: simple use directive" {
    // UseDecl → kw_use UsePath(id) eol
    try expectAccepts("use Sys\n");
}

test "parse: dotted use path is left-recursive" {
    // UsePath → UsePath . id — exercises the recursive UsePath rule
    try expectAccepts("use System.Collections.Generic\n");
}

test "parse: enum declaration" {
    // EnumDecl + two EnumMember entries (plain id form)
    try expectAccepts("enum Color\n\tred\n\tgreen\n\tblue\n");
}

// ── Acceptance: class and member declarations ──────────────────────────────────

test "parse: class with var member" {
    // Simplest valid non-empty class body: VarMemberDecl with an explicit type
    try expectAccepts("class Foo\n\tvar x as int\n");
}

test "parse: method declaration without body" {
    // MethodDecl (no-arg, no-return) with no Block — valid abstract-style decl
    try expectAccepts("class Foo\n\tdef run\n");
}

test "parse: method with typed parameter and return annotation" {
    // MethodDecl: open_call ParamList(Param(id as TypeRef)) rparen ReturnAnnotOpt eol
    try expectAccepts("class Foo\n\tdef greet(name as String) as String\n");
}

test "parse: class implements interface" {
    // ClassHeader → ImplementsClauseOpt(kw_implements TypeRefListNE)
    try expectAccepts("class Foo implements IBar\n\tdef run\n");
}

// ── Acceptance: statements inside method bodies ────────────────────────────────

test "parse: method with pass body" {
    // Block → indent StmtList(StmtPass) dedent — three indentation levels
    try expectAccepts("class Foo\n\tdef run\n\t\tpass\n");
}

test "parse: return with expression" {
    // StmtReturn → kw_return Expr(Atom(string_single)) eol
    try expectAccepts("class Foo\n\tdef greet as String\n\t\treturn 'hello'\n");
}

test "parse: assignment statement" {
    // StmtAssign → Expr(id) AssignOp(assign) Expr(integer_lit) eol
    try expectAccepts("class Foo\n\tdef run\n\t\tx = 42\n");
}

test "parse: augmented assignment" {
    // StmtAssign → Expr(id) AssignOp(plus_equals) Expr(integer_lit) eol
    try expectAccepts("class Foo\n\tdef run\n\t\tx += 1\n");
}

test "parse: if without else" {
    // StmtIf with IfTail → ε (nullable — no else branch)
    try expectAccepts("class Foo\n\tdef run\n\t\tif x\n\t\t\tpass\n");
}

test "parse: if with else" {
    // IfTail → ElseClauseOpt(kw_else eol Block)
    // Exercises the DEDENT-before-else token pattern
    try expectAccepts("class Foo\n\tdef run\n\t\tif x\n\t\t\tpass\n\t\telse\n\t\t\tpass\n");
}

test "parse: while loop" {
    // StmtWhile → kw_while Expr eol Block
    try expectAccepts("class Foo\n\tdef run\n\t\twhile x\n\t\t\tpass\n");
}

test "parse: for-in loop" {
    // StmtForIn → kw_for ForVarList(id) kw_in Expr eol Block
    try expectAccepts("class Foo\n\tdef run\n\t\tfor item in items\n\t\t\tpass\n");
}

test "parse: print statement with interpolated string" {
    // StmtPrint → kw_print ExprList eol
    // Atom → string_start_double InterpBodyD string_stop_double
    try expectAccepts("class Foo\n\tdef run\n\t\tprint \"hi ${name}!\"\n");
}

test "parse: chained method call as statement" {
    // Expr9 → Expr9(kw_this) dot open_call ArgList(Expr) rparen
    // StmtExpr → Expr eol
    try expectAccepts("class Foo\n\tdef run\n\t\tthis.show(42)\n");
}

test "parse: arithmetic expression in assignment" {
    // Tests operator precedence: a + b * c parses as a + (b * c)
    // StmtAssign: id = Expr5(a + Expr6(b * c))
    try expectAccepts("class Foo\n\tdef run\n\t\tx = a + b * c\n");
}

// ── Tree structure ─────────────────────────────────────────────────────────────

test "parse: tree root is Program spanning all tokens" {
    const tokens = try Tokenizer.tokenize("use Sys\n", testing.allocator);
    defer testing.allocator.free(tokens);
    var result = try parse(tokens, testing.allocator);
    defer result.deinit();
    try testing.expect(result.isOk());

    const root = result.ok.tree.root;
    try testing.expect(root == .inner);
    // NT.Program is ordinal 0 in the NT enum → grammar index 0
    try testing.expectEqual(@as(u16, @intFromEnum(G.NT.Program)), root.inner.nt);
    // Program always spans from token 0 to the end
    try testing.expectEqual(@as(u32, 0), root.inner.start);
    try testing.expectEqual(@as(u32, @intCast(tokens.len)), root.inner.end);
}

// ── Rejection cases ────────────────────────────────────────────────────────────

test "parse: rejects empty token stream (no eof token)" {
    // Bypasses the tokenizer — no eof means grammar can never match Program
    var result = try parse(&.{}, testing.allocator);
    defer result.deinit();
    try testing.expect(!result.isOk());
}

test "parse: rejects statement in class body" {
    // `pass` is a Stmt, not a MemberDecl — only methods/vars/props are allowed
    // at class body scope
    try expectRejects("class Foo\n\tpass\n");
}

// ── Acceptance: namespace, extend ────────────────────────────────────────────

test "parse: namespace wrapping class" {
    // NamespaceDecl → kw_namespace UsePath eol indent TopDeclList dedent
    try expectAccepts("namespace Foo\n\tclass Bar\n\t\tdef run\n");
}

test "parse: dotted namespace" {
    try expectAccepts("namespace System.Collections\n\tclass List\n\t\tdef run\n");
}

test "parse: extend declaration" {
    // ExtendDecl → kw_extend TypeRef … MemberDeclList
    try expectAccepts("extend String\n\tdef doubled as String\n\t\treturn this + this\n");
}

// ── Acceptance: is / has clauses ──────────────────────────────────────────────

test "parse: method with is shared" {
    // IsClauseOpt → kw_is IsAttrList
    try expectAccepts("class Foo\n\tdef main is shared\n");
}

test "parse: class with is abstract" {
    try expectAccepts("class Foo is abstract\n\tdef run\n");
}

test "parse: method with is shared and body" {
    try expectAccepts("class Foo\n\tdef main is shared\n\t\tpass\n");
}

// ── Acceptance: grouped member blocks ─────────────────────────────────────────

test "parse: shared group block" {
    // SharedGroupDecl → kw_shared eol indent MemberDeclList dedent
    try expectAccepts("class Foo\n\tshared\n\t\tdef main\n\t\t\tpass\n");
}

test "parse: test member block" {
    // TestMemberDecl → kw_test eol indent StmtList dedent
    try expectAccepts("class Foo\n\ttest\n\t\tpass\n");
}

test "parse: invariant block" {
    // InvariantDecl → kw_invariant eol indent StmtList dedent
    try expectAccepts("class Foo\n\tinvariant\n\t\tassert x > 0\n");
}

// ── Acceptance: pro and from-var properties ───────────────────────────────────

test "parse: pro declaration no body" {
    // ProDecl → ModList kw_pro id ReturnAnnotOpt … eol
    try expectAccepts("class Foo\n\tpro age as int\n");
}

test "parse: pro from var" {
    // ProDecl → ModList kw_pro id kw_from kw_var ReturnAnnotOpt eol
    try expectAccepts("class Foo\n\tpro age from var\n");
}

test "parse: pro with full get/set body" {
    // ProDecl → … eol PropBodyOpt(indent PropBodyListNE dedent)
    try expectAccepts("class Foo\n\tpro age as int\n\t\tget\n\t\t\treturn _age\n\t\tset\n\t\t\t_age = value\n");
}

test "parse: get from var" {
    try expectAccepts("class Foo\n\tget x from var as int\n");
}

test "parse: set from named var" {
    try expectAccepts("class Foo\n\tset age from _age\n");
}

// ── Acceptance: contract sub-blocks ───────────────────────────────────────────

test "parse: method with require and body clauses" {
    // ContractBlock → indent ContractClauseListNE dedent
    try expectAccepts("class Foo\n\tdef square(x as int) as int\n\t\trequire\n\t\t\tassert x > 0\n\t\tbody\n\t\t\treturn x\n");
}

// ── Acceptance: new statements ────────────────────────────────────────────────

test "parse: post while (do-while form)" {
    // StmtPostWhile → kw_post kw_while Expr eol Block
    try expectAccepts("class Foo\n\tdef run\n\t\tpost while x > 0\n\t\t\tx = 0\n");
}

test "parse: expect statement" {
    // StmtExpect → kw_expect TypeRef comma Expr eol
    try expectAccepts("class Foo\n\tdef run\n\t\texpect Exception, foo()\n");
}

test "parse: lock statement" {
    // StmtLock → kw_lock Expr eol Block
    try expectAccepts("class Foo\n\tdef run\n\t\tlock mutex\n\t\t\tpass\n");
}

test "parse: inline branch-on" {
    // BranchOnClause inline: kw_on ExprListNE comma Stmt
    try expectAccepts("class Foo\n\tdef run\n\t\tbranch x\n\t\t\ton 1, pass\n\t\t\telse, pass\n");
}

// ── Acceptance: expression extensions ────────────────────────────────────────

test "parse: self-member access" {
    // Atom → dot id
    try expectAccepts("class Foo\n\tdef run\n\t\tx = .value\n");
}

test "parse: self-method call" {
    // Atom → dot open_call ArgList rparen
    try expectAccepts("class Foo\n\tdef run\n\t\t.doIt(42)\n");
}

test "parse: to! non-nil assertion" {
    // Expr9 → Expr9 kw_to bang
    try expectAccepts("class Foo\n\tdef run\n\t\tx = foo() to!\n");
}

test "parse: all comprehension" {
    // AllAnyExpr → kw_all kw_for ForVarList kw_in Expr kw_get Expr
    try expectAccepts("class Foo\n\tdef run\n\t\tx = all for s in items get s > 0\n");
}

test "parse: any comprehension" {
    try expectAccepts("class Foo\n\tdef run\n\t\tx = any for s in items get s > 0\n");
}

// ── Rejection cases ────────────────────────────────────────────────────────────

// ── Acceptance: extended enum (sum types with payloads) ───────────────────────

test "parse: enum with payload members" {
    // EnumMember → open_call ParamList rparen eol
    try expectAccepts("enum Shape\n\tcircle(radius as float)\n\trect(w as float, h as float)\n\tpoint\n");
}

test "parse: enum mixing plain and payload members" {
    try expectAccepts("enum Result\n\tok(value as int)\n\terr(msg as String)\n\tempty\n");
}

// ── Acceptance: aspect declarations ───────────────────────────────────────────

test "parse: aspect with before clause" {
    // AspectBodyItem → kw_on id eol Block
    try expectAccepts("aspect Logging\n\ton before\n\t\tpass\n");
}

test "parse: aspect with after clause binding result" {
    // AspectBodyItem → kw_on id lparen id rparen eol Block
    try expectAccepts("aspect Logging\n\ton after(result)\n\t\tpass\n");
}

test "parse: aspect with around clause" {
    try expectAccepts("aspect Timing\n\ton around\n\t\tresult = proceed()\n\t\treturn result\n");
}

test "parse: aspect with error clause binding error" {
    try expectAccepts("aspect Safety\n\ton error(e)\n\t\tpass\n");
}

test "parse: aspect with all four advice clauses" {
    try expectAccepts(
        "aspect Full\n" ++
        "\ton before\n\t\tpass\n" ++
        "\ton after(result)\n\t\tpass\n" ++
        "\ton around\n\t\tresult = proceed()\n\t\treturn result\n" ++
        "\ton error(e)\n\t\tpass\n"
    );
}

test "parse: aspect defined inside a class" {
    // MemberDecl → AspectDecl — private/scoped aspect
    try expectAccepts("class Repo\n\taspect Audit\n\t\ton before\n\t\t\tpass\n");
}

// ── Acceptance: weaves clause ─────────────────────────────────────────────────

test "parse: method with weaves clause" {
    // MethodDecl → ... WeavesOpt ...
    try expectAccepts("class Foo\n\tdef save(data as String) weaves Logging\n");
}

test "parse: method with weaves clause and body" {
    try expectAccepts("class Foo\n\tdef save(data as String) weaves Logging\n\t\tpass\n");
}

test "parse: method weaves multiple aspects" {
    try expectAccepts("class Foo\n\tdef run weaves Logging, Timing\n\t\tpass\n");
}

test "parse: class with weaves clause" {
    // ClassDecl → ... WeavesOpt ...
    try expectAccepts("class Repository weaves Logging\n\tdef save\n");
}

test "parse: project-level weave to all def" {
    // WeaveDecl → kw_weaves TypeRef kw_to kw_all kw_def Atom eol
    try expectAccepts("weaves Logging to all def 'save*'\n");
}

test "parse: project-level weave to all class" {
    try expectAccepts("weaves Timing to all class '*Repository'\n");
}

test "parse: project-level weave to all public def" {
    try expectAccepts("weaves Auditing to all public def '*'\n");
}

// ── Acceptance: error unions ───────────────────────────────────────────────────

test "parse: error union type !T in parameter" {
    // TypeRef → bang TypeRef
    try expectAccepts("class Foo\n\tdef run(x as !int)\n\t\tpass\n");
}

test "parse: error union type !T as return type" {
    try expectAccepts("class Foo\n\tdef run as !String\n\t\treturn 'ok'\n");
}

test "parse: orelse operator" {
    // Expr → Expr kw_orelse Expr2
    try expectAccepts("class Foo\n\tdef run\n\t\tx = foo() orelse 0\n");
}

test "parse: catch operator without binding" {
    // Expr → Expr kw_catch Expr2
    try expectAccepts("class Foo\n\tdef run\n\t\tx = tryRead() catch 'default'\n");
}

test "parse: catch operator with binding" {
    // Expr → Expr kw_catch vertical_bar id vertical_bar Expr2
    try expectAccepts("class Foo\n\tdef run\n\t\tx = tryRead() catch |e| logError(e)\n");
}

test "parse: chained orelse then catch" {
    try expectAccepts("class Foo\n\tdef run\n\t\tx = getVal() orelse fallback() catch |e| 0\n");
}

// ── Acceptance: defer / errdefer ───────────────────────────────────────────────

test "parse: defer simple statement" {
    // StmtDefer → kw_defer Stmt
    try expectAccepts("class Foo\n\tdef run\n\t\tdefer cleanup()\n");
}

test "parse: errdefer simple statement" {
    // StmtDefer → kw_errdefer Stmt
    try expectAccepts("class Foo\n\tdef run\n\t\terrdefer rollback()\n");
}

test "parse: defer followed by other statements" {
    try expectAccepts("class Foo\n\tdef run\n\t\tdefer close(file)\n\t\tx = readAll(file)\n");
}

// ── Acceptance: old expression (contract) ─────────────────────────────────────

test "parse: old expression in ensure clause" {
    // Expr8 → kw_old Expr9
    try expectAccepts("class Foo\n\tdef push(x as int)\n\t\tensure\n\t\t\tcount == old count + 1\n");
}

// ── Rejection cases ────────────────────────────────────────────────────────────

test "parse: error position is past the valid prefix" {
    // Class + method header parses fine; `if` without a condition fails when
    // `eol` appears where an expression is required.
    const tokens = try Tokenizer.tokenize("class Foo\n\tdef run\n\t\tif\n", testing.allocator);
    defer testing.allocator.free(tokens);
    var result = try parse(tokens, testing.allocator);
    defer result.deinit();
    try testing.expect(!result.isOk());
    // Must have advanced past position 0 (the start of the class)
    try testing.expect(result.err.error_pos > 0);
}
