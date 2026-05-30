//! Common Lisp tokenizer.
//!
//! The tokenizer is allocation-free: every token's `text` is a slice into
//! the source buffer the caller provided. The tokenizer borrows the source
//! for its lifetime; the caller keeps it alive.
//!
//! Float literals are recognized as a lexeme but not parsed — the token's
//! `text` carries the full source. Numeric value parsing belongs to the
//! reader, which has a 100-value SBCL-diffed corpus gate.
//!
//! Keyword tokens are reported with the leading `:` stripped from `text`;
//! the reader will intern into the KEYWORD package once packages exist.

const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const TokenKind = tok.TokenKind;
const Position = tok.Position;

pub const Error = error{
    /// `EndOfInput` mid-token (unterminated string, character literal,
    /// `|..|` symbol, or `#| ... |#` block comment).
    UnexpectedEndOfInput,
    /// Saw `#X` for an X with no defined dispatch behavior (e.g. `#$`).
    BadDispatchChar,
    /// Saw a token that looks like a number but isn't well-formed
    /// (e.g. `1/`, `#b2`, `#3R9`).
    BadNumericLiteral,
    /// Saw a closing pipe-escape or backslash without anything following.
    BadEscape,
    /// `#nR...` with `n` outside the spec's 2..36 range.
    BadRadix,
    /// `,@` or other reader-macro form encountered in a context that doesn't
    /// support it. The tokenizer doesn't enforce context; this is reserved
    /// for the reader.
    Unreachable,
};

pub const Tokenizer = struct {
    src: []const u8,
    /// Byte offset of the next character to read.
    idx: usize = 0,
    /// 1-based line for the next character to read.
    line: u32 = 1,
    /// 1-based column for the next character to read.
    col: u32 = 1,
    /// Start position of the most recent `next()` token, captured after
    /// skipping leading trivia. The reader uses this to point error
    /// messages at the start of a malformed token rather than
    /// at the leading whitespace or the in-progress token-recognition
    /// state at the moment the tokenizer raised.
    last_token_start: Position = .{},

    pub fn init(src: []const u8) Tokenizer {
        return .{ .src = src };
    }

    pub fn pos(self: *const Tokenizer) Position {
        return .{
            .line = self.line,
            .column = self.col,
            .byte_offset = @intCast(self.idx),
        };
    }

    fn peek(self: *const Tokenizer) ?u8 {
        if (self.idx >= self.src.len) return null;
        return self.src[self.idx];
    }

    fn peekAt(self: *const Tokenizer, offset: usize) ?u8 {
        const i = self.idx + offset;
        if (i >= self.src.len) return null;
        return self.src[i];
    }

    fn advance(self: *Tokenizer) void {
        const c = self.src[self.idx];
        self.idx += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    /// Whitespace per CLHS 2.1.4.7: space, tab, newline, return, page (form
    /// feed), and vertical tab. Linefeed advances `line`.
    fn isWhitespace(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', 0x0C, 0x0B => true,
            else => false,
        };
    }

    /// Characters that terminate a symbol/number lexeme without being
    /// consumed.
    fn isTerminator(c: u8) bool {
        return isWhitespace(c) or switch (c) {
            '(', ')', '\'', '`', ',', ';', '"', '|' => true,
            else => false,
        };
    }

    /// Eat whitespace and comments. Block comments nest.
    fn skipTrivia(self: *Tokenizer) Error!void {
        while (true) {
            const c = self.peek() orelse return;
            if (isWhitespace(c)) {
                self.advance();
            } else if (c == ';') {
                while (self.peek()) |ch| {
                    if (ch == '\n') break;
                    self.advance();
                }
            } else if (c == '#' and self.peekAt(1) == '|') {
                try self.skipBlockComment();
            } else {
                return;
            }
        }
    }

    fn skipBlockComment(self: *Tokenizer) Error!void {
        // Caller has confirmed `#|` at idx; consume it, then walk until the
        // matching `|#`. Counts nesting so `#| outer #| inner |# outer |#`
        // closes the outer comment exactly.
        self.advance(); // '#'
        self.advance(); // '|'
        var depth: u32 = 1;
        while (depth > 0) {
            const c = self.peek() orelse return Error.UnexpectedEndOfInput;
            if (c == '#' and self.peekAt(1) == '|') {
                self.advance();
                self.advance();
                depth += 1;
            } else if (c == '|' and self.peekAt(1) == '#') {
                self.advance();
                self.advance();
                depth -= 1;
            } else {
                self.advance();
            }
        }
    }

    pub fn next(self: *Tokenizer) Error!Token {
        try self.skipTrivia();
        const start_pos = self.pos();
        self.last_token_start = start_pos;
        const start_idx = self.idx;
        const c = self.peek() orelse return .{
            .kind = .eof,
            .pos = start_pos,
            .text = self.src[self.src.len..],
        };

        return switch (c) {
            '(' => self.singleChar(.lparen, start_pos, start_idx),
            ')' => self.singleChar(.rparen, start_pos, start_idx),
            '\'' => self.singleChar(.quote, start_pos, start_idx),
            '`' => self.singleChar(.backquote, start_pos, start_idx),
            ',' => self.commaForm(start_pos, start_idx),
            '"' => self.stringLiteral(start_pos),
            '|' => self.pipeSymbol(start_pos),
            ':' => self.keyword(start_pos),
            '#' => self.dispatch(start_pos, start_idx),
            '+', '-' => self.signedAtom(start_pos, start_idx),
            '0'...'9' => self.numericOrSymbol(start_pos, start_idx),
            '.' => self.dotForm(start_pos, start_idx),
            else => self.symbol(start_pos, start_idx),
        };
    }

    /// Token starting with `.`. Could be:
    ///   `.` alone (dotted-pair separator)
    ///   `.5` / `.0e10` — float (digit after the dot)
    ///   `.foo` — symbol with leading dot
    fn dotForm(self: *Tokenizer, start_pos: Position, start_idx: usize) Error!Token {
        if (self.peekAt(1)) |nc| {
            if (std.ascii.isDigit(nc)) {
                return self.numericOrSymbol(start_pos, start_idx);
            }
        }
        self.advance(); // '.'
        if (self.peek() == null or isTerminator(self.peek().?)) {
            return .{
                .kind = .dot,
                .pos = start_pos,
                .text = self.src[start_idx..self.idx],
            };
        }
        self.scanSymbolBody();
        return .{
            .kind = .symbol,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }

    fn singleChar(
        self: *Tokenizer,
        kind: TokenKind,
        start_pos: Position,
        start_idx: usize,
    ) Token {
        self.advance();
        return .{
            .kind = kind,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }

    fn commaForm(self: *Tokenizer, start_pos: Position, start_idx: usize) Token {
        self.advance(); // ','
        if (self.peek() == @as(u8, '@')) {
            self.advance();
            return .{
                .kind = .comma_at,
                .pos = start_pos,
                .text = self.src[start_idx..self.idx],
            };
        }
        return .{
            .kind = .comma,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }

    fn stringLiteral(self: *Tokenizer, start_pos: Position) Error!Token {
        self.advance(); // opening quote
        const content_start = self.idx;
        while (true) {
            const c = self.peek() orelse return Error.UnexpectedEndOfInput;
            if (c == '"') break;
            if (c == '\\') {
                self.advance();
                if (self.peek() == null) return Error.UnexpectedEndOfInput;
                self.advance();
                continue;
            }
            self.advance();
        }
        const content_end = self.idx;
        self.advance(); // closing quote
        return .{
            .kind = .string,
            .pos = start_pos,
            .text = self.src[content_start..content_end],
        };
    }

    fn pipeSymbol(self: *Tokenizer, start_pos: Position) Error!Token {
        // `|...|` runs verbatim, with backslash escape for embedded `|` or `\`.
        // Tokenizer keeps the pipes in `text` so the reader knows to skip case
        // folding for this name.
        const start_idx = self.idx;
        self.advance(); // opening pipe
        while (true) {
            const c = self.peek() orelse return Error.UnexpectedEndOfInput;
            if (c == '|') break;
            if (c == '\\') {
                self.advance();
                if (self.peek() == null) return Error.UnexpectedEndOfInput;
                self.advance();
                continue;
            }
            self.advance();
        }
        self.advance(); // closing pipe
        return .{
            .kind = .symbol,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }

    fn keyword(self: *Tokenizer, start_pos: Position) Error!Token {
        self.advance(); // ':'
        // After the colon: a name token, possibly pipe-quoted. We reuse the
        // symbol-body scan but emit a keyword kind. `text` excludes the colon.
        const name_start = self.idx;
        if (self.peek() == @as(u8, '|')) {
            // Quoted body — scan to closing pipe, leave the pipes in text.
            self.advance();
            while (true) {
                const c = self.peek() orelse return Error.UnexpectedEndOfInput;
                if (c == '|') break;
                if (c == '\\') {
                    self.advance();
                    if (self.peek() == null) return Error.UnexpectedEndOfInput;
                    self.advance();
                    continue;
                }
                self.advance();
            }
            self.advance();
        } else {
            // Bare body — read until terminator. Backslash escapes single
            // characters per CLHS 2.4.8; same as a plain symbol.
            self.scanSymbolBody();
        }
        return .{
            .kind = .keyword,
            .pos = start_pos,
            .text = self.src[name_start..self.idx],
        };
    }

    fn scanSymbolBody(self: *Tokenizer) void {
        while (self.peek()) |c| {
            if (isTerminator(c)) break;
            if (c == '\\') {
                self.advance();
                if (self.peek() == null) return;
                self.advance();
                continue;
            }
            self.advance();
        }
    }

    fn dispatch(self: *Tokenizer, start_pos: Position, start_idx: usize) Error!Token {
        self.advance(); // '#'
        const c = self.peek() orelse return Error.BadDispatchChar;
        return switch (c) {
            '\'' => blk: {
                self.advance();
                break :blk .{
                    .kind = .hash_quote,
                    .pos = start_pos,
                    .text = self.src[start_idx..self.idx],
                };
            },
            '(' => blk: {
                self.advance();
                break :blk .{
                    .kind = .hash_lparen,
                    .pos = start_pos,
                    .text = self.src[start_idx..self.idx],
                };
            },
            '+' => blk: {
                self.advance();
                break :blk .{
                    .kind = .hash_plus,
                    .pos = start_pos,
                    .text = self.src[start_idx..self.idx],
                };
            },
            '-' => blk: {
                self.advance();
                break :blk .{
                    .kind = .hash_minus,
                    .pos = start_pos,
                    .text = self.src[start_idx..self.idx],
                };
            },
            '\\' => self.charLiteral(start_pos),
            'b', 'B', 'o', 'O', 'x', 'X' => self.radixIntegerSingleChar(start_pos, start_idx),
            '0'...'9' => self.radixIntegerExplicit(start_pos, start_idx),
            // `#|` is consumed by skipTrivia at the top of next(), so we never
            // see `|` here. Anything else is a dispatch we don't recognize.
            else => Error.BadDispatchChar,
        };
    }

    fn charLiteral(self: *Tokenizer, start_pos: Position) Error!Token {
        self.advance(); // '\\'
        const name_start = self.idx;
        const first = self.peek() orelse return Error.UnexpectedEndOfInput;
        self.advance();
        if ((first & 0x80) != 0) {
            // Multi-byte UTF-8 single character: consume the continuation
            // bytes so the captured `text` is the whole codepoint.
            const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
            var k: usize = 1;
            while (k < len and self.peek() != null) : (k += 1) self.advance();
        } else if (isCharNameStart(first)) {
            // ASCII character name (Space, Newline, U+XXXX, etc.) — extend
            // until a terminator. `#\(`, `#\ `, `#\\` already stopped after
            // one character because their first char isn't a name start.
            while (self.peek()) |c| {
                if (isTerminator(c)) break;
                self.advance();
            }
        }
        return .{
            .kind = .character,
            .pos = start_pos,
            .text = self.src[name_start..self.idx],
        };
    }

    fn isCharNameStart(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '+' or c == '-';
    }

    /// `#b1010` / `#o755` / `#xFF` — single-letter radix prefix.
    fn radixIntegerSingleChar(
        self: *Tokenizer,
        start_pos: Position,
        start_idx: usize,
    ) Error!Token {
        self.advance(); // the radix letter
        const digits_start = self.idx;
        try self.scanSignedDigits();
        if (self.idx == digits_start) return Error.BadNumericLiteral;
        return .{
            .kind = .integer,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }

    /// `#nnRdigits` — explicit radix in 2..36.
    fn radixIntegerExplicit(
        self: *Tokenizer,
        start_pos: Position,
        start_idx: usize,
    ) Error!Token {
        var radix: u32 = 0;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            radix = radix * 10 + (c - '0');
            if (radix > 36) return Error.BadRadix;
            self.advance();
        }
        if (radix < 2) return Error.BadRadix;
        const r_marker = self.peek() orelse return Error.BadNumericLiteral;
        if (r_marker != 'r' and r_marker != 'R') return Error.BadNumericLiteral;
        self.advance();
        const digits_start = self.idx;
        try self.scanSignedDigits();
        if (self.idx == digits_start) return Error.BadNumericLiteral;
        return .{
            .kind = .integer,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }

    fn scanSignedDigits(self: *Tokenizer) Error!void {
        if (self.peek()) |c| {
            if (c == '+' or c == '-') self.advance();
        }
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                self.advance();
            } else break;
        }
    }

    /// Saw `+` or `-` at the start of a token. Could be:
    ///   - signed integer / ratio / float (`+1`, `-3/4`, `-1.5`)
    ///   - the symbol `+` or `-` (terminator follows)
    ///   - a longer symbol (`++`, `-foo`)
    fn signedAtom(self: *Tokenizer, start_pos: Position, start_idx: usize) Error!Token {
        // Look at what follows the sign without consuming it. A digit means
        // a number; anything else (including EOF or terminator) means symbol.
        const next_c = self.peekAt(1);
        if (next_c == null or !std.ascii.isDigit(next_c.?)) {
            return self.symbol(start_pos, start_idx);
        }
        return self.numericOrSymbol(start_pos, start_idx);
    }

    /// Top-level numeric-shaped scan. Consume the symbol-body as a lexeme,
    /// then post-classify by walking the text. CL's rule (CLHS 2.3) is
    /// "if the lexeme matches one of the numeric shapes, it's that number;
    /// otherwise it's a symbol that happened to start digit-ish." So `1-`
    /// and `1/` and `1.5/2` are all symbols.
    fn numericOrSymbol(
        self: *Tokenizer,
        start_pos: Position,
        start_idx: usize,
    ) Error!Token {
        var saw_escape = false;
        while (self.peek()) |c| {
            if (isTerminator(c)) break;
            if (c == '\\') {
                saw_escape = true;
                self.advance();
                if (self.peek() == null) break;
                self.advance();
                continue;
            }
            self.advance();
        }
        const text = self.src[start_idx..self.idx];
        if (saw_escape) {
            return .{ .kind = .symbol, .pos = start_pos, .text = text };
        }
        return .{ .kind = classifyNumericLexeme(text), .pos = start_pos, .text = text };
    }

    /// Decide whether a backslash-free lexeme is a CL number per CLHS 2.3.
    /// Anything that isn't recognized as integer / ratio / float is a symbol.
    fn classifyNumericLexeme(text: []const u8) TokenKind {
        if (text.len == 0) return .symbol;
        var i: usize = 0;
        if (text[0] == '+' or text[0] == '-') i += 1;

        const d1_start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        const d1 = i - d1_start;

        if (i == text.len) return if (d1 > 0) .integer else .symbol;

        if (text[i] == '/') {
            if (d1 == 0) return .symbol;
            i += 1;
            const d2_start = i;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
            const d2 = i - d2_start;
            return if (i == text.len and d2 > 0) .ratio else .symbol;
        }

        if (text[i] == '.') {
            i += 1;
            const d2_start = i;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
            const d2 = i - d2_start;
            if (i == text.len) {
                // `123.` → integer; `.5` / `1.5` → float; `.` alone is a symbol
                // here (caller owns the dot-token path)
                if (d1 > 0 and d2 == 0) return .integer;
                if (d1 + d2 > 0) return .float;
                return .symbol;
            }
            if (isExpMarker(text[i])) return classifyExponent(text, i + 1, d1 + d2);
            return .symbol;
        }

        if (isExpMarker(text[i])) {
            if (d1 == 0) return .symbol;
            return classifyExponent(text, i + 1, d1);
        }

        return .symbol;
    }

    fn classifyExponent(text: []const u8, start: usize, mantissa_digits: usize) TokenKind {
        if (mantissa_digits == 0) return .symbol;
        var i = start;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const exp_start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        const exp_digits = i - exp_start;
        return if (i == text.len and exp_digits > 0) .float else .symbol;
    }

    fn isExpMarker(c: u8) bool {
        return switch (c) {
            'e', 'E', 's', 'S', 'f', 'F', 'd', 'D', 'l', 'L' => true,
            else => false,
        };
    }

    /// Plain symbol path: anything that didn't match digit / sign / dot /
    /// dispatch / structural / reader-macro entry points.
    fn symbol(self: *Tokenizer, start_pos: Position, start_idx: usize) Error!Token {
        self.scanSymbolBody();
        return .{
            .kind = .symbol,
            .pos = start_pos,
            .text = self.src[start_idx..self.idx],
        };
    }
};
