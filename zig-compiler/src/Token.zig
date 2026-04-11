//! Token kinds and source-annotated token structs for the Zebra tokenizer.
//!
//! ## Two-layer design
//!
//! The Earley parser library requires a comptime enum as its Token type.
//! `TokenKind` is that enum.  `Token` is a richer struct that pairs a kind
//! with source-location metadata (file, line, column, and a slice of the
//! original source text).
//!
//! The tokenizer produces `[]Token`.  Before handing the input to the
//! Earley parser, extract the kind array:
//!
//! ```zig
//! const kinds = try Token.kindsOf(tokens, alloc);
//! defer alloc.free(kinds);
//! var result = try parser.parseResult(kinds);
//! ```

// ── TokenKind ─────────────────────────────────────────────────────────────────

/// Every distinct token kind the Zebra tokenizer can produce.
///
/// Order within each group is alphabetical; the grouping mirrors the
/// Zebra tokenizer source.  Keywords appear as their own kinds so that the
/// Earley grammar can reference them directly — no post-processing needed.
pub const TokenKind = enum {

    // ── Structure tokens ───────────────────────────────────────────────────

    /// Increase in indentation (one level).
    indent,
    /// Decrease in indentation (one level per emitted DEDENT).
    dedent,
    /// Newline / end of logical line.
    eol,
    /// End of file.
    eof,

    // ── Identifiers ────────────────────────────────────────────────────────

    /// A plain identifier: `[A-Za-z_][A-Za-z0-9_]*`
    id,
    /// An attribute-style identifier: `@[A-Za-z_][A-Za-z0-9_]*`
    at_id,

    // ── Numeric literals ───────────────────────────────────────────────────

    /// Decimal integer: `42`, `1_000_000`, etc.
    integer_lit,
    /// Explicitly-sized integer: `42_u8`, `255_i16`, etc.
    integer_lit_explicit,
    /// Hex literal: `0xFF`
    hex_lit,
    /// Hex unsigned: `0xFF_u32`
    hex_lit_unsign,
    /// Hex sized: `0xFF_8`
    hex_lit_explicit,
    /// Float with decimal point: `3.14`, `1.0_f32`
    float_lit,
    /// Float without decimal: `1_f64`
    float_lit_exp,
    /// Fractional: `3.14` (not typed float, defaults to float64)
    fractional_lit,
    /// Decimal (high-precision): `3.14_d`
    decimal_lit,
    /// Number (default number type): `3.14_n`
    number_lit,
    /// Sized int type name: `int32`, `int64`, `int128`
    int_size,
    /// Sized uint type name: `uint8`, `uint64`
    uint_size,
    /// Sized float type name: `float32`, `float64`
    float_size,

    // ── Character literals ─────────────────────────────────────────────────

    /// Single-quoted char: `c'x'`
    char_lit_single,
    /// Double-quoted char: `c"x"`
    char_lit_double,

    // ── String literals ────────────────────────────────────────────────────

    /// Plain single-quoted string: `'hello'`
    string_single,
    /// Plain double-quoted string: `"hello"`
    string_double,
    /// Non-substituted single-quoted: `ns'hello'`
    string_nosub_single,
    /// Non-substituted double-quoted: `ns"hello"`
    string_nosub_double,
    /// Raw (no-escape) single-quoted: `r'hello'`
    string_raw_single,
    /// Raw double-quoted: `r"hello"`
    string_raw_double,
    /// Start of interpolated single-quoted string: `'hello ${
    string_start_single,
    /// Literal part inside interpolated string
    string_part_single,
    /// End of interpolated single-quoted string
    string_stop_single,
    /// Start of interpolated double-quoted string
    string_start_double,
    string_part_double,
    string_stop_double,
    /// Format spec inside interpolation: `:06.2f`
    string_part_format,
    /// `}` that closes a `${...}` interpolation expression
    rcurly_special,
    /// Backend (Zig) literal single-quoted: `zig'...'`
    zig_single,
    /// Backend (Zig) literal double-quoted: `zig"..."`
    zig_double,
    /// Doc-string start: triple-quote on its own line
    doc_string_start,
    /// Doc-string single line: `"""..."""`
    doc_string_line,

    // ── Operators and punctuation ──────────────────────────────────────────

    dot,           // .
    dotdot,        // ..
    colon,         // :
    semi,          // ;
    comma,         // ,
    lparen,        // (
    rparen,        // )
    lbracket,      // [
    rbracket,      // ]
    lcurly,        // {
    rcurly,        // }
    at_lbracket,   // @[  (array literal open)

    plus,          // +
    plusplus,      // ++
    minus,         // -
    minusminus,    // --
    arrow,         // ->
    star,          // *
    starstar,      // **
    slash,         // /
    slashslash,    // //
    percent,       // %
    percentpercent,// %%
    ampersand,     // &
    vertical_bar,  // |
    caret,         // ^
    tilde,         // ~
    question,      // ?
    bang,          // !
    double_lt,     // <<
    double_gt,     // >>

    assign,        // =
    eq,            // ==
    ne,            // <>
    lt,            // <
    gt,            // >
    le,            // <=
    ge,            // >=

    plus_equals,          // +=
    minus_equals,         // -=
    star_equals,          // *=
    slash_equals,         // /=
    slashslash_equals,    // //=
    percent_equals,       // %=
    starstar_equals,      // **=
    ampersand_equals,     // &=
    vertical_bar_equals,  // |=
    caret_equals,         // ^=
    double_lt_equals,     // <<=
    double_gt_equals,     // >>=
    question_equals,      // ?=
    bang_equals,          // !=

    /// `to?` — cast-or-nil operator (tokenized as a single token)
    toq,

    /// `identifier(` — identifier immediately followed by `(`, no space.
    /// Signals a call vs. a reference.
    open_call,

    // ── Keywords ───────────────────────────────────────────────────────────
    //
    // Grouped by category, matching KeywordSpecs.rawSpecs.

    // Module / namespace
    kw_use,
    kw_exposing,
    kw_namespace,

    // Type declarations
    kw_class,
    kw_interface,
    kw_mixin,
    kw_struct,
    kw_enum,
    kw_extend,

    // Member declarations
    kw_def,
    kw_sig,
    kw_get,
    kw_set,
    kw_pro,
    kw_var,
    kw_const,
    kw_cue,
    kw_test,

    // Declaration keywords
    kw_implements,
    kw_adds,
    kw_is,
    kw_as,
    kw_from,
    kw_has,
    kw_body,
    kw_shared,
    kw_invariant,
    kw_where,

    // Modifiers
    kw_abstract,
    kw_extern,
    kw_internal,
    kw_public,
    kw_private,
    kw_protected,
    kw_readonly,

    // Built-in types
    kw_bool,
    kw_char,
    kw_int,
    kw_uint,
    kw_float,
    kw_same,

    // Contracts
    kw_require,
    kw_ensure,
    kw_old,
    kw_implies,

    // Statements
    kw_assert,
    kw_branch,
    kw_on,
    kw_expect,
    kw_if,
    kw_else,
    kw_lock,
    kw_while,
    kw_post,
    kw_for,
    kw_break,
    kw_continue,
    kw_pass,
    kw_print,
    kw_stop,
    kw_trace,
    kw_return,
    kw_yield,
    kw_defer,     // defer stmt — run on scope exit
    kw_errdefer,  // errdefer stmt — run only on error exit

    // Expressions
    kw_this,
    kw_to,
    kw_and,
    kw_or,
    kw_not,
    kw_any,
    kw_all,
    kw_in,
    kw_orelse,    // expr orelse fallback — optional/error unwrap with fallback
    kw_catch,     // expr catch fallback — error union fallback (with optional binding)
    kw_true,
    kw_false,
    kw_nil,

    // Argument modifiers
    kw_vari,

    // Aspect-oriented programming
    kw_aspect,    // aspect declaration
    kw_weaves,    // weaves clause on class/method; project-level weave declaration

    // Error handling (error union path)
    kw_error,     // used in `on error(e)` advice clauses and error-union types

    // Closures / contextual self / struct update
    kw_capture,   // capture block — explicit closure state declaration
    kw_with,      // with obj — contextual self block
    kw_except,    // original except field = val — struct update expression

    // Discriminated union types
    kw_union,     // union type declaration

    // Scoped arena allocation
    kw_arena,     // arena block — creates a sub-arena that frees all allocations on exit

    // Guard statements
    kw_guard,     // guard cond else stmt/block — early-exit pattern

    // Error propagation
    kw_raise,     // raise an error (with optional details)
    kw_throws,    // method annotation — method may propagate errors
    kw_try,       // propagate error upward (expression) or try/catch block (statement)

};

// ── Keyword table ─────────────────────────────────────────────────────────────

/// Maps keyword strings to their `TokenKind`.  Used by the tokenizer to
/// distinguish identifiers from keywords in O(1) via hash lookup.
pub const keyword_map = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "use",         .kw_use },
    .{ "exposing",    .kw_exposing },
    .{ "namespace",   .kw_namespace },
    .{ "class",       .kw_class },
    .{ "interface",   .kw_interface },
    .{ "mixin",       .kw_mixin },
    .{ "struct",      .kw_struct },
    .{ "enum",        .kw_enum },
    .{ "extend",      .kw_extend },
    .{ "def",         .kw_def },
    .{ "sig",         .kw_sig },
    .{ "get",         .kw_get },
    .{ "set",         .kw_set },
    .{ "pro",         .kw_pro },
    .{ "var",         .kw_var },
    .{ "const",       .kw_const },
    .{ "cue",         .kw_cue },
    .{ "test",        .kw_test },
    .{ "implements",  .kw_implements },
    .{ "adds",        .kw_adds },
    .{ "is",          .kw_is },
    .{ "as",          .kw_as },
    .{ "from",        .kw_from },
    .{ "has",         .kw_has },
    .{ "body",        .kw_body },
    .{ "shared",      .kw_shared },
    .{ "invariant",   .kw_invariant },
    .{ "abstract",    .kw_abstract },
    .{ "extern",      .kw_extern },
    .{ "internal",    .kw_internal },
    .{ "public",      .kw_public },
    .{ "private",     .kw_private },
    .{ "protected",   .kw_protected },
    .{ "readonly",    .kw_readonly },
    .{ "bool",        .kw_bool },
    .{ "char",        .kw_char },
    .{ "int",         .kw_int },
    .{ "uint",        .kw_uint },
    .{ "float",       .kw_float },
    .{ "same",        .kw_same },
    .{ "require",     .kw_require },
    .{ "ensure",      .kw_ensure },
    .{ "old",         .kw_old },
    .{ "implies",     .kw_implies },
    .{ "assert",      .kw_assert },
    .{ "branch",      .kw_branch },
    .{ "on",          .kw_on },
    .{ "expect",      .kw_expect },
    .{ "if",          .kw_if },
    .{ "else",        .kw_else },
    .{ "lock",        .kw_lock },
    .{ "while",       .kw_while },
    .{ "post",        .kw_post },
    .{ "for",         .kw_for },
    .{ "break",       .kw_break },
    .{ "continue",    .kw_continue },
    .{ "pass",        .kw_pass },
    .{ "print",       .kw_print },
    .{ "stop",        .kw_stop },
    .{ "trace",       .kw_trace },
    .{ "return",      .kw_return },
    .{ "yield",       .kw_yield },
    .{ "defer",       .kw_defer },
    .{ "errdefer",    .kw_errdefer },
    .{ "this",        .kw_this },
    .{ "to",          .kw_to },
    .{ "and",         .kw_and },
    .{ "or",          .kw_or },
    .{ "not",         .kw_not },
    .{ "any",         .kw_any },
    .{ "all",         .kw_all },
    .{ "in",          .kw_in },
    .{ "orelse",      .kw_orelse },
    .{ "catch",       .kw_catch },
    .{ "true",        .kw_true },
    .{ "false",       .kw_false },
    .{ "nil",         .kw_nil },
    .{ "vari",        .kw_vari },
    .{ "aspect",      .kw_aspect },
    .{ "weaves",      .kw_weaves },
    .{ "error",       .kw_error },
    .{ "capture",     .kw_capture },
    .{ "with",        .kw_with },
    .{ "except",      .kw_except },
    .{ "union",       .kw_union  },
    .{ "guard",       .kw_guard  },
    .{ "raise",       .kw_raise  },
    .{ "throws",      .kw_throws },
    .{ "try",         .kw_try    },
    .{ "where",       .kw_where  },
    .{ "arena",       .kw_arena  },
});

// ── Token (source-annotated) ──────────────────────────────────────────────────

/// A token with source-location metadata.
///
/// The `text` slice points into the original source string; it is valid for
/// the lifetime of the source buffer.  The `Token` struct itself is 24 bytes
/// on 64-bit targets.
pub const Token = struct {
    kind:  TokenKind,
    /// The exact text of the token in the source file.
    text:  []const u8,
    /// 1-based line number.
    line:  u32,
    /// 1-based column number of the first character.
    col:   u16,

    /// Convenience: is this token a keyword?
    pub fn isKeyword(self: Token) bool {
        return @intFromEnum(self.kind) >= @intFromEnum(TokenKind.kw_use);
    }

    /// Convenience: is this token an identifier or keyword?
    pub fn isName(self: Token) bool {
        return self.kind == .id or self.isKeyword();
    }
};

// ── Kind extraction ───────────────────────────────────────────────────────────

/// Extract just the `TokenKind` values from a token slice into a new allocation.
///
/// The result is sized for the Earley parser: `parser.parseResult(kinds)`.
/// Caller owns the returned slice.
pub fn kindsOf(tokens: []const Token, alloc: @import("std").mem.Allocator) ![]const TokenKind {
    const out = try alloc.alloc(TokenKind, tokens.len);
    for (tokens, 0..) |tok, i| out[i] = tok.kind;
    return out;
}

// ── Imports ───────────────────────────────────────────────────────────────────

const std = @import("std");
