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
