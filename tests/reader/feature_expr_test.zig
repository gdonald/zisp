//! Feature-expression (#+/#-) acceptance tests.
//!
//! Reads `tests/lisp/feature-expr-corpus.lisp` and, for each line, sets
//! up a reader with the given feature set, parses the feature expression
//! through `Reader.evalFeatureExpr`, and confirms the truth value matches
//! what SBCL would compute given the same `*features*`.
//!
//! Then exercises the conditional reader-macro path itself (`#+` / `#-`)
//! to verify keep-vs-skip behavior at top level, in lists, in vectors,
//! and in interaction with quote-like reader macros.

const std = @import("std");
const zisp = @import("zisp");

const value = zisp.value;
const heap = zisp.heap;
const symbol = zisp.symbol;
const Value = value.Value;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const ReaderError = zisp.reader.ReaderError;

const corpus_text = @embedFile("../lisp/feature-expr-corpus.lisp");

const Setup = struct {
    arena: std.heap.ArenaAllocator,
    h: heap.Heap,
    interner: symbol.Interner,
    allocator: std.mem.Allocator,

    fn deinit(self: *Setup) void {
        self.interner.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

fn newSetup(test_allocator: std.mem.Allocator) !*Setup {
    const s = try test_allocator.create(Setup);
    s.* = .{
        .arena = std.heap.ArenaAllocator.init(test_allocator),
        .h = undefined,
        .interner = symbol.Interner.init(test_allocator),
        .allocator = test_allocator,
    };
    s.h = heap.Heap.init(s.arena.allocator());
    try symbol.initStandardSymbols(&s.interner);
    return s;
}

/// Intern each comma-separated `:NAME` token from `csv` as a symbol and
/// collect the resulting `Value`s in `out`. Returns the populated slice.
fn buildFeatures(out: *std.ArrayList(Value), interner: *symbol.Interner, allocator: std.mem.Allocator, csv: []const u8) ![]Value {
    var iter = std.mem.tokenizeScalar(u8, csv, ',');
    while (iter.next()) |raw| {
        // The corpus always begins each token with `:`; intern verbatim
        // so the keyword stub layout (`:FOO`) is preserved.
        const sym = try interner.intern(raw);
        try out.append(allocator, sym);
    }
    return out.items;
}

const Entry = struct {
    expected: bool,
    features_csv: []const u8,
    expr: []const u8,
    line_no: u32,
};

const ParseError = error{MalformedCorpusLine};

fn parseLine(line: []const u8, line_no: u32) !?Entry {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == line.len) return null; // blank
    if (line[i] == ';') return null; // comment

    const trimmed = line[i..];
    // <expected> <features-csv> <expr>
    const sp1 = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return ParseError.MalformedCorpusLine;
    const expected_str = trimmed[0..sp1];
    const rest1 = trimmed[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest1, ' ') orelse return ParseError.MalformedCorpusLine;
    const features_csv = rest1[0..sp2];
    const expr = rest1[sp2 + 1 ..];

    const expected: bool = if (std.mem.eql(u8, expected_str, "TRUE"))
        true
    else if (std.mem.eql(u8, expected_str, "FALSE"))
        false
    else
        return ParseError.MalformedCorpusLine;

    return .{
        .expected = expected,
        .features_csv = features_csv,
        .expr = expr,
        .line_no = line_no,
    };
}

test "feature expression corpus matches expected truth values" {
    var iter = std.mem.splitScalar(u8, corpus_text, '\n');
    var line_no: u32 = 0;
    var entries: u32 = 0;
    var depth_ge_4: u32 = 0;
    var mixed: u32 = 0;

    while (iter.next()) |line| {
        line_no += 1;
        const entry = (parseLine(line, line_no) catch |e| {
            std.debug.print(
                "corpus line {d} malformed: {s}\n  >> {s}\n",
                .{ line_no, @errorName(e), line },
            );
            return e;
        }) orelse continue;

        const s = try newSetup(std.testing.allocator);
        defer s.deinit();

        var features_buf: std.ArrayList(Value) = .empty;
        defer features_buf.deinit(s.allocator);
        const features = try buildFeatures(&features_buf, &s.interner, s.allocator, entry.features_csv);

        var tk = Tokenizer.init(entry.expr);
        var rd = Reader.init(&tk, &s.h, &s.interner);
        rd.setFeatures(features);

        const expr_v = (try rd.read()) orelse {
            std.debug.print("line {d}: empty parse for `{s}`\n", .{ entry.line_no, entry.expr });
            return error.TestFailed;
        };
        const got = rd.evalFeatureExpr(expr_v) catch |e| {
            std.debug.print(
                "line {d}: evalFeatureExpr({s}) failed: {s}\n",
                .{ entry.line_no, entry.expr, @errorName(e) },
            );
            return e;
        };

        if (got != entry.expected) {
            std.debug.print(
                "line {d}: {s} (features {s}): expected {s}, got {s}\n",
                .{
                    entry.line_no,
                    entry.expr,
                    entry.features_csv,
                    if (entry.expected) "TRUE" else "FALSE",
                    if (got) "TRUE" else "FALSE",
                },
            );
            return error.TestFailed;
        }

        if (lexicalDepth(entry.expr) >= 4) depth_ge_4 += 1;
        if (mixesOps(entry.expr)) mixed += 1;
        entries += 1;
    }

    if (entries < 30) {
        std.debug.print("corpus contained only {d} entries; need >=30\n", .{entries});
        return error.TestFailed;
    }
    if (depth_ge_4 < 10) {
        std.debug.print("only {d} entries had depth >=4; need >=10\n", .{depth_ge_4});
        return error.TestFailed;
    }
    if (mixed < 5) {
        std.debug.print("only {d} entries mixed and/or/not; need >=5\n", .{mixed});
        return error.TestFailed;
    }
}

/// Maximum paren-nesting depth of `text`, ignoring string content (we
/// don't have any in the corpus). A single bare symbol counts as 0.
fn lexicalDepth(text: []const u8) u32 {
    var depth: u32 = 0;
    var max: u32 = 0;
    for (text) |c| {
        if (c == '(') {
            depth += 1;
            if (depth > max) max = depth;
        } else if (c == ')') {
            if (depth > 0) depth -= 1;
        }
    }
    return max;
}

/// True if `text` contains at least two of `and`, `or`, `not` as bare
/// tokens (letter-bounded). Approximate but sufficient for the corpus
/// shape — every operator token is surrounded by `(` or whitespace.
fn mixesOps(text: []const u8) bool {
    var saw_and = false;
    var saw_or = false;
    var saw_not = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i > 0 and isWordChar(text[i - 1])) continue;
        if (matchKeyword(text, i, "and") and (i + 3 == text.len or !isWordChar(text[i + 3]))) {
            saw_and = true;
            i += 2;
        } else if (matchKeyword(text, i, "or") and (i + 2 == text.len or !isWordChar(text[i + 2]))) {
            saw_or = true;
            i += 1;
        } else if (matchKeyword(text, i, "not") and (i + 3 == text.len or !isWordChar(text[i + 3]))) {
            saw_not = true;
            i += 2;
        }
    }
    var count: u32 = 0;
    if (saw_and) count += 1;
    if (saw_or) count += 1;
    if (saw_not) count += 1;
    return count >= 2;
}

fn matchKeyword(text: []const u8, start: usize, kw: []const u8) bool {
    if (start + kw.len > text.len) return false;
    return std.ascii.eqlIgnoreCase(text[start .. start + kw.len], kw);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

// --- direct reader tests for #+ / #- ------------------------------------

fn readWithFeatures(s: *Setup, features: []const Value, src: []const u8) !?Value {
    var tk = Tokenizer.init(src);
    var rd = Reader.init(&tk, &s.h, &s.interner);
    rd.setFeatures(features);
    return try rd.read();
}

test "#+ keeps form when feature is present" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const sbcl = try s.interner.intern(":SBCL");
    const features = [_]Value{sbcl};
    const v = (try readWithFeatures(s, &features, "#+sbcl :yes :nope")).?;
    try std.testing.expectEqualStrings(":YES", symbol.name(v));
}

test "#- discards form when feature is present" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const sbcl = try s.interner.intern(":SBCL");
    const features = [_]Value{sbcl};
    const v = (try readWithFeatures(s, &features, "#-sbcl :no :ok")).?;
    try std.testing.expectEqualStrings(":OK", symbol.name(v));
}

test "#+ inside list elides element when feature absent" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = (try readWithFeatures(s, &.{}, "(a #+nope b c)")).?;
    // (A C)
    try std.testing.expect(v.isCons());
    try std.testing.expectEqualStrings("A", symbol.name(heap.car(v)));
    try std.testing.expectEqualStrings("C", symbol.name(heap.car(heap.cdr(v))));
    try std.testing.expect(heap.cdr(heap.cdr(v)).equalsRaw(value.NIL));
}

test "#+ at end of list before close paren elides cleanly" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = (try readWithFeatures(s, &.{}, "(a b #+nope skipped)")).?;
    try std.testing.expect(v.isCons());
    try std.testing.expectEqualStrings("A", symbol.name(heap.car(v)));
    try std.testing.expectEqualStrings("B", symbol.name(heap.car(heap.cdr(v))));
    try std.testing.expect(heap.cdr(heap.cdr(v)).equalsRaw(value.NIL));
}

test "#+ inside vector elides element when feature absent" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = (try readWithFeatures(s, &.{}, "#(1 #+nope 2 3)")).?;
    const items = heap.asVector(v).constSlice();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].toFixnum());
    try std.testing.expectEqual(@as(i64, 3), items[1].toFixnum());
}

test "#+ inside vector keeps element when feature present" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const sbcl = try s.interner.intern(":SBCL");
    const features = [_]Value{sbcl};
    const v = (try readWithFeatures(s, &features, "#(1 #+sbcl 2 3)")).?;
    const items = heap.asVector(v).constSlice();
    try std.testing.expectEqual(@as(usize, 3), items.len);
}

test "nested #+#+ requires both features" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const a = try s.interner.intern(":A");
    const b = try s.interner.intern(":B");
    const both = [_]Value{ a, b };
    const v = (try readWithFeatures(s, &both, "#+a #+b :both :fallback")).?;
    try std.testing.expectEqualStrings(":BOTH", symbol.name(v));

    const only_a = [_]Value{a};
    const v2 = (try readWithFeatures(s, &only_a, "#+a #+b :both :fallback")).?;
    try std.testing.expectEqualStrings(":FALLBACK", symbol.name(v2));
}

test "#+ feature expr (or ...) " {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const ccl = try s.interner.intern(":CCL");
    const features = [_]Value{ccl};
    const v = (try readWithFeatures(s, &features, "#+(or sbcl ccl) :picked :rejected")).?;
    try std.testing.expectEqualStrings(":PICKED", symbol.name(v));
}

test "#+ feature expr (and (not ...)) " {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const sbcl = try s.interner.intern(":SBCL");
    const features = [_]Value{sbcl};
    // (and sbcl (not aix)) → TRUE → keep yes
    const v = (try readWithFeatures(s, &features, "#+(and sbcl (not aix)) :yes :no")).?;
    try std.testing.expectEqualStrings(":YES", symbol.name(v));
}

test "#+ all-skipped at top level returns null" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#+nope only-form");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const v = try rd.read();
    try std.testing.expect(v == null);
}

test "EOF after #+ feature expr is EndOfInput" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#+sbcl");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
}

test "#+ with bad feature expression shape is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // 42 is neither a symbol nor a list.
    var tk = Tokenizer.init("#+42 :yes");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "#+ with unknown operator is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#+(xor a b) :yes");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "(not ...) requires exactly one operand" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#+(not) :yes");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());

    var tk2 = Tokenizer.init("#+(not a b) :yes");
    var rd2 = Reader.init(&tk2, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd2.read());
}

test "feature expr with non-symbol head is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#+(1 2 3) :yes");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "dotted feature expression is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#+(or sbcl . ccl) :yes");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "features compare case-sensitively after stripping colon" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // Plain `sbcl` in expr → SBCL after upcase. Feature `:SBCL` strips
    // colon → "SBCL". Match.
    const sbcl = try s.interner.intern(":SBCL");
    const features = [_]Value{sbcl};
    const v = (try readWithFeatures(s, &features, "#+sbcl :yes :no")).?;
    try std.testing.expectEqualStrings(":YES", symbol.name(v));
}

test "non-symbol value in features list is ignored" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // A fixnum in the features list would be ignored — only symbol
    // entries can match. Regression guard for the `if (!f.isSymbol())`
    // skip in `hasFeature`.
    const features = [_]Value{Value.fromFixnum(1)};
    var tk = Tokenizer.init("#+sbcl :yes :no");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    rd.setFeatures(&features);
    const v = (try rd.read()).?;
    try std.testing.expectEqualStrings(":NO", symbol.name(v));
}
