//! Common Lisp reader (ROADMAP Phase 1.2).
//!
//! Builds a `Value` tree from the token stream a `Tokenizer` produces.
//! The reader is recursive-descent: each top-level call to `read` returns
//! one S-expression, or `null` on EOF at the top level. EOF mid-form is
//! `Error.EndOfInput`. Stray `)` is `Error.UnbalancedParens`.
//!
//! Allocates through a `Heap` (cons cells, strings, floats, ratios,
//! vectors) and interns symbols through a shared `Interner`. The reader
//! never owns its inputs — it borrows the tokenizer's source buffer for
//! token text, and borrows the heap/interner for value construction.

const std = @import("std");
const tok = @import("token.zig");
const tokenizer_mod = @import("tokenizer.zig");
const float_parse = @import("float_parse.zig");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol = @import("../runtime/symbol.zig");

const Token = tok.Token;
const TokenKind = tok.TokenKind;
const Position = tok.Position;
const Tokenizer = tokenizer_mod.Tokenizer;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = symbol.Interner;

/// 1.2.13 error type hierarchy. `EndOfInput` and `UnbalancedParens` cover
/// list-shape failures; `BadToken` covers everything the tokenizer or
/// numeric/character/string post-processing rejects. Allocator errors
/// surface unwrapped so callers can distinguish OOM from bad input.
pub const Error = error{
    /// EOF arrived mid-form (inside a list, a quote, a sharp-dispatch).
    EndOfInput,
    /// Saw `)` with no matching `(` open at this depth.
    UnbalancedParens,
    /// Token was structurally invalid: bad escape, bad numeric lexeme,
    /// unterminated literal, unknown character name, dot in a non-dotted
    /// position, etc.
    BadToken,
} || std.mem.Allocator.Error;

pub const Reader = struct {
    tokenizer: *Tokenizer,
    heap: *Heap,
    interner: *Interner,
    /// One-token lookahead. The reader peeks when it needs to decide
    /// between dotted-pair and final-element in a list, and to detect
    /// EOF without consuming.
    peeked: ?Token = null,

    pub fn init(tokenizer: *Tokenizer, heap: *Heap, interner: *Interner) Reader {
        return .{ .tokenizer = tokenizer, .heap = heap, .interner = interner };
    }

    fn nextToken(self: *Reader) Error!Token {
        if (self.peeked) |t| {
            self.peeked = null;
            return t;
        }
        return self.tokenizer.next() catch |e| switch (e) {
            error.UnexpectedEndOfInput => Error.EndOfInput,
            else => Error.BadToken,
        };
    }

    fn peekToken(self: *Reader) Error!Token {
        if (self.peeked) |t| return t;
        const t = self.tokenizer.next() catch |e| switch (e) {
            error.UnexpectedEndOfInput => return Error.EndOfInput,
            else => return Error.BadToken,
        };
        self.peeked = t;
        return t;
    }

    /// 1.2.1 entry. Returns one form, or null if the stream is empty
    /// before any token. EOF mid-form raises `Error.EndOfInput`.
    pub fn read(self: *Reader) Error!?Value {
        const t = try self.nextToken();
        if (t.kind == .eof) return null;
        return try self.readFromToken(t);
    }

    fn readForm(self: *Reader) Error!Value {
        const t = try self.nextToken();
        if (t.kind == .eof) return Error.EndOfInput;
        return try self.readFromToken(t);
    }

    fn readFromToken(self: *Reader, t: Token) Error!Value {
        return switch (t.kind) {
            .lparen => self.readList(),
            .rparen => Error.UnbalancedParens,
            .dot => Error.BadToken, // dot only legal inside a list
            .quote => self.readReaderMacro("QUOTE"),
            .backquote => self.readReaderMacro("QUASIQUOTE"),
            .comma => self.readReaderMacro("UNQUOTE"),
            .comma_at => self.readReaderMacro("UNQUOTE-SPLICING"),
            .hash_quote => self.readReaderMacro("FUNCTION"),
            .hash_lparen => self.readVector(),
            // 1.2.10 lands the conditional reader. Until then, presence of
            // `#+`/`#-` at top level is a structural error rather than a
            // silent skip — surfaces the missing feature loudly.
            .hash_plus, .hash_minus => Error.BadToken,
            .integer => self.parseInteger(t.text),
            .ratio => self.parseRatio(t.text),
            .float => self.parseFloat(t.text),
            .string => self.parseString(t.text),
            .character => self.parseCharacter(t.text),
            .symbol => self.parseSymbol(t.text),
            .keyword => self.parseKeyword(t.text),
            .eof => Error.EndOfInput,
        };
    }

    /// 1.2.2 / 1.2.3. `()` reads as `NIL`. Otherwise build a chain of cons
    /// cells. A `.` token before the final element switches into dotted
    /// mode — exactly one form must follow, then the closing paren.
    fn readList(self: *Reader) Error!Value {
        var head: Value = value.NIL;
        var tail: Value = value.NIL;
        while (true) {
            const t = try self.peekToken();
            switch (t.kind) {
                .eof => return Error.EndOfInput,
                .rparen => {
                    _ = try self.nextToken();
                    return head;
                },
                .dot => {
                    if (head.equalsRaw(value.NIL)) return Error.BadToken;
                    _ = try self.nextToken();
                    const cdr_form = try self.readForm();
                    const closer = try self.nextToken();
                    if (closer.kind != .rparen) return Error.BadToken;
                    heap_mod.setCdr(tail, cdr_form);
                    return head;
                },
                else => {
                    const elem = try self.readForm();
                    const cell = try self.heap.allocCons(elem, value.NIL);
                    if (head.equalsRaw(value.NIL)) {
                        head = cell;
                        tail = cell;
                    } else {
                        heap_mod.setCdr(tail, cell);
                        tail = cell;
                    }
                },
            }
        }
    }

    /// 1.2.4–1.2.8. `'x` → `(QUOTE x)`, `` `x `` → `(QUASIQUOTE x)`,
    /// `,x` → `(UNQUOTE x)`, `,@x` → `(UNQUOTE-SPLICING x)`,
    /// `#'fn` → `(FUNCTION fn)`. All lower into a 2-element list whose
    /// car is the canonical interned symbol.
    fn readReaderMacro(self: *Reader, sym_name: []const u8) Error!Value {
        const sym = try self.interner.intern(sym_name);
        const inner = try self.readForm();
        const tail = try self.heap.allocCons(inner, value.NIL);
        return try self.heap.allocCons(sym, tail);
    }

    /// 1.2.9. `#(a b c)` reads each form until the matching `)`, then
    /// allocates a flat T-vector. Empty `#()` is permitted.
    fn readVector(self: *Reader) Error!Value {
        var elems: std.ArrayList(Value) = .empty;
        defer elems.deinit(self.heap.allocator);
        while (true) {
            const t = try self.peekToken();
            switch (t.kind) {
                .eof => return Error.EndOfInput,
                .rparen => {
                    _ = try self.nextToken();
                    return try self.heap.allocVector(elems.items);
                },
                .dot => return Error.BadToken,
                else => {
                    const elem = try self.readForm();
                    try elems.append(self.heap.allocator, elem);
                },
            }
        }
    }

    fn parseSymbol(self: *Reader, text: []const u8) Error!Value {
        var buf: [256]u8 = undefined;
        const name = try foldSymbolName(text, &buf);
        return try self.interner.intern(name);
    }

    /// Keyword stub (1.1.10): until Phase 4 packages exist, intern with a
    /// leading `:` so `:FOO` and `FOO` are distinct symbols. The printer
    /// reads the leading `:` back out for free.
    fn parseKeyword(self: *Reader, text: []const u8) Error!Value {
        var buf: [256]u8 = undefined;
        if (text.len + 1 > buf.len) return Error.BadToken;
        buf[0] = ':';
        const folded = try foldSymbolName(text, buf[1..]);
        const name = buf[0 .. folded.len + 1];
        return try self.interner.intern(name);
    }

    fn parseString(self: *Reader, text: []const u8) Error!Value {
        var buf: [4096]u8 = undefined;
        if (text.len > buf.len) {
            // Fall back to heap scratch for very long strings.
            const scratch = try self.heap.allocator.alloc(u8, text.len);
            defer self.heap.allocator.free(scratch);
            const out = unescapeString(text, scratch) catch return Error.BadToken;
            return try self.heap.allocString(out);
        }
        const out = unescapeString(text, &buf) catch return Error.BadToken;
        return try self.heap.allocString(out);
    }

    fn parseInteger(self: *Reader, text: []const u8) Error!Value {
        const n = parseIntegerLexeme(text) catch return Error.BadToken;
        if (n < value.FIXNUM_MIN or n > value.FIXNUM_MAX) {
            // Bignums land in Phase 4. For now reject overflow loudly.
            return Error.BadToken;
        }
        _ = self;
        return Value.fromFixnum(n);
    }

    fn parseRatio(self: *Reader, text: []const u8) Error!Value {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return Error.BadToken;
        const num = parseIntegerLexeme(text[0..slash]) catch return Error.BadToken;
        const den = parseIntegerLexeme(text[slash + 1 ..]) catch return Error.BadToken;
        if (den == 0) return Error.BadToken;
        return try self.heap.allocRatio(num, den);
    }

    fn parseFloat(self: *Reader, text: []const u8) Error!Value {
        const fv = float_parse.parseFloatLexeme(text) catch return Error.BadToken;
        return switch (fv) {
            .single => |x| try self.heap.allocSingleFloat(x),
            .double => |x| try self.heap.allocDoubleFloat(x),
        };
    }

    fn parseCharacter(self: *Reader, text: []const u8) Error!Value {
        _ = self;
        const cp = decodeCharLiteral(text) catch return Error.BadToken;
        return Value.fromChar(cp);
    }
};

/// Apply readtable-case `:upcase` to a symbol's source text. `|..|` runs
/// are taken verbatim with the surrounding pipes stripped; backslash
/// escapes one following character verbatim. `out` must have room for
/// the full result.
fn foldSymbolName(text: []const u8, out: []u8) Error![]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < text.len) : (i += 0) {
        const c = text[i];
        if (c == '|') {
            i += 1;
            while (i < text.len) {
                const ch = text[i];
                if (ch == '|') {
                    i += 1;
                    break;
                }
                if (ch == '\\') {
                    i += 1;
                    if (i >= text.len) return Error.BadToken;
                    if (o >= out.len) return Error.BadToken;
                    out[o] = text[i];
                    o += 1;
                    i += 1;
                    continue;
                }
                if (o >= out.len) return Error.BadToken;
                out[o] = ch;
                o += 1;
                i += 1;
            } else {
                return Error.BadToken;
            }
        } else if (c == '\\') {
            i += 1;
            if (i >= text.len) return Error.BadToken;
            if (o >= out.len) return Error.BadToken;
            out[o] = text[i];
            o += 1;
            i += 1;
        } else {
            if (o >= out.len) return Error.BadToken;
            out[o] = std.ascii.toUpper(c);
            o += 1;
            i += 1;
        }
    }
    return out[0..o];
}

/// String-literal escape processing. CL strings only require `\\` and `\"`
/// per CLHS 2.4.5; other escapes are reserved. We mirror that: any other
/// escape is `BadToken`. The tokenizer kept the bytes between the quotes
/// raw, so we walk them once.
fn unescapeString(text: []const u8, out: []u8) ![]u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\') {
            i += 1;
            if (i >= text.len) return error.BadToken;
            const esc = text[i];
            if (esc != '\\' and esc != '"') return error.BadToken;
            if (o >= out.len) return error.BadToken;
            out[o] = esc;
            o += 1;
        } else {
            if (o >= out.len) return error.BadToken;
            out[o] = c;
            o += 1;
        }
    }
    return out[0..o];
}

const IntegerParseError = error{ Overflow, BadDigit };

/// Decode a numeric lexeme into i64, honoring optional sign and any
/// of `#b`/`#o`/`#x`/`#nR` radix prefixes the tokenizer accepted.
fn parseIntegerLexeme(text: []const u8) IntegerParseError!i64 {
    if (text.len == 0) return IntegerParseError.BadDigit;
    var i: usize = 0;

    var radix: u32 = 10;
    if (text[i] == '#') {
        i += 1;
        if (i >= text.len) return IntegerParseError.BadDigit;
        switch (text[i]) {
            'b', 'B' => {
                radix = 2;
                i += 1;
            },
            'o', 'O' => {
                radix = 8;
                i += 1;
            },
            'x', 'X' => {
                radix = 16;
                i += 1;
            },
            else => {
                // Explicit `#nnRdigits`.
                var r: u32 = 0;
                while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
                    r = r * 10 + (text[i] - '0');
                    if (r > 36) return IntegerParseError.BadDigit;
                }
                if (r < 2) return IntegerParseError.BadDigit;
                if (i >= text.len) return IntegerParseError.BadDigit;
                if (text[i] != 'r' and text[i] != 'R') return IntegerParseError.BadDigit;
                i += 1;
                radix = r;
            },
        }
    }

    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    if (i >= text.len) return IntegerParseError.BadDigit;

    var acc: i128 = 0;
    while (i < text.len) : (i += 1) {
        const d = digitValue(text[i]) orelse return IntegerParseError.BadDigit;
        if (d >= radix) return IntegerParseError.BadDigit;
        acc = acc * @as(i128, radix) + @as(i128, d);
        if (acc > std.math.maxInt(i64)) return IntegerParseError.Overflow;
    }
    if (negative) acc = -acc;
    if (acc > std.math.maxInt(i64) or acc < std.math.minInt(i64)) {
        return IntegerParseError.Overflow;
    }
    return @intCast(acc);
}

fn digitValue(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => null,
    };
}

const CharLiteralError = error{Bad};

/// Decode the character-literal text the tokenizer captured (the part
/// after `#\`). Recognized: a single character (any codepoint), the
/// CLHS character names (`Space`, `Newline`, `Tab`, `Return`, `Page`,
/// `Rubout`, `Linefeed`, `Backspace`, `Null`), and `U+XXXX` hex.
fn decodeCharLiteral(text: []const u8) CharLiteralError!u21 {
    if (text.len == 0) return CharLiteralError.Bad;
    if (text.len == 1) return @as(u21, text[0]);

    // Multi-byte UTF-8 single character.
    if ((text[0] & 0x80) != 0) {
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return CharLiteralError.Bad;
        if (len == text.len) {
            return std.unicode.utf8Decode(text) catch CharLiteralError.Bad;
        }
    }

    if (std.ascii.eqlIgnoreCase(text, "Space")) return ' ';
    if (std.ascii.eqlIgnoreCase(text, "Newline")) return '\n';
    if (std.ascii.eqlIgnoreCase(text, "Tab")) return '\t';
    if (std.ascii.eqlIgnoreCase(text, "Return")) return '\r';
    if (std.ascii.eqlIgnoreCase(text, "Linefeed")) return '\n';
    if (std.ascii.eqlIgnoreCase(text, "Page")) return 0x0C;
    if (std.ascii.eqlIgnoreCase(text, "Backspace")) return 0x08;
    if (std.ascii.eqlIgnoreCase(text, "Rubout")) return 0x7F;
    if (std.ascii.eqlIgnoreCase(text, "Null")) return 0;

    if (text.len >= 2 and (text[0] == 'U' or text[0] == 'u') and text[1] == '+') {
        const hex = text[2..];
        if (hex.len == 0 or hex.len > 6) return CharLiteralError.Bad;
        const n = std.fmt.parseInt(u32, hex, 16) catch return CharLiteralError.Bad;
        if (n > 0x10FFFF) return CharLiteralError.Bad;
        return @intCast(n);
    }

    return CharLiteralError.Bad;
}
