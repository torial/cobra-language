//! Zebra source tokenizer.
//!
//! Converts a UTF-8 source string into a flat slice of `Token` values.
//!
//! ## Indentation
//!
//! Zebra is indentation-sensitive.  The tokenizer inserts synthetic
//! `indent` / `dedent` tokens when the indentation level changes and
//! emits `eol` at the end of every significant line.  Blank lines
//! (containing only whitespace) are silently consumed; comment-only
//! lines are also consumed.  Truly empty lines (bare `\n`) emit `eol`.
//!
//! Tabs and spaces may not be mixed on the same line.  Spaces must be
//! in multiples of four.
//!
//! ## String interpolation
//!
//! Strings containing `${expr}` interpolations are split into
//! `string_start_*` / `string_part_*` / `string_stop_*` token triples.
//! The inner expression tokens are scanned normally; the `}` that closes
//! the expression is emitted as `rcurly_special` (not `rcurly`).
//!
//! ## Usage
//!
//! ```zig
//! const toks = try tokenize(source, allocator);
//! defer allocator.free(toks);
//! ```

const std   = @import("std");
const tk    = @import("Token.zig");

pub const Token     = tk.Token;
pub const TokenKind = tk.TokenKind;

pub const TokenizeError = error{
    MixedIndentation,
    SpaceIndentNotMultipleOfFour,
    UnterminatedString,
    UnterminatedCharLiteral,
    UnterminatedBlockComment,
    UnterminatedInterpolation,
    UnexpectedCharacter,
    OutOfMemory,
};

// ── Public API ────────────────────────────────────────────────────────────────

/// Tokenize Zebra source text.
///
/// Returns a heap-allocated slice.  The `text` fields in every token are
/// slices into `src`; `src` must remain valid for the lifetime of the
/// returned slice.  Caller owns the result and must free with
/// `allocator.free(tokens)`.
pub fn tokenize(src: []const u8, allocator: std.mem.Allocator) TokenizeError![]Token {
    var t = Tokenizer{
        .src   = src,
        .alloc = allocator,
    };
    errdefer t.out.deinit(allocator);
    try t.run();
    return t.out.toOwnedSlice(allocator);
}

// ── Internal tokenizer ────────────────────────────────────────────────────────

const Tokenizer = struct {
    src:        []const u8,
    pos:        usize = 0,
    line:       u32   = 1,
    line_start: usize = 0,  // byte offset of start of current line

    alloc: std.mem.Allocator,
    out:   std.ArrayListUnmanaged(Token) = .empty,

    /// Current indentation depth (number of INDENT tokens emitted without
    /// matching DEDENT).
    indent_depth: u32 = 0,

    /// Depth of open `/#` block comments (supports nesting).
    block_depth: u32 = 0,

    /// Depth of open parentheses `(` without matching `)`.
    /// When > 0, indentation checking is suppressed so that multi-line
    /// argument lists (e.g. `cue init` signatures) don't trigger
    /// SpaceIndentNotMultipleOfFour errors.
    paren_depth: u32 = 0,

    // ── Low-level helpers ─────────────────────────────────────────────────

    fn col(self: *const Tokenizer) u16 {
        return @intCast(self.pos - self.line_start + 1);
    }

    fn peek(self: *const Tokenizer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn peek1(self: *const Tokenizer) u8 {
        return if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
    }

    fn peekAt(self: *const Tokenizer, offset: usize) u8 {
        return if (self.pos + offset < self.src.len) self.src[self.pos + offset] else 0;
    }

    /// Advance past `\n`, updating line/line_start.
    fn advanceNewline(self: *Tokenizer) void {
        std.debug.assert(self.src[self.pos] == '\n');
        self.pos       += 1;
        self.line      += 1;
        self.line_start = self.pos;
    }

    fn emit(self: *Tokenizer, kind: TokenKind, text: []const u8, ln: u32, cl: u16) !void {
        try self.out.append(self.alloc, .{ .kind = kind, .text = text, .line = ln, .col = cl });
    }

    // ── Main loop ─────────────────────────────────────────────────────────

    fn run(self: *Tokenizer) !void {
        var at_line_start = true;

        while (self.pos < self.src.len) {
            if (at_line_start) {
                at_line_start = false;
                switch (self.classifyLine()) {
                    .empty => {
                        // Bare newline — emit EOL and continue.
                        // Inside balanced parens, EOL is not significant.
                        const ln = self.line;
                        const cl = self.col();
                        self.advanceNewline();
                        if (self.paren_depth == 0) try self.emit(.eol, "\n", ln, cl);
                        at_line_start = true;
                        continue;
                    },
                    .whitespace_only => {
                        // Skip the whole line silently.
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
                        if (self.pos < self.src.len) self.advanceNewline();
                        at_line_start = true;
                        continue;
                    },
                    .comment_only => {
                        // Skip the whole line silently.
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
                        if (self.pos < self.src.len) self.advanceNewline();
                        at_line_start = true;
                        continue;
                    },
                    .has_content => {
                        try self.processIndentation();
                    },
                }
            }

            const c = self.peek();

            // Mid-line whitespace
            if (c == ' ' or c == '\t') { self.pos += 1; continue; }

            // End of line
            if (c == '\n') {
                const ln = self.line; const cl = self.col();
                self.advanceNewline();
                // Inside balanced parens, newlines are not significant.
                if (self.paren_depth == 0) try self.emit(.eol, "\n", ln, cl);
                at_line_start = true;
                continue;
            }

            // Line comment  #...
            if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
                continue;
            }

            // Block comment  /# ... #/
            if (c == '/' and self.peek1() == '#') {
                try self.scanBlockComment();
                continue;
            }

            try self.scanToken();
        }

        // End of file: if the last line had content but no trailing newline,
        // emit a synthetic EOL before the DEDENTs.
        if (!at_line_start) {
            try self.emit(.eol, "", self.line, self.col());
        }

        // Close any open indentation levels.
        const eof_col = self.col();
        const eof_ln  = self.line;
        while (self.indent_depth > 0) {
            try self.emit(.dedent, "", eof_ln, eof_col);
            self.indent_depth -= 1;
        }
        try self.emit(.eof, "", eof_ln, eof_col);
    }

    const LineKind = enum { empty, whitespace_only, comment_only, has_content };

    /// Peek at the current line to decide how to handle it without advancing.
    fn classifyLine(self: *const Tokenizer) LineKind {
        var i = self.pos;
        // Truly empty line
        if (i >= self.src.len or self.src[i] == '\n') return .empty;
        // Scan whitespace
        var has_ws = false;
        while (i < self.src.len and (self.src[i] == ' ' or self.src[i] == '\t')) { has_ws = true; i += 1; }
        if (i >= self.src.len or self.src[i] == '\n') {
            return if (has_ws) .whitespace_only else .empty;
        }
        if (self.src[i] == '#') return .comment_only;
        return .has_content;
    }

    /// Measure the leading whitespace on the current line and emit INDENT /
    /// DEDENT tokens as needed.  Advances `self.pos` past the whitespace.
    fn processIndentation(self: *Tokenizer) !void {
        const ln: u32 = self.line;
        var tabs:   u32 = 0;
        var spaces: u32 = 0;

        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '\t' => { tabs   += 1; self.pos += 1; },
                ' '  => { spaces += 1; self.pos += 1; },
                else => break,
            }
        }

        if (tabs > 0 and spaces > 0) return error.MixedIndentation;

        // Inside balanced parentheses, indentation is not significant —
        // suppress INDENT/DEDENT emission and return after consuming whitespace.
        if (self.paren_depth > 0) return;

        const level: u32 = if (spaces > 0) blk: {
            if (spaces % 4 != 0) return error.SpaceIndentNotMultipleOfFour;
            break :blk spaces / 4;
        } else tabs;

        while (level > self.indent_depth) {
            try self.emit(.indent, "", ln, 1);
            self.indent_depth += 1;
        }
        while (level < self.indent_depth) {
            try self.emit(.dedent, "", ln, 1);
            self.indent_depth -= 1;
        }
    }

    // ── Block comment ─────────────────────────────────────────────────────

    fn scanBlockComment(self: *Tokenizer) !void {
        self.pos       += 2;  // consume /#
        self.block_depth += 1;

        while (self.pos < self.src.len and self.block_depth > 0) {
            if (self.src[self.pos] == '/' and self.pos + 1 < self.src.len and
                self.src[self.pos + 1] == '#')
            {
                self.pos         += 2;
                self.block_depth += 1;
            } else if (self.src[self.pos] == '#' and self.pos + 1 < self.src.len and
                       self.src[self.pos + 1] == '/')
            {
                self.pos         += 2;
                self.block_depth -= 1;
            } else if (self.src[self.pos] == '\n') {
                self.advanceNewline();
            } else {
                self.pos += 1;
            }
        }
        if (self.block_depth > 0) return error.UnterminatedBlockComment;
    }

    // ── Token dispatch ────────────────────────────────────────────────────

    fn scanToken(self: *Tokenizer) TokenizeError!void {
        const c  = self.peek();
        const ln = self.line;
        const cl = self.col();

        // Numeric literals
        if (std.ascii.isDigit(c)) return self.scanNumericLiteral(ln, cl);

        // Hex literal starting with 0x
        if (c == '0' and self.peek1() == 'x') return self.scanNumericLiteral(ln, cl);

        // @ — at_id or @[
        if (c == '@') return self.scanAt(ln, cl);

        // Identifiers, keywords, and string prefixes (c/r/ns/sharp)
        if (std.ascii.isAlphabetic(c) or c == '_') return self.scanIdentOrKeyword(ln, cl);

        // Character literals and string literals.
        // 'x' or '\n' (exactly one char/escape + closing quote) → char literal.
        // Multi-char single-quoted content → string literal (backwards compat).
        if (c == '\'') return self.scanSingleQuote(ln, cl);
        if (c == '"')  return self.scanString('"', ln, cl);

        // Operators and punctuation
        return self.scanOperator(ln, cl);
    }

    // ── @ prefix ──────────────────────────────────────────────────────────

    fn scanAt(self: *Tokenizer, ln: u32, cl: u16) !void {
        const c1 = self.peek1();
        if (c1 == '[') {
            self.pos += 2;
            try self.emit(.at_lbracket, "@[", ln, cl);
            return;
        }
        if (std.ascii.isAlphabetic(c1) or c1 == '_') {
            self.pos += 1;  // consume @
            const id_start = self.pos;
            while (self.pos < self.src.len and isIdentContinue(self.src[self.pos])) : (self.pos += 1) {}
            const word = self.src[id_start..self.pos];
            // @keyword escape hatch: @body, @init, @class, etc.
            // If the word after @ is a reserved keyword, emit it as a plain identifier
            // so it can be used as a field name, variable name, or parameter name.
            if (tk.keyword_map.get(word) != null) {
                try self.emit(.id, word, ln, cl);
                return;
            }
            // Otherwise emit as at_id (e.g. @TypeName for future attributes).
            try self.emit(.at_id, self.src[id_start - 1 .. self.pos], ln, cl);
            return;
        }
        return error.UnexpectedCharacter;
    }

    // ── Identifiers, keywords, string prefixes ────────────────────────────

    fn scanIdentOrKeyword(self: *Tokenizer, ln: u32, cl: u16) !void {
        const start = self.pos;

        // Scan the full identifier characters first.
        while (self.pos < self.src.len and isIdentContinue(self.src[self.pos])) : (self.pos += 1) {}
        const word = self.src[start..self.pos];

        // ── String prefixes ───────────────────────────────────────────────

        // c'  c"  — char literals
        if (word.len == 1 and word[0] == 'c') {
            const q = self.peek();
            if (q == '\'' or q == '"') return self.scanCharLiteral(q, start, ln, cl);
        }

        // r'  r"  — raw strings (no escapes, no interpolation)
        if (word.len == 1 and word[0] == 'r') {
            const q = self.peek();
            if (q == '\'' or q == '"') {
                const kind: TokenKind = if (q == '\'') .string_raw_single else .string_raw_double;
                return self.scanSimpleString(q, start, kind, ln, cl);
            }
        }

        // ns'  ns"  — no-substitution strings
        if (word.len == 2 and word[0] == 'n' and word[1] == 's') {
            const q = self.peek();
            if (q == '\'' or q == '"') {
                const kind: TokenKind = if (q == '\'') .string_nosub_single else .string_nosub_double;
                return self.scanSimpleString(q, start, kind, ln, cl);
            }
        }

        // zig'  zig"  — backend (Zig) literals
        if (std.mem.eql(u8, word, "zig")) {
            const q = self.peek();
            if (q == '\'' or q == '"') {
                const kind: TokenKind = if (q == '\'') .zig_single else .zig_double;
                return self.scanSimpleString(q, start, kind, ln, cl);
            }
        }

        // ── Sized type names ──────────────────────────────────────────────

        if (std.mem.startsWith(u8, word, "int") and word.len > 3 and
            std.ascii.isDigit(word[3]))
        {
            try self.emit(.int_size, word, ln, cl);
            return;
        }
        if (std.mem.startsWith(u8, word, "uint") and word.len > 4 and
            std.ascii.isDigit(word[4]))
        {
            try self.emit(.uint_size, word, ln, cl);
            return;
        }
        if (std.mem.startsWith(u8, word, "float") and word.len > 5 and
            std.ascii.isDigit(word[5]))
        {
            try self.emit(.float_size, word, ln, cl);
            return;
        }

        // ── `to?` operator ────────────────────────────────────────────────

        if (std.mem.eql(u8, word, "to") and self.peek() == '?') {
            self.pos += 1;  // consume ?
            try self.emit(.toq, self.src[start..self.pos], ln, cl);
            return;
        }

        // ── Keyword or identifier ─────────────────────────────────────────

        const kind: TokenKind = tk.keyword_map.get(word) orelse .id;

        // open_call — non-keyword identifier immediately followed by `(`
        if (kind == .id and self.peek() == '(') {
            self.pos += 1;  // consume the (
            self.paren_depth += 1;  // track depth for indentation suppression
            // text stores just the identifier name; the ( is implicit in the kind
            try self.emit(.open_call, word, ln, cl);
            return;
        }

        try self.emit(kind, word, ln, cl);
    }

    // ── Char literals  'x'  '\n'  (also legacy c'x' c"x") ───────────────────

    /// Dispatch a bare `'` — decide whether it opens a char literal or a string.
    /// Rule: if the content is exactly one character (or one `\X` escape) followed
    /// by a closing `'`, emit as char_lit.  Otherwise fall through to scanString.
    fn scanSingleQuote(self: *Tokenizer, ln: u32, cl: u16) TokenizeError!void {
        // self.pos points to the opening '
        const p1 = self.peekAt(1);  // first content char (or closing ')
        if (p1 == '\\') {
            // Escape sequence '\X': positions are ' \ X '
            // p3 (offset 3) should be the closing quote for a valid 1-char escape.
            if (self.peekAt(3) == '\'') return self.scanCharLiteral('\'', self.pos, ln, cl);
        } else if (p1 != '\'' and p1 != 0 and p1 != '\n') {
            // Single plain character: positions are ' X '
            if (self.peekAt(2) == '\'') return self.scanCharLiteral('\'', self.pos, ln, cl);
        }
        // Multi-char content, empty '', or unterminated — fall through to string scanner.
        return self.scanString('\'', ln, cl);
    }

    fn scanCharLiteral(self: *Tokenizer, q: u8, start: usize, ln: u32, cl: u16) !void {
        self.pos += 1;  // consume quote
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\') { self.pos += 2; continue; }
            if (c == q   ) { self.pos += 1; break; }
            if (c == '\n') return error.UnterminatedCharLiteral;
            self.pos += 1;
        }
        const kind: TokenKind = if (q == '\'') .char_lit_single else .char_lit_double;
        try self.emit(kind, self.src[start..self.pos], ln, cl);
    }

    // ── Simple (non-interpolated) strings ─────────────────────────────────

    /// Scan a string that cannot contain `${...}` interpolation:
    /// raw (r'...'), no-sub (ns'...'), and backend (sharp'...) strings.
    /// `start` is the position of the first byte of the prefix (before the quote).
    fn scanSimpleString(
        self:  *Tokenizer,
        q:     u8,
        start: usize,
        kind:  TokenKind,
        ln:    u32,
        cl:    u16,
    ) !void {
        self.pos += 1;  // consume opening quote
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\') { self.pos += 2; continue; }
            if (c == q   ) { self.pos += 1; break; }
            if (c == '\n') return error.UnterminatedString;
            self.pos += 1;
        }
        try self.emit(kind, self.src[start..self.pos], ln, cl);
    }

    // ── Interpolated (and plain) strings ──────────────────────────────────

    /// Scan a `'...'` or `"..."` string, emitting either a single
    /// `string_single` / `string_double` token (if no interpolation) or a
    /// sequence of `string_start` / `string_part` / `string_stop` tokens.
    fn scanString(self: *Tokenizer, q: u8, ln: u32, cl: u16) TokenizeError!void {
        // Check for triple-quote doc string  """
        if (q == '"' and self.peek1() == '"' and self.peekAt(2) == '"') {
            return self.scanDocString(ln, cl);
        }

        const open_pos = self.pos;  // position of the opening quote
        self.pos += 1;              // consume opening quote

        var has_interp = false;
        var seg_start  = self.pos;
        var seg_ln     = self.line;

        while (self.pos < self.src.len) {
            const c = self.src[self.pos];

            if (c == '$' and self.peek1() == '{') {
                // Interpolation starts: `${`
                const seg_text = self.src[seg_start..self.pos];
                if (!has_interp) {
                    const kind: TokenKind = if (q == '\'') .string_start_single else .string_start_double;
                    // text = everything from the opening quote through the last char before ${
                    try self.emit(kind, self.src[open_pos..self.pos], ln, cl);
                    has_interp = true;
                } else {
                    const kind: TokenKind = if (q == '\'') .string_part_single else .string_part_double;
                    try self.emit(kind, seg_text, seg_ln, @intCast(seg_start - self.line_start + 1));
                }
                self.pos  += 2;  // consume ${ (two chars)
                try self.scanInterpExpr();
                seg_start  = self.pos;
                seg_ln     = self.line;
                continue;
            }

            if (c == q) {
                // End of string.
                const seg_text = self.src[seg_start..self.pos];
                self.pos += 1;  // consume closing quote
                if (!has_interp) {
                    const kind: TokenKind = if (q == '\'') .string_single else .string_double;
                    try self.emit(kind, self.src[open_pos..self.pos], ln, cl);
                } else {
                    const kind: TokenKind = if (q == '\'') .string_stop_single else .string_stop_double;
                    try self.emit(kind, seg_text, seg_ln, @intCast(seg_start - self.line_start + 1));
                }
                return;
            }

            if (c == '\n') return error.UnterminatedString;
            if (c == '\\') { self.pos += 2; continue; }
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    /// Scan tokens inside a `${...}` interpolation.  Called after consuming
    /// the `${`.  Emits `rcurly_special` for the closing `}`.
    fn scanInterpExpr(self: *Tokenizer) TokenizeError!void {
        var depth: u32 = 1;

        while (depth > 0) {
            if (self.pos >= self.src.len) return error.UnterminatedInterpolation;

            const c = self.src[self.pos];

            if (c == ' ' or c == '\t') { self.pos += 1; continue; }

            if (c == '{') {
                const ln = self.line; const cl = self.col();
                self.pos += 1;
                try self.emit(.lcurly, "{", ln, cl);
                depth += 1;
                continue;
            }

            if (c == '}') {
                const ln = self.line; const cl = self.col();
                self.pos += 1;
                depth -= 1;
                if (depth == 0) {
                    try self.emit(.rcurly_special, "}", ln, cl);
                } else {
                    try self.emit(.rcurly, "}", ln, cl);
                }
                continue;
            }

            // Handle format spec  :...} — e.g. `:06.2f`
            if (c == ':') {
                const spec_start = self.pos;
                const spec_ln    = self.line;
                const spec_cl    = self.col();
                self.pos += 1;
                while (self.pos < self.src.len and
                       self.src[self.pos] != '}' and
                       self.src[self.pos] != '\n') : (self.pos += 1) {}
                if (self.pos < self.src.len and self.src[self.pos] == '}') {
                    try self.emit(.string_part_format, self.src[spec_start..self.pos], spec_ln, spec_cl);
                    // Don't consume }; let the next iteration handle it.
                    continue;
                }
                // Not a format spec — reset and fall through to scanToken.
                self.pos = spec_start;
            }

            try self.scanToken();
        }
    }

    // ── Doc strings ───────────────────────────────────────────────────────

    /// Scan `"""..."""` (single-line or multiline).  Called when `"""` is detected.
    /// Always emits a single `doc_string_line` token whose text is the full
    /// `"""..."""` source slice so the AstBuilder/CodeGen can strip the delimiters.
    fn scanDocString(self: *Tokenizer, ln: u32, cl: u16) !void {
        const start = self.pos;
        self.pos += 3;  // consume opening """

        // Skip optional trailing whitespace on the opening line
        while (self.pos < self.src.len and
               (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) : (self.pos += 1) {}

        // Single-line: """content"""
        if (self.pos < self.src.len and self.src[self.pos] != '\n') {
            while (self.pos + 2 < self.src.len) {
                if (self.src[self.pos] == '"' and
                    self.src[self.pos + 1] == '"' and
                    self.src[self.pos + 2] == '"')
                {
                    self.pos += 3;
                    try self.emit(.doc_string_line, self.src[start..self.pos], ln, cl);
                    return;
                }
                self.pos += 1;
            }
            return error.UnterminatedString;
        }

        // Multiline: """ followed by newline — consume lines until closing """
        // The emitted token text is the full `"""\n...\n"""` slice.
        if (self.pos < self.src.len and self.src[self.pos] == '\n') {
            self.advanceNewline();
        }
        while (self.pos < self.src.len) {
            // Check for closing """ (may be indented)
            var p = self.pos;
            while (p < self.src.len and (self.src[p] == ' ' or self.src[p] == '\t')) : (p += 1) {}
            if (p + 2 < self.src.len and
                self.src[p] == '"' and self.src[p + 1] == '"' and self.src[p + 2] == '"')
            {
                self.pos = p + 3;
                try self.emit(.doc_string_line, self.src[start..self.pos], ln, cl);
                return;
            }
            // Consume this content line
            while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            if (self.pos < self.src.len) self.advanceNewline();
        }
        return error.UnterminatedString;
    }

    // ── Numeric literals ──────────────────────────────────────────────────

    fn scanNumericLiteral(self: *Tokenizer, ln: u32, cl: u16) !void {
        const start = self.pos;

        // Hex  0x...
        if (self.src[self.pos] == '0' and self.pos + 1 < self.src.len and
            self.src[self.pos + 1] == 'x')
        {
            self.pos += 2;
            while (self.pos < self.src.len and isHexDigit(self.src[self.pos])) : (self.pos += 1) {}
            // Optional suffix
            if (self.peek() == '_') {
                const suffix_start = self.pos;
                self.pos += 1;
                if (self.peek() == 'u') {
                    self.pos += 1;
                    while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
                    try self.emit(.hex_lit_unsign, self.src[start..self.pos], ln, cl);
                    return;
                }
                // Size suffix: _8 _16 _32 _64
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
                if (self.pos > suffix_start + 1) {
                    try self.emit(.hex_lit_explicit, self.src[start..self.pos], ln, cl);
                    return;
                }
                self.pos = suffix_start;  // no valid suffix — rewind
            }
            try self.emit(.hex_lit, self.src[start..self.pos], ln, cl);
            return;
        }

        // Decimal integer part (with optional _ separators)
        while (self.pos < self.src.len and
               (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}

        // Optional fractional part  .digits
        const has_dot = self.peek() == '.' and std.ascii.isDigit(self.peekAt(1));
        if (has_dot) {
            self.pos += 1;  // consume .
            while (self.pos < self.src.len and
                   (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
        }

        // Optional suffix
        const c = self.peek();
        const c1 = self.peek1();

        // _d  decimal
        if (c == '_' and c1 == 'd' and !isIdentContinue(self.peekAt(2))) {
            self.pos += 2;
            try self.emit(.decimal_lit, self.src[start..self.pos], ln, cl);
            return;
        }

        // _n  number
        if (c == '_' and c1 == 'n' and !isIdentContinue(self.peekAt(2))) {
            self.pos += 2;
            try self.emit(.number_lit, self.src[start..self.pos], ln, cl);
            return;
        }

        // _f  _f32  _f64  or bare f32/f64
        if ((c == '_' and c1 == 'f') or c == 'f') {
            if (c == '_') self.pos += 1;  // consume _
            self.pos += 1;               // consume f
            if ((self.peek() == '3' and self.peekAt(1) == '2') or
                (self.peek() == '6' and self.peekAt(1) == '4'))
            {
                self.pos += 2;
            }
            const kind: TokenKind = if (has_dot) .float_lit else .float_lit_exp;
            try self.emit(kind, self.src[start..self.pos], ln, cl);
            return;
        }

        // _i  _u  _i8  _u16  etc.  (explicitly-sized integer)
        if ((c == '_' and (c1 == 'i' or c1 == 'u')) or c == 'i' or c == 'u') {
            if (c == '_') self.pos += 1;  // consume _
            self.pos += 1;               // consume i / u
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            try self.emit(.integer_lit_explicit, self.src[start..self.pos], ln, cl);
            return;
        }

        // Plain number
        if (has_dot) {
            try self.emit(.fractional_lit, self.src[start..self.pos], ln, cl);
        } else {
            try self.emit(.integer_lit, self.src[start..self.pos], ln, cl);
        }
    }

    // ── Operators and punctuation ─────────────────────────────────────────

    fn scanOperator(self: *Tokenizer, ln: u32, cl: u16) !void {
        const c  = self.peek();
        const c1 = self.peek1();

        // Three-character compound operators
        if (self.pos + 2 < self.src.len) {
            const c2 = self.src[self.pos + 2];
            if (c == '/' and c1 == '/' and c2 == '=') { self.pos += 3; try self.emit(.slashslash_equals, "//=", ln, cl); return; }
            if (c == '*' and c1 == '*' and c2 == '=') { self.pos += 3; try self.emit(.starstar_equals,   "**=", ln, cl); return; }
            if (c == '<' and c1 == '<' and c2 == '=') { self.pos += 3; try self.emit(.double_lt_equals,  "<<=", ln, cl); return; }
            if (c == '>' and c1 == '>' and c2 == '=') { self.pos += 3; try self.emit(.double_gt_equals,  ">>=", ln, cl); return; }
        }

        // Two-character compound operators (longest-match)
        if (c == '+' and c1 == '+') { self.pos += 2; try self.emit(.plusplus,             "++", ln, cl); return; }
        if (c == '+' and c1 == '=') { self.pos += 2; try self.emit(.plus_equals,          "+=", ln, cl); return; }
        if (c == '-' and c1 == '>') { self.pos += 2; try self.emit(.arrow,                "->", ln, cl); return; }
        if (c == '-' and c1 == '-') { self.pos += 2; try self.emit(.minusminus,           "--", ln, cl); return; }
        if (c == '-' and c1 == '=') { self.pos += 2; try self.emit(.minus_equals,         "-=", ln, cl); return; }
        if (c == '*' and c1 == '*') { self.pos += 2; try self.emit(.starstar,             "**", ln, cl); return; }
        if (c == '*' and c1 == '=') { self.pos += 2; try self.emit(.star_equals,          "*=", ln, cl); return; }
        if (c == '/' and c1 == '/') { self.pos += 2; try self.emit(.slashslash,           "//", ln, cl); return; }
        if (c == '/' and c1 == '=') { self.pos += 2; try self.emit(.slash_equals,         "/=", ln, cl); return; }
        if (c == '%' and c1 == '%') { self.pos += 2; try self.emit(.percentpercent,       "%%", ln, cl); return; }
        if (c == '%' and c1 == '=') { self.pos += 2; try self.emit(.percent_equals,       "%=", ln, cl); return; }
        if (c == '=' and c1 == '=') { self.pos += 2; try self.emit(.eq,                  "==", ln, cl); return; }
        if (c == '<' and c1 == '>') { self.pos += 2; try self.emit(.ne,                  "<>", ln, cl); return; }
        if (c == '<' and c1 == '=') { self.pos += 2; try self.emit(.le,                  "<=", ln, cl); return; }
        if (c == '<' and c1 == '<') { self.pos += 2; try self.emit(.double_lt,           "<<", ln, cl); return; }
        if (c == '>' and c1 == '=') { self.pos += 2; try self.emit(.ge,                  ">=", ln, cl); return; }
        if (c == '>' and c1 == '>') { self.pos += 2; try self.emit(.double_gt,           ">>", ln, cl); return; }
        if (c == '&' and c1 == '=') { self.pos += 2; try self.emit(.ampersand_equals,    "&=", ln, cl); return; }
        if (c == '|' and c1 == '=') { self.pos += 2; try self.emit(.vertical_bar_equals, "|=", ln, cl); return; }
        if (c == '^' and c1 == '=') { self.pos += 2; try self.emit(.caret_equals,        "^=", ln, cl); return; }
        if (c == '?' and c1 == '=') { self.pos += 2; try self.emit(.question_equals,     "?=", ln, cl); return; }
        if (c == '!' and c1 == '=') { self.pos += 2; try self.emit(.bang_equals,         "!=", ln, cl); return; }
        if (c == '.' and c1 == '.') { self.pos += 2; try self.emit(.dotdot,              "..", ln, cl); return; }

        // Single-character operators
        self.pos += 1;
        const kind: TokenKind = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '=' => .assign,
            '<' => .lt,
            '>' => .gt,
            '&' => .ampersand,
            '|' => .vertical_bar,
            '^' => .caret,
            '~' => .tilde,
            '?' => .question,
            '!' => .bang,
            '.' => .dot,
            ':' => .colon,
            ';' => .semi,
            ',' => .comma,
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lcurly,
            '}' => .rcurly,
            else => return error.UnexpectedCharacter,
        };
        // Track parenthesis depth for indentation suppression.
        if (kind == .lparen) {
            self.paren_depth += 1;
        } else if (kind == .rparen and self.paren_depth > 0) {
            self.paren_depth -= 1;
        }
        try self.emit(kind, self.src[self.pos - 1 .. self.pos], ln, cl);
    }
};

// ── Character classifiers ─────────────────────────────────────────────────────

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isHexDigit(c: u8) bool {
    return std.ascii.isDigit(c) or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectKinds(src: []const u8, expected: []const TokenKind) !void {
    const alloc = testing.allocator;
    const toks  = try tokenize(src, alloc);
    defer alloc.free(toks);

    // Strip trailing eof for comparison convenience.
    const n = if (toks.len > 0 and toks[toks.len - 1].kind == .eof) toks.len - 1 else toks.len;

    try testing.expectEqual(expected.len, n);
    for (expected, toks[0..n]) |exp, got| {
        try testing.expectEqual(exp, got.kind);
    }
}

test "hello world class" {
    try expectKinds(
        "class Foo\n\tdef foo()\n\t\treturn 1",
        &.{
            .kw_class, .id, .eol,
            .indent, .kw_def, .open_call, .rparen, .eol,
            .indent, .kw_return, .integer_lit, .eol,
            .dedent, .dedent,
        },
    );
}

test "blank line between classes" {
    try expectKinds(
        "class Foo\n\tpass\n\nclass Bar\n\tpass",
        &.{
            .kw_class, .id, .eol,
            .indent, .kw_pass, .eol,
            .eol,
            .dedent, .kw_class, .id, .eol,
            .indent, .kw_pass, .eol,
            .dedent,
        },
    );
}

test "simple integer and operator tokens" {
    try expectKinds(
        "x = 42 + 1",
        &.{ .id, .assign, .integer_lit, .plus, .integer_lit, .eol },
    );
}

test "plain string literals" {
    try expectKinds(
        \\x = "hello"
        ,
        &.{ .id, .assign, .string_double, .eol },
    );
}

test "interpolated string" {
    try expectKinds(
        \\x = "hi ${name}!"
        ,
        &.{
            .id, .assign,
            .string_start_double,
            .id,
            .rcurly_special,
            .string_stop_double,
            .eol,
        },
    );
}

test "hex literal" {
    try expectKinds("x = 0xFF", &.{ .id, .assign, .hex_lit, .eol });
}

test "toq operator" {
    try expectKinds(
        "y = x to? int",
        &.{ .id, .assign, .id, .toq, .kw_int, .eol },
    );
}

test "at_id and at_lbracket" {
    try expectKinds(
        "@myAttr @[1,2]",
        &.{ .at_id, .at_lbracket, .integer_lit, .comma, .integer_lit, .rbracket, .eol },
    );
}

test "compound assignment operators" {
    try expectKinds(
        "x += 1\ny -= 2\nz **= 3",
        &.{
            .id, .plus_equals,   .integer_lit, .eol,
            .id, .minus_equals,  .integer_lit, .eol,
            .id, .starstar_equals, .integer_lit, .eol,
        },
    );
}
