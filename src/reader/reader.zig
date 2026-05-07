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
//!
//! Reader-macro dispatch (1.2.11) goes through a `Readtable` so the
//! handler set is replaceable. Source positions (1.2.12) are written to
//! an optional side-table keyed on cons address.
//!
//! Conditional reading (1.2.10) runs through the same readtable: `#+` and
//! `#-` consume a feature expression and a following form; the form is
//! either kept or discarded based on whether the expression matches the
//! reader's `features` list. A discarded form yields a `ReadStep.skipped`
//! result so the surrounding context (top-level `read`, list/vector
//! readers, or another reader macro) can continue.

const std = @import("std");
const tok = @import("token.zig");
const tokenizer_mod = @import("tokenizer.zig");
const float_parse = @import("float_parse.zig");
const readtable_mod = @import("readtable.zig");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol = @import("../runtime/symbol.zig");
const source_pos = @import("../runtime/source_pos.zig");

const Token = tok.Token;
const TokenKind = tok.TokenKind;
const Position = tok.Position;
const Tokenizer = tokenizer_mod.Tokenizer;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = symbol.Interner;
const Readtable = readtable_mod.Readtable;
const MacroHandler = readtable_mod.MacroHandler;
const ReadStep = readtable_mod.ReadStep;
const PositionTable = source_pos.PositionTable;
const SourcePosition = source_pos.SourcePosition;

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

/// Default readtable shared by every reader that doesn't supply its own.
/// Initialized lazily on first `Reader.init` so the standard handlers
/// (defined below) are visible at call time.
var standard_readtable: ?Readtable = null;

/// The built-in handler vtable, exposed so users (and tests) can build
/// their own readtables seeded from the defaults.
pub const standard_handlers: readtable_mod.StandardHandlers = .{
    .quote = handleQuote,
    .backquote = handleBackquote,
    .comma = handleComma,
    .comma_at = handleCommaAt,
    .hash_quote = handleHashQuote,
    .hash_lparen = handleHashLparen,
    .hash_plus = handleHashPlus,
    .hash_minus = handleHashMinus,
};

/// Process-wide standard readtable, lazily initialized. Every `Reader.init`
/// without an explicit readtable argument uses this one.
pub fn defaultReadtable() *Readtable {
    if (standard_readtable == null) {
        standard_readtable = Readtable.initStandard(standard_handlers);
    }
    return &standard_readtable.?;
}

pub const Reader = struct {
    tokenizer: *Tokenizer,
    heap: *Heap,
    interner: *Interner,
    readtable: *Readtable,
    /// Optional side-table for cons positions (1.2.12). When non-null the
    /// reader records `(file, line, column)` for every cons it allocates.
    positions: ?*PositionTable = null,
    /// Filename associated with this reader's input. Borrowed; the caller
    /// keeps it alive. Used only when `positions` is non-null.
    file: []const u8 = "",
    /// Active feature symbols for `#+` / `#-` (1.2.10). Empty by default.
    /// Borrowed: the caller keeps the slice alive. Names match feature
    /// expressions case-sensitively after stripping a leading `:` from
    /// either side, mirroring CL's "feature names compare by symbol-name".
    features: []const Value = &.{},
    /// One-token lookahead. The reader peeks when it needs to decide
    /// between dotted-pair and final-element in a list, and to detect
    /// EOF without consuming.
    peeked: ?Token = null,
    /// Position of the last error this reader returned (1.4.2). Reset
    /// to null at the start of every public `read` call. Use
    /// `lastErrorPos` to retrieve after a failing read.
    last_error_pos: ?SourcePosition = null,

    pub fn init(tokenizer: *Tokenizer, heap: *Heap, interner: *Interner) Reader {
        return .{
            .tokenizer = tokenizer,
            .heap = heap,
            .interner = interner,
            .readtable = defaultReadtable(),
        };
    }

    /// Build a reader with explicit readtable, source-position table, and
    /// filename. Pass `null` for `positions` to skip position tracking.
    pub fn initFull(
        tokenizer: *Tokenizer,
        heap: *Heap,
        interner: *Interner,
        rt: *Readtable,
        positions: ?*PositionTable,
        file: []const u8,
    ) Reader {
        return .{
            .tokenizer = tokenizer,
            .heap = heap,
            .interner = interner,
            .readtable = rt,
            .positions = positions,
            .file = file,
        };
    }

    /// Replace the active feature list. Borrowed: caller keeps the slice
    /// alive for the reader's lifetime.
    pub fn setFeatures(self: *Reader, features: []const Value) void {
        self.features = features;
    }

    /// 1.4.2 accessor. Position of the most recently raised reader error,
    /// or null if the last public `read` call succeeded. The position
    /// resets at the start of every `read` so old errors don't leak into
    /// later results.
    pub fn lastErrorPos(self: *const Reader) ?SourcePosition {
        return self.last_error_pos;
    }

    /// Stamp `last_error_pos` from the supplied source position, then
    /// return the error so callers can chain via `return self.errAt(...)`.
    fn errAt(self: *Reader, p: Position, err: Error) Error {
        self.last_error_pos = .{
            .file = self.file,
            .line = p.line,
            .column = p.column,
        };
        return err;
    }

    fn nextToken(self: *Reader) Error!Token {
        if (self.peeked) |t| {
            self.peeked = null;
            return t;
        }
        return self.tokenizer.next() catch |e| {
            const at = self.tokenizer.last_token_start;
            return switch (e) {
                error.UnexpectedEndOfInput => self.errAt(at, Error.EndOfInput),
                else => self.errAt(at, Error.BadToken),
            };
        };
    }

    fn peekToken(self: *Reader) Error!Token {
        if (self.peeked) |t| return t;
        const t = self.tokenizer.next() catch |e| {
            const at = self.tokenizer.last_token_start;
            return switch (e) {
                error.UnexpectedEndOfInput => self.errAt(at, Error.EndOfInput),
                else => self.errAt(at, Error.BadToken),
            };
        };
        self.peeked = t;
        return t;
    }

    /// Allocate a cons and (if a position table is bound) record `pos`.
    fn allocConsAt(self: *Reader, car_v: Value, cdr_v: Value, pos: Position) Error!Value {
        const cell = try self.heap.allocCons(car_v, cdr_v);
        if (self.positions) |table| {
            try table.record(cell, .{
                .file = self.file,
                .line = pos.line,
                .column = pos.column,
            });
        }
        return cell;
    }

    /// 1.2.1 entry. Returns one form, or null if the stream is empty
    /// before any token. EOF mid-form raises `Error.EndOfInput`.
    ///
    /// Loops past `skipped` results so a top-level `#+nope x` followed by
    /// EOF returns null cleanly, and `#+nope x y` returns `y`.
    /// Resets `last_error_pos` so callers see the error position only
    /// from the most recent failing read (1.4.2). If a deeper site
    /// didn't stamp a position before the error escaped, the wrapper
    /// captures the current tokenizer position as a best-effort fallback.
    pub fn read(self: *Reader) Error!?Value {
        self.last_error_pos = null;
        return self.readImpl() catch |err| {
            if (self.last_error_pos == null) {
                const tp = self.tokenizer.pos();
                self.last_error_pos = .{
                    .file = self.file,
                    .line = tp.line,
                    .column = tp.column,
                };
            }
            return err;
        };
    }

    fn readImpl(self: *Reader) Error!?Value {
        while (true) {
            const t = try self.nextToken();
            if (t.kind == .eof) return null;
            switch (try self.readFromToken(t)) {
                .value => |v| return v,
                .skipped => {},
            }
        }
    }

    /// Internal: read one form, looping past any `skipped` step. Used by
    /// reader-macro handlers that need exactly one form (quote, the
    /// kept-side of `#+`/`#-`, etc.). Mid-form EOF raises `EndOfInput`.
    fn readForm(self: *Reader) Error!Value {
        while (true) {
            const t = try self.nextToken();
            switch (try self.readFromToken(t)) {
                .value => |v| return v,
                .skipped => {},
            }
        }
    }

    fn readFromToken(self: *Reader, t: Token) Error!ReadStep {
        // Reader-macro tokens go through the dispatch table so user-side
        // overrides (1.2.11) actually fire. Everything else is a fixed
        // shape the tokenizer already classified.
        if (self.readtable.get(t.kind)) |handler| {
            return try handler(@ptrCast(self));
        }
        return switch (t.kind) {
            .lparen => ReadStep{ .value = try self.readListAt(t.pos) },
            .rparen => self.errAt(t.pos, Error.UnbalancedParens),
            .dot => self.errAt(t.pos, Error.BadToken), // dot only legal inside a list
            .integer => ReadStep{ .value = try self.parseIntegerAt(t.text, t.pos) },
            .ratio => ReadStep{ .value = try self.parseRatioAt(t.text, t.pos) },
            .float => ReadStep{ .value = try self.parseFloatAt(t.text, t.pos) },
            .string => ReadStep{ .value = try self.parseStringAt(t.text, t.pos) },
            .character => ReadStep{ .value = try self.parseCharacterAt(t.text, t.pos) },
            .symbol => ReadStep{ .value = try self.parseSymbolAt(t.text, t.pos) },
            .keyword => ReadStep{ .value = try self.parseKeywordAt(t.text, t.pos) },
            .eof => self.errAt(t.pos, Error.EndOfInput),
            // Reader-macro kinds without a handler shouldn't reach here —
            // the standard readtable populates them. A null means user code
            // explicitly cleared an entry; surface as BadToken.
            .quote, .backquote, .comma, .comma_at, .hash_quote, .hash_lparen, .hash_plus, .hash_minus => self.errAt(t.pos, Error.BadToken),
        };
    }

    /// 1.2.2 / 1.2.3. `()` reads as `NIL`. Otherwise build a chain of cons
    /// cells. A `.` token before the final element switches into dotted
    /// mode — exactly one form must follow, then the closing paren.
    /// Element-position dispatches that produce `skipped` are silently
    /// re-tried so `#+`/`#-` can elide entries.
    fn readListAt(self: *Reader, lparen_pos: Position) Error!Value {
        var head: Value = value.NIL;
        var tail: Value = value.NIL;
        while (true) {
            const t = try self.peekToken();
            switch (t.kind) {
                .eof => return self.errAt(lparen_pos, Error.EndOfInput),
                .rparen => {
                    _ = try self.nextToken();
                    return head;
                },
                .dot => {
                    if (head.equalsRaw(value.NIL)) return self.errAt(t.pos, Error.BadToken);
                    _ = try self.nextToken();
                    const cdr_form = try self.readForm();
                    const closer = try self.nextToken();
                    if (closer.kind != .rparen) return self.errAt(closer.pos, Error.BadToken);
                    heap_mod.setCdr(tail, cdr_form);
                    return head;
                },
                else => {
                    const elem_pos = t.pos;
                    _ = try self.nextToken();
                    const step = try self.readFromToken(t);
                    switch (step) {
                        .skipped => continue,
                        .value => |elem| {
                            const cell_pos = if (head.equalsRaw(value.NIL)) lparen_pos else elem_pos;
                            const cell = try self.allocConsAt(elem, value.NIL, cell_pos);
                            if (head.equalsRaw(value.NIL)) {
                                head = cell;
                                tail = cell;
                            } else {
                                heap_mod.setCdr(tail, cell);
                                tail = cell;
                            }
                        },
                    }
                },
            }
        }
    }

    /// 1.2.4–1.2.8 helper: lower a reader-macro form into `(SYM x)`.
    /// The handlers below all funnel through this; the readtable picks
    /// which symbol to splice in.
    fn readMacroExpansion(self: *Reader, sym_name: []const u8) Error!Value {
        const sym = try self.interner.intern(sym_name);
        const inner = try self.readForm();
        // Use the inner form's position when we don't have a separate
        // capture for the macro character itself.
        const pos: Position = .{};
        const tail = try self.allocConsAt(inner, value.NIL, pos);
        return try self.allocConsAt(sym, tail, pos);
    }

    /// 1.2.9. `#(a b c)` reads each form until the matching `)`, then
    /// allocates a flat T-vector. Empty `#()` is permitted. Conditional
    /// elements that produce `skipped` are silently elided, matching the
    /// list-reader behavior.
    fn readVector(self: *Reader) Error!Value {
        var elems: std.ArrayList(Value) = .empty;
        defer elems.deinit(self.heap.allocator);
        while (true) {
            const t = try self.peekToken();
            switch (t.kind) {
                .eof => return self.errAt(t.pos, Error.EndOfInput),
                .rparen => {
                    _ = try self.nextToken();
                    return try self.heap.allocVector(elems.items);
                },
                .dot => return self.errAt(t.pos, Error.BadToken),
                else => {
                    _ = try self.nextToken();
                    switch (try self.readFromToken(t)) {
                        .skipped => continue,
                        .value => |elem| try elems.append(self.heap.allocator, elem),
                    }
                },
            }
        }
    }

    /// 1.2.10. Read a feature expression, then read the following form.
    /// Keep the form when the expression's truth value matches `want`;
    /// otherwise discard it and signal `skipped`.
    fn readConditional(self: *Reader, want: bool) Error!ReadStep {
        const expr = try self.readForm();
        const present = try self.evalFeatureExpr(expr);
        if (present == want) {
            return ReadStep{ .value = try self.readForm() };
        }
        // Read and discard the form. We don't bind `*read-suppress*` yet
        // (that lands with Phase 2's special-variable plumbing); instead
        // we read normally and throw away the result. Bad input inside a
        // discarded form still raises errors — strictly less permissive
        // than `*read-suppress* T`, but matches "fail loud" until Phase 2.
        _ = try self.readForm();
        return ReadStep.skipped;
    }

    /// True if any feature in `self.features` shares a name with `query`,
    /// stripping a leading `:` from either side. Phase 4 swaps this for a
    /// real `KEYWORD::name` package lookup.
    pub fn hasFeature(self: *const Reader, query_name: []const u8) bool {
        const q = stripLeadingColon(query_name);
        for (self.features) |f| {
            if (!f.isSymbol()) continue;
            const fname = stripLeadingColon(symbol.name(f));
            if (std.mem.eql(u8, fname, q)) return true;
        }
        return false;
    }

    /// Recursively interpret a feature expression. CLHS 24.1.2.1.1:
    /// a symbol is true iff it names a feature; `(or e...)` is the
    /// disjunction (false on empty); `(and e...)` is the conjunction
    /// (true on empty); `(not e)` requires exactly one operand.
    pub fn evalFeatureExpr(self: *Reader, expr: Value) Error!bool {
        if (expr.isSymbol()) {
            return self.hasFeature(symbol.name(expr));
        }
        if (!expr.isCons()) return Error.BadToken;
        const op_v = heap_mod.car(expr);
        if (!op_v.isSymbol()) return Error.BadToken;
        const op_name = stripLeadingColon(symbol.name(op_v));
        var args = heap_mod.cdr(expr);

        if (eqlIgnoreCase(op_name, "OR")) {
            while (args.isCons()) : (args = heap_mod.cdr(args)) {
                if (try self.evalFeatureExpr(heap_mod.car(args))) return true;
            }
            if (!args.equalsRaw(value.NIL)) return Error.BadToken;
            return false;
        }
        if (eqlIgnoreCase(op_name, "AND")) {
            while (args.isCons()) : (args = heap_mod.cdr(args)) {
                if (!try self.evalFeatureExpr(heap_mod.car(args))) return false;
            }
            if (!args.equalsRaw(value.NIL)) return Error.BadToken;
            return true;
        }
        if (eqlIgnoreCase(op_name, "NOT")) {
            if (!args.isCons()) return Error.BadToken;
            const only = heap_mod.car(args);
            if (!heap_mod.cdr(args).equalsRaw(value.NIL)) return Error.BadToken;
            return !(try self.evalFeatureExpr(only));
        }
        return Error.BadToken;
    }

    fn parseSymbolAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        var buf: [256]u8 = undefined;
        const name = foldSymbolName(text, &buf) catch |e| return self.errAt(p, e);
        return try self.interner.intern(name);
    }

    /// Keyword stub (1.1.10): until Phase 4 packages exist, intern with a
    /// leading `:` so `:FOO` and `FOO` are distinct symbols. The printer
    /// reads the leading `:` back out for free.
    fn parseKeywordAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        var buf: [256]u8 = undefined;
        if (text.len + 1 > buf.len) return self.errAt(p, Error.BadToken);
        buf[0] = ':';
        const folded = foldSymbolName(text, buf[1..]) catch |e| return self.errAt(p, e);
        const name = buf[0 .. folded.len + 1];
        return try self.interner.intern(name);
    }

    fn parseStringAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        var buf: [4096]u8 = undefined;
        if (text.len > buf.len) {
            // Fall back to heap scratch for very long strings.
            const scratch = try self.heap.allocator.alloc(u8, text.len);
            defer self.heap.allocator.free(scratch);
            const out = unescapeString(text, scratch) catch return self.errAt(p, Error.BadToken);
            return try self.heap.allocString(out);
        }
        const out = unescapeString(text, &buf) catch return self.errAt(p, Error.BadToken);
        return try self.heap.allocString(out);
    }

    fn parseIntegerAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        const n = parseIntegerLexeme(text) catch return self.errAt(p, Error.BadToken);
        if (n < value.FIXNUM_MIN or n > value.FIXNUM_MAX) {
            // Bignums land in Phase 4. For now reject overflow loudly.
            return self.errAt(p, Error.BadToken);
        }
        return Value.fromFixnum(n);
    }

    fn parseRatioAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return self.errAt(p, Error.BadToken);
        const num = parseIntegerLexeme(text[0..slash]) catch return self.errAt(p, Error.BadToken);
        const den = parseIntegerLexeme(text[slash + 1 ..]) catch return self.errAt(p, Error.BadToken);
        if (den == 0) return self.errAt(p, Error.BadToken);
        return try self.heap.allocRatio(num, den);
    }

    fn parseFloatAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        const fv = float_parse.parseFloatLexeme(text) catch return self.errAt(p, Error.BadToken);
        return switch (fv) {
            .single => |x| try self.heap.allocSingleFloat(x),
            .double => |x| try self.heap.allocDoubleFloat(x),
        };
    }

    fn parseCharacterAt(self: *Reader, text: []const u8, p: Position) Error!Value {
        const cp = decodeCharLiteral(text) catch return self.errAt(p, Error.BadToken);
        return Value.fromChar(cp);
    }
};

// --- standard reader-macro handlers --------------------------------------
//
// Each takes the reader as `*anyopaque` (the `MacroHandler` signature) and
// casts back. Errors widen from `Error` to `readtable.HandlerError` —
// they share the same set, so the cast is a no-op.

fn handleQuote(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return ReadStep{ .value = try self.readMacroExpansion("QUOTE") };
}

fn handleBackquote(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return ReadStep{ .value = try self.readMacroExpansion("QUASIQUOTE") };
}

fn handleComma(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return ReadStep{ .value = try self.readMacroExpansion("UNQUOTE") };
}

fn handleCommaAt(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return ReadStep{ .value = try self.readMacroExpansion("UNQUOTE-SPLICING") };
}

fn handleHashQuote(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return ReadStep{ .value = try self.readMacroExpansion("FUNCTION") };
}

fn handleHashLparen(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return ReadStep{ .value = try self.readVector() };
}

fn handleHashPlus(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return self.readConditional(true);
}

fn handleHashMinus(ctx: *anyopaque) readtable_mod.HandlerError!ReadStep {
    const self: *Reader = @ptrCast(@alignCast(ctx));
    return self.readConditional(false);
}

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

fn stripLeadingColon(name_str: []const u8) []const u8 {
    if (name_str.len > 0 and name_str[0] == ':') return name_str[1..];
    return name_str;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
