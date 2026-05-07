//! ROADMAP Phase 1.2 reader tests.
//!
//! Each test sets up a fresh tokenizer, heap, and interner, reads one or
//! more forms, and asserts on the resulting `Value` structure (or on the
//! printer's round-trip output for cases where structural assertions
//! would be noisier than diff).

const std = @import("std");
const zisp = @import("zisp");

const value = zisp.value;
const heap = zisp.heap;
const symbol = zisp.symbol;
const printer = zisp.printer;
const Value = value.Value;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const ReaderError = zisp.reader.ReaderError;

/// Test setup is heap-allocated because the arena allocator and the heap
/// it backs both store pointers into the arena's state. A stack-allocated
/// `Setup` returned by value would invalidate those pointers when moved.
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

fn readOne(setup: *Setup, src: []const u8) !Value {
    var tk = Tokenizer.init(src);
    var rd = Reader.init(&tk, &setup.h, &setup.interner);
    const got = try rd.read();
    return got orelse error.UnexpectedEof;
}

fn expectPrints(allocator: std.mem.Allocator, v: Value, expected: []const u8) !void {
    const got = try printer.printToOwnedSlice(allocator, v);
    defer allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

// --- 1.2.1 / atoms -------------------------------------------------------

test "1.2.1 read positive integer" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "42");
    try std.testing.expect(v.isFixnum());
    try std.testing.expectEqual(@as(i64, 42), v.toFixnum());
}

test "1.2.1 read negative integer" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "-17");
    try std.testing.expectEqual(@as(i64, -17), v.toFixnum());
}

test "1.2.1 read radix integer #xff" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#xff");
    try std.testing.expectEqual(@as(i64, 255), v.toFixnum());
}

test "1.2.1 read explicit radix integer" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#16r1F");
    try std.testing.expectEqual(@as(i64, 31), v.toFixnum());
}

test "1.2.1 read symbol upcased" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "foo-bar");
    try std.testing.expect(v.isSymbol());
    try std.testing.expectEqualStrings("FOO-BAR", symbol.name(v));
}

test "1.2.1 read |escaped pipes| preserves case" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "|HiThere|");
    try std.testing.expectEqualStrings("HiThere", symbol.name(v));
}

test "1.2.1 same name interns to same symbol" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const a = try readOne(s, "foo");
    const b = try readOne(s, "FOO");
    try std.testing.expect(a.equalsRaw(b));
}

test "1.2.1 read string with escapes" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "\"hello \\\"world\\\"\"");
    try std.testing.expect(v.isHeap());
    const got = heap.asString(v).constSlice();
    try std.testing.expectEqualStrings("hello \"world\"", got);
}

test "1.2.1 read character literals" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const a = try readOne(s, "#\\a");
    try std.testing.expectEqual(@as(u21, 'a'), a.toChar());
    const sp = try readOne(s, "#\\Space");
    try std.testing.expectEqual(@as(u21, ' '), sp.toChar());
    const nl = try readOne(s, "#\\Newline");
    try std.testing.expectEqual(@as(u21, '\n'), nl.toChar());
    const u = try readOne(s, "#\\U+03BB");
    try std.testing.expectEqual(@as(u21, 0x03BB), u.toChar());
}

test "1.2.1 read float and ratio" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const f = try readOne(s, "1.5");
    try std.testing.expect(f.isHeap());
    try std.testing.expectEqual(heap.HeapType.single_float, heap.heapType(f));
    try std.testing.expectEqual(@as(f32, 1.5), heap.asSingleFloat(f).value);

    const d = try readOne(s, "2.5d0");
    try std.testing.expectEqual(heap.HeapType.double_float, heap.heapType(d));
    try std.testing.expectEqual(@as(f64, 2.5), heap.asDoubleFloat(d).value);

    const r = try readOne(s, "3/4");
    try std.testing.expectEqual(heap.HeapType.ratio, heap.heapType(r));
    const ratio = heap.asRatio(r);
    try std.testing.expectEqual(@as(i64, 3), ratio.numerator);
    try std.testing.expectEqual(@as(i64, 4), ratio.denominator);
}

test "1.2.1 read keyword stub" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, ":foo");
    try std.testing.expect(v.isSymbol());
    try std.testing.expectEqualStrings(":FOO", symbol.name(v));
}

// --- 1.2.2 / lists / dotted pairs ----------------------------------------

test "1.2.3 empty list reads as NIL" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "()");
    try std.testing.expect(v.equalsRaw(value.NIL));
}

test "1.2.2 proper list of three" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "(1 2 3)");
    try std.testing.expect(v.isCons());
    try std.testing.expectEqual(@as(i64, 1), heap.car(v).toFixnum());
    try std.testing.expectEqual(@as(i64, 2), heap.car(heap.cdr(v)).toFixnum());
    try std.testing.expectEqual(@as(i64, 3), heap.car(heap.cdr(heap.cdr(v))).toFixnum());
    try std.testing.expect(heap.cdr(heap.cdr(heap.cdr(v))).equalsRaw(value.NIL));
}

test "1.2.2 dotted pair" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "(1 . 2)");
    try std.testing.expect(v.isCons());
    try std.testing.expectEqual(@as(i64, 1), heap.car(v).toFixnum());
    try std.testing.expectEqual(@as(i64, 2), heap.cdr(v).toFixnum());
}

test "1.2.2 dotted tail in longer list" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "(1 2 . 3)");
    const tail = heap.cdr(heap.cdr(v));
    try std.testing.expectEqual(@as(i64, 3), tail.toFixnum());
}

test "1.2.2 nested lists" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "((a b) (c d))");
    const first = heap.car(v);
    try std.testing.expect(first.isCons());
    try std.testing.expectEqualStrings("A", symbol.name(heap.car(first)));
    try std.testing.expectEqualStrings("B", symbol.name(heap.car(heap.cdr(first))));
}

// --- 1.2.4–1.2.8 / reader macros ----------------------------------------

test "1.2.4 quote 'x → (QUOTE x)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "'foo");
    try std.testing.expect(v.isCons());
    try std.testing.expectEqualStrings("QUOTE", symbol.name(heap.car(v)));
    try std.testing.expectEqualStrings("FOO", symbol.name(heap.car(heap.cdr(v))));
    try std.testing.expect(heap.cdr(heap.cdr(v)).equalsRaw(value.NIL));
}

test "1.2.5 backquote `x → (QUASIQUOTE x)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "`foo");
    try std.testing.expectEqualStrings("QUASIQUOTE", symbol.name(heap.car(v)));
}

test "1.2.6 unquote ,x → (UNQUOTE x)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, ",foo");
    try std.testing.expectEqualStrings("UNQUOTE", symbol.name(heap.car(v)));
}

test "1.2.7 unquote-splicing ,@x → (UNQUOTE-SPLICING x)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, ",@foo");
    try std.testing.expectEqualStrings("UNQUOTE-SPLICING", symbol.name(heap.car(v)));
}

test "1.2.8 #'fn → (FUNCTION fn)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#'car");
    try std.testing.expectEqualStrings("FUNCTION", symbol.name(heap.car(v)));
    try std.testing.expectEqualStrings("CAR", symbol.name(heap.car(heap.cdr(v))));
}

test "1.2.5 nested backquote/unquote" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // `(a ,b ,@c)
    const v = try readOne(s, "`(a ,b ,@c)");
    try std.testing.expectEqualStrings("QUASIQUOTE", symbol.name(heap.car(v)));
    const inner = heap.car(heap.cdr(v));
    // inner = (A (UNQUOTE B) (UNQUOTE-SPLICING C))
    try std.testing.expectEqualStrings("A", symbol.name(heap.car(inner)));
    const second = heap.car(heap.cdr(inner));
    try std.testing.expectEqualStrings("UNQUOTE", symbol.name(heap.car(second)));
    const third = heap.car(heap.cdr(heap.cdr(inner)));
    try std.testing.expectEqualStrings("UNQUOTE-SPLICING", symbol.name(heap.car(third)));
}

// --- 1.2.9 / vectors ----------------------------------------------------

test "1.2.9 vector literal #(1 2 3)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#(1 2 3)");
    try std.testing.expect(v.isHeap());
    try std.testing.expectEqual(heap.HeapType.vector, heap.heapType(v));
    const items = heap.asVector(v).constSlice();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].toFixnum());
    try std.testing.expectEqual(@as(i64, 2), items[1].toFixnum());
    try std.testing.expectEqual(@as(i64, 3), items[2].toFixnum());
}

test "1.2.9 empty vector #()" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#()");
    try std.testing.expectEqual(@as(usize, 0), heap.asVector(v).len);
}

// --- 1.2.13 / errors ----------------------------------------------------

test "1.2.13 unbalanced rparen" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init(")");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.UnbalancedParens, rd.read());
}

test "1.2.13 EOF mid-list" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(1 2");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
}

test "1.2.13 dot at start of list is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(. 1)");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "1.2.13 empty stream returns null" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("   ;; just a comment\n");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const got = try rd.read();
    try std.testing.expect(got == null);
}

// --- multi-form streams --------------------------------------------------

test "read multiple forms in sequence" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("1 2 3");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const a = (try rd.read()).?;
    const b = (try rd.read()).?;
    const c = (try rd.read()).?;
    try std.testing.expectEqual(@as(i64, 1), a.toFixnum());
    try std.testing.expectEqual(@as(i64, 2), b.toFixnum());
    try std.testing.expectEqual(@as(i64, 3), c.toFixnum());
    try std.testing.expect((try rd.read()) == null);
}

// --- printer round-trip --------------------------------------------------

test "print( read('(1 . 2)) ) round-trips" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "(1 . 2)");
    try expectPrints(s.allocator, v, "(1 . 2)");
}

test "print( read('(1 2 3)) ) round-trips" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "(1 2 3)");
    try expectPrints(s.allocator, v, "(1 2 3)");
}

test "print( read('quote-form) ) round-trips structurally" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "'foo");
    try expectPrints(s.allocator, v, "(QUOTE FOO)");
}

// --- 1.2.11 / readtable dispatch ----------------------------------------

const Readtable = zisp.reader.Readtable;
const TokenKind = zisp.reader.TokenKind;
const PositionTable = zisp.source_pos.PositionTable;

/// Stub handler used by the override test. Returns a fresh symbol so the
/// test can detect that the override fired instead of the built-in.
fn overrideQuoteHandler(ctx: *anyopaque) zisp.reader.readtable.HandlerError!zisp.reader.readtable.ReadStep {
    const Reader2 = zisp.reader.Reader;
    const r: *Reader2 = @ptrCast(@alignCast(ctx));
    // Consume the next form so the stream stays balanced, then return a
    // sentinel symbol the test can identify.
    _ = r.read() catch null;
    const sym = try r.interner.intern("OVERRIDDEN-QUOTE");
    return .{ .value = sym };
}

test "1.2.11 dispatch goes through the readtable" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var rt = Readtable.initStandard(.{
        .quote = overrideQuoteHandler,
        .backquote = overrideQuoteHandler,
        .comma = overrideQuoteHandler,
        .comma_at = overrideQuoteHandler,
        .hash_quote = overrideQuoteHandler,
        .hash_lparen = overrideQuoteHandler,
        .hash_plus = overrideQuoteHandler,
        .hash_minus = overrideQuoteHandler,
    });
    var tk = Tokenizer.init("'foo");
    var rd = zisp.reader.Reader.initFull(&tk, &s.h, &s.interner, &rt, null, "");
    const v = (try rd.read()).?;
    try std.testing.expect(v.isSymbol());
    try std.testing.expectEqualStrings("OVERRIDDEN-QUOTE", symbol.name(v));
}

test "1.2.11 standard readtable still serves built-ins after override test" {
    // Sanity check: each test gets its own readtable, so the previous
    // override didn't leak into the global.
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "'bar");
    try std.testing.expectEqualStrings("QUOTE", symbol.name(heap.car(v)));
}

// --- 1.2.12 / source positions on cons cells ----------------------------

test "1.2.12 records position for the head cons of a list" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var positions = PositionTable.init(s.allocator);
    defer positions.deinit();

    var tk = Tokenizer.init("(1 2 3)");
    var rd = zisp.reader.Reader.initFull(
        &tk,
        &s.h,
        &s.interner,
        zisp.reader.reader.defaultReadtable(),
        &positions,
        "test.lisp",
    );
    const v = (try rd.read()).?;
    try std.testing.expect(v.isCons());
    const pos = positions.lookup(v) orelse return error.NoPositionRecorded;
    try std.testing.expectEqualStrings("test.lisp", pos.file);
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 1), pos.column);
}

test "1.2.12 second-line list gets line=2" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var positions = PositionTable.init(s.allocator);
    defer positions.deinit();
    var tk = Tokenizer.init("\n  (foo)");
    var rd = zisp.reader.Reader.initFull(
        &tk,
        &s.h,
        &s.interner,
        zisp.reader.reader.defaultReadtable(),
        &positions,
        "src.lisp",
    );
    const v = (try rd.read()).?;
    const pos = positions.lookup(v).?;
    try std.testing.expectEqual(@as(u32, 2), pos.line);
    try std.testing.expectEqual(@as(u32, 3), pos.column);
}

test "1.2.12 every cons cell in a 3-element list has a position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var positions = PositionTable.init(s.allocator);
    defer positions.deinit();
    var tk = Tokenizer.init("(a b c)");
    var rd = zisp.reader.Reader.initFull(
        &tk,
        &s.h,
        &s.interner,
        zisp.reader.reader.defaultReadtable(),
        &positions,
        "f.lisp",
    );
    const v = (try rd.read()).?;
    var cur = v;
    var seen: u32 = 0;
    while (cur.isCons()) : (cur = heap.cdr(cur)) {
        try std.testing.expect(positions.lookup(cur) != null);
        seen += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), seen);
}

test "1.2.12 reader without position table records nothing" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "(1 2)");
    var empty = PositionTable.init(s.allocator);
    defer empty.deinit();
    try std.testing.expect(empty.lookup(v) == null);
    try std.testing.expectEqual(@as(u32, 0), empty.count());
}

// --- coverage: atom edge cases ------------------------------------------

test "read #b binary integer" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#b1010");
    try std.testing.expectEqual(@as(i64, 10), v.toFixnum());
}

test "read #o octal integer" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "#o755");
    try std.testing.expectEqual(@as(i64, 493), v.toFixnum());
}

test "read pipe-quoted symbol with escaped pipe inside" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "|a\\|b|");
    try std.testing.expectEqualStrings("a|b", symbol.name(v));
}

test "read symbol with bare backslash escape preserves case" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "f\\oo");
    // The backslash escapes a single character so its case is preserved.
    // Surrounding chars still upcase, so `f\oo` → `FoO`.
    try std.testing.expectEqualStrings("FoO", symbol.name(v));
}

test "read multi-byte UTF-8 character literal" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // U+03BB GREEK SMALL LETTER LAMDA: two bytes (0xCE 0xBB).
    const v = try readOne(s, "#\\\xCE\xBB");
    try std.testing.expectEqual(@as(u21, 0x03BB), v.toChar());
}

test "read string longer than the on-stack buffer" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // The reader keeps a 4096-byte stack buffer; anything longer hits the
    // heap-scratch fallback. Build "\"<5000 a's>\"".
    const big_n = 5000;
    var buf = try s.allocator.alloc(u8, big_n + 2);
    defer s.allocator.free(buf);
    buf[0] = '"';
    @memset(buf[1 .. 1 + big_n], 'a');
    buf[buf.len - 1] = '"';
    var tk = Tokenizer.init(buf);
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const v = (try rd.read()).?;
    try std.testing.expect(v.isHeap());
    const got = heap.asString(v).constSlice();
    try std.testing.expectEqual(@as(usize, big_n), got.len);
    try std.testing.expectEqual(@as(u8, 'a'), got[0]);
    try std.testing.expectEqual(@as(u8, 'a'), got[big_n - 1]);
}

// --- coverage: error paths ----------------------------------------------

test "top-level dot is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init(".");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "1.2.10 #+ with absent feature skips form" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // No features configured → `foo` is absent → discard `bar` → return `baz`.
    var tk = Tokenizer.init("#+foo bar baz");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const v = (try rd.read()).?;
    try std.testing.expectEqualStrings("BAZ", symbol.name(v));
}

test "1.2.10 #- with absent feature keeps form" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // No features → `foo` absent → `#-foo bar` keeps `bar`.
    var tk = Tokenizer.init("#-foo bar");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const v = (try rd.read()).?;
    try std.testing.expectEqualStrings("BAR", symbol.name(v));
}

test "vector with EOF mid-read is EndOfInput" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#(1 2");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
}

test "vector with dotted pair is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#(1 . 2)");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "tokenizer error at top level surfaces as BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#$");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "unterminated string at top level surfaces as EndOfInput" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("\"unterminated");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
}

test "tokenizer error inside list (peek path) surfaces as BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(#$)");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

test "unterminated string inside list (peek path) surfaces as EndOfInput" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(\"unterminated");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
}

test "EOF after quote surfaces EndOfInput (covers .eof switch arm)" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("'");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
}

test "unknown character literal name is BadToken" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#\\BogusName");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}

// --- 1.4.2 / reader errors carry source position ------------------------

test "1.4.2 unbalanced rparen carries position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("\n  )");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.UnbalancedParens, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 2), pos.line);
    try std.testing.expectEqual(@as(u32, 3), pos.column);
}

test "1.4.2 EOF mid-list reports lparen position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(1 2");
    var rd = zisp.reader.Reader.initFull(
        &tk,
        &s.h,
        &s.interner,
        zisp.reader.reader.defaultReadtable(),
        null,
        "src.lisp",
    );
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqualStrings("src.lisp", pos.file);
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 1), pos.column);
}

test "1.4.2 dot at start of list points at the dot" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(  . 1)");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 4), pos.column);
}

test "1.4.2 dotted-pair without closer points at the offending token" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("(1 . 2 3)");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    // The closer-position is the `3` token (column 8 in `(1 . 2 3)`).
    try std.testing.expectEqual(@as(u32, 8), pos.column);
}

test "1.4.2 vector EOF reports the EOF position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#(1 2");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.EndOfInput, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 1), pos.line);
}

test "1.4.2 vector dot reports the dot position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#(1 . 2)");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 5), pos.column);
}

test "1.4.2 tokenizer error captures pre-token position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("  #$");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    // tokenizer.pos() returns the position of the next byte; we capture
    // it before calling next(), which sits at the `#`.
    try std.testing.expectEqual(@as(u32, 3), pos.column);
}

test "1.4.2 last_error_pos resets on subsequent successful read" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init(") 42");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.UnbalancedParens, rd.read());
    try std.testing.expect(rd.lastErrorPos() != null);
    const v = (try rd.read()).?;
    try std.testing.expectEqual(@as(i64, 42), v.toFixnum());
    try std.testing.expect(rd.lastErrorPos() == null);
}

test "1.4.2 unknown character literal carries token position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("  #\\BogusName");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 3), pos.column);
}

test "1.4.2 integer that overflows fixnum but fits i64 carries position" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // FIXNUM_MAX is 2^60 - 1; 2^60 = 1152921504606846976 still fits i64.
    var tk = Tokenizer.init("  1152921504606846976");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    const pos = rd.lastErrorPos() orelse return error.NoPositionRecorded;
    try std.testing.expectEqual(@as(u32, 3), pos.column);
}

test "1.4.2 fallback captures position when deeper site didn't stamp" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // (xor a b) as a feature expression hits evalFeatureExpr's BadToken
    // path, which doesn't stamp directly. The public read wrapper must
    // fall back to the tokenizer's current position.
    var tk = Tokenizer.init("#+(xor a) :form");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    try std.testing.expectError(ReaderError.BadToken, rd.read());
    try std.testing.expect(rd.lastErrorPos() != null);
}

test "readtable with nulled handler surfaces BadToken on macro char" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    // Empty readtable: every reader-macro-token kind dispatches to null,
    // so the reader falls through to the explicit BadToken arm.
    var rt = Readtable.init();
    var tk = Tokenizer.init("'foo");
    var rd = zisp.reader.Reader.initFull(&tk, &s.h, &s.interner, &rt, null, "");
    try std.testing.expectError(ReaderError.BadToken, rd.read());
}
