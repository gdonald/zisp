const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const heap = zisp.heap;
const symbol = zisp.symbol;
const printer = zisp.printer;
const Value = value.Value;
const Heap = heap.Heap;
const Interner = symbol.Interner;

fn fmtValue(allocator: std.mem.Allocator, v: Value) ![]u8 {
    return printer.printToOwnedSlice(allocator, v);
}

test "print fixnum" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromFixnum(42));
    defer a.free(s);
    try std.testing.expectEqualStrings("42", s);
}

test "print negative fixnum" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromFixnum(-7));
    defer a.free(s);
    try std.testing.expectEqualStrings("-7", s);
}

test "print NIL" {
    const a = std.testing.allocator;
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    const s = try fmtValue(a, value.NIL);
    defer a.free(s);
    try std.testing.expectEqualStrings("NIL", s);
}

test "print T" {
    const a = std.testing.allocator;
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    const s = try fmtValue(a, value.T);
    defer a.free(s);
    try std.testing.expectEqualStrings("T", s);
}

test "print symbol" {
    const a = std.testing.allocator;
    var interner = Interner.init(a);
    defer interner.deinit();

    const sym = try interner.intern("FOO");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("FOO", s);
}

test "print proper list (1 2 3)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var h = Heap.init(arena.allocator());
    const list = try h.allocCons(
        Value.fromFixnum(1),
        try h.allocCons(
            Value.fromFixnum(2),
            try h.allocCons(Value.fromFixnum(3), value.NIL),
        ),
    );

    const s = try fmtValue(a, list);
    defer a.free(s);
    try std.testing.expectEqualStrings("(1 2 3)", s);
}

test "print dotted pair (1 . 2)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var h = Heap.init(arena.allocator());
    const pair = try h.allocCons(Value.fromFixnum(1), Value.fromFixnum(2));

    const s = try fmtValue(a, pair);
    defer a.free(s);
    try std.testing.expectEqualStrings("(1 . 2)", s);
}

test "print nested list (1 (2 3) 4)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var h = Heap.init(arena.allocator());
    const inner = try h.allocCons(
        Value.fromFixnum(2),
        try h.allocCons(Value.fromFixnum(3), value.NIL),
    );
    const outer = try h.allocCons(
        Value.fromFixnum(1),
        try h.allocCons(inner, try h.allocCons(Value.fromFixnum(4), value.NIL)),
    );

    const s = try fmtValue(a, outer);
    defer a.free(s);
    try std.testing.expectEqualStrings("(1 (2 3) 4)", s);
}

test "print character ascii" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromChar('A'));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\A", s);
}

test "print character named" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromChar(' '));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\Space", s);
}

test "print character newline" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromChar('\n'));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\Newline", s);
}

test "print special unbound" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, value.SPECIAL_UNBOUND);
    defer a.free(s);
    try std.testing.expectEqualStrings("#<unbound>", s);
}

test "print is cycle-safe" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var h = Heap.init(arena.allocator());
    // Build (1 . X) and patch X to point at the cell itself.
    const cell = try h.allocCons(Value.fromFixnum(1), value.NIL);
    heap.setCdr(cell, cell);

    const s = try fmtValue(a, cell);
    defer a.free(s);
    // Output should not loop forever; expect cycle marker.
    try std.testing.expect(std.mem.indexOf(u8, s, "cycle") != null);
}

test "print is cycle-safe when a cons appears in its own car" {
    // Hits the top-of-printCons cycle check (recursive entry with the cons
    // already in `seen`), distinct from the in-loop cycle check the
    // self-cdr test above exercises.
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var h = Heap.init(arena.allocator());
    const cell = try h.allocCons(value.NIL, value.NIL);
    heap.setCar(cell, cell);

    const s = try fmtValue(a, cell);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "cycle") != null);
}

test "print emits #<deep> when nesting exceeds MAX_DEPTH" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var interner = Interner.init(a);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var h = Heap.init(arena.allocator());
    // 1025 levels of car-nesting: ((...(NIL)...)) — depth grows by one per
    // level when printValue recurses into each car. MAX_DEPTH is 1024.
    var inner = value.NIL;
    var i: usize = 0;
    while (i < 1025) : (i += 1) {
        inner = try h.allocCons(inner, value.NIL);
    }

    const s = try fmtValue(a, inner);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "#<deep>") != null);
}

test "print string heap object" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocString("hi");
    const s = try fmtValue(a, v);
    defer a.free(s);
    try std.testing.expectEqualStrings("\"hi\"", s);
}

test "print vector heap object" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocVector(&[_]Value{ Value.fromFixnum(1), Value.fromFixnum(2) });
    const s = try fmtValue(a, v);
    defer a.free(s);
    try std.testing.expectEqualStrings("#(1 2)", s);
}

test "print single-float emits scientific notation" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocSingleFloat(1.5);
    const s = try fmtValue(a, v);
    defer a.free(s);
    // Phase-0 printer uses Zig's `{e}` formatter; we just check that the
    // mantissa lands and an exponent marker shows up.
    try std.testing.expect(std.mem.indexOf(u8, s, "1.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "e") != null);
}

test "print double-float emits d0 suffix" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocDoubleFloat(2.5);
    const s = try fmtValue(a, v);
    defer a.free(s);
    try std.testing.expect(std.mem.endsWith(u8, s, "d0"));
    try std.testing.expect(std.mem.indexOf(u8, s, "2.5") != null);
}

test "print ratio emits num/den" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocRatio(3, 4);
    const s = try fmtValue(a, v);
    defer a.free(s);
    try std.testing.expectEqualStrings("3/4", s);
}

test "print character tab" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromChar('\t'));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\Tab", s);
}

test "print character return" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromChar('\r'));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\Return", s);
}

test "print character null" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromChar(0));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\Null", s);
}

test "print non-ASCII character emits UTF-8" {
    const a = std.testing.allocator;
    // U+03BB GREEK SMALL LETTER LAMDA — two-byte UTF-8 (0xCE 0xBB).
    const s = try fmtValue(a, Value.fromChar(0x03BB));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\\u{03BB}", s);
}

test "print invalid codepoint falls back to U+ form" {
    const a = std.testing.allocator;
    // 0x110000 is past Unicode's max (0x10FFFF) but fits in u21.
    // utf8Encode rejects it; the printer must take the U+ fallback.
    const s = try fmtValue(a, Value.fromChar(0x110000));
    defer a.free(s);
    try std.testing.expectEqualStrings("#\\U+110000", s);
}

test "print special eof" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, value.SPECIAL_EOF);
    defer a.free(s);
    try std.testing.expectEqualStrings("#<eof>", s);
}

test "print unknown special index" {
    const a = std.testing.allocator;
    const s = try fmtValue(a, Value.fromSpecial(42));
    defer a.free(s);
    try std.testing.expectEqualStrings("#<special:42>", s);
}

// --- prin1 / princ / print ----------------------

fn princOwned(allocator: std.mem.Allocator, v: Value) ![]u8 {
    return printer.princToOwnedSlice(allocator, v);
}

fn writeOwned(allocator: std.mem.Allocator, v: Value, settings: printer.Settings) ![]u8 {
    return printer.writeToOwnedSlice(allocator, v, settings);
}

test "prin1 string keeps quotes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocString("hi");
    const s = try fmtValue(a, v);
    defer a.free(s);
    try std.testing.expectEqualStrings("\"hi\"", s);
}

test "princ string drops quotes and escapes" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    // The backslash and quote inside the string should appear literally
    // under princ — no escaping, no surrounding quotes.
    const v = try h.allocString("he said \"hi\"\\bye");
    const s = try princOwned(a, v);
    defer a.free(s);
    try std.testing.expectEqualStrings("he said \"hi\"\\bye", s);
}

test "princ character writes the char itself" {
    const a = std.testing.allocator;
    const s = try princOwned(a, Value.fromChar('A'));
    defer a.free(s);
    try std.testing.expectEqualStrings("A", s);
}

test "princ space character is a literal space" {
    const a = std.testing.allocator;
    const s = try princOwned(a, Value.fromChar(' '));
    defer a.free(s);
    try std.testing.expectEqualStrings(" ", s);
}

test "princ non-ascii character emits UTF-8" {
    const a = std.testing.allocator;
    const s = try princOwned(a, Value.fromChar(0x03BB));
    defer a.free(s);
    try std.testing.expectEqualStrings("\u{03BB}", s);
}

test "princ invalid codepoint falls back to U+ form" {
    const a = std.testing.allocator;
    const s = try princOwned(a, Value.fromChar(0x110000));
    defer a.free(s);
    try std.testing.expectEqualStrings("U+110000", s);
}

test "print emits newline-prin1-space" {
    const a = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try printer.print(a, &aw.writer, Value.fromFixnum(7));
    try std.testing.expectEqualStrings("\n7 ", aw.written());
}

// --- base / radix / readably / escape ---------------------------

test "base 2 integer" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(10), .{ .base = 2 });
    defer a.free(s);
    try std.testing.expectEqualStrings("1010", s);
}

test "base 16 integer with radix prefix" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(255), .{ .base = 16, .radix = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("#xFF", s);
}

test "base 8 integer with radix prefix" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(8), .{ .base = 8, .radix = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("#o10", s);
}

test "base 2 integer with radix prefix" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(5), .{ .base = 2, .radix = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("#b101", s);
}

test "base 10 integer with radix gets trailing dot" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(42), .{ .base = 10, .radix = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("42.", s);
}

test "explicit nnR radix prefix" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(31), .{ .base = 36, .radix = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("#36rV", s);
}

test "negative integer in base 16" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(-255), .{ .base = 16 });
    defer a.free(s);
    try std.testing.expectEqualStrings("-FF", s);
}

test "zero in base 2" {
    const a = std.testing.allocator;
    const s = try writeOwned(a, Value.fromFixnum(0), .{ .base = 2 });
    defer a.free(s);
    try std.testing.expectEqualStrings("0", s);
}

test "base out-of-range clamps high" {
    const a = std.testing.allocator;
    // base=99 clamps to 36; same as the 36-base case.
    const s = try writeOwned(a, Value.fromFixnum(35), .{ .base = 99 });
    defer a.free(s);
    try std.testing.expectEqualStrings("Z", s);
}

test "base out-of-range clamps low" {
    const a = std.testing.allocator;
    // base=0 clamps to 2.
    const s = try writeOwned(a, Value.fromFixnum(3), .{ .base = 0 });
    defer a.free(s);
    try std.testing.expectEqualStrings("11", s);
}

test "fixnum minimum survives base conversion" {
    const a = std.testing.allocator;
    // FIXNUM_MIN is -2^60 — make sure unsigned-conversion path doesn't
    // overflow.
    const s = try writeOwned(a, Value.fromFixnum(value.FIXNUM_MIN), .{ .base = 16 });
    defer a.free(s);
    try std.testing.expectEqualStrings("-1000000000000000", s);
}

test "ratio respects base/radix" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocRatio(15, 16);
    const s = try writeOwned(a, v, .{ .base = 16, .radix = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("#xF/10", s);
}

test "readably forces escape even when escape=false" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());
    const v = try h.allocString("hi");
    const s = try writeOwned(a, v, .{ .escape = false, .readably = true });
    defer a.free(s);
    try std.testing.expectEqualStrings("\"hi\"", s);
}

// --- symbol escape rules for round-trip ------------------------

test "prin1 escapes lowercase symbol" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("HiThere");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|HiThere|", s);
}

test "prin1 escapes symbol with embedded pipe" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("a|b");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|a\\|b|", s);
}

test "prin1 escapes symbol that starts with digit" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("1A");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|1A|", s);
}

test "prin1 escapes symbol with sign-then-digit" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("+1");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|+1|", s);
}

test "prin1 leaves bare uppercase symbol unescaped" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("FOO-BAR");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("FOO-BAR", s);
}

test "prin1 leaves keyword symbol unescaped" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern(":KEY");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings(":KEY", s);
}

test "prin1 leaves bare + symbol unescaped" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("+");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("+", s);
}

test "prin1 escapes empty symbol name" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("||", s);
}

test "prin1 escapes symbol with whitespace inside" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("HAS SPACE");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|HAS SPACE|", s);
}

test "prin1 escapes symbol with embedded backslash" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("a\\b");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|a\\\\b|", s);
}

test "princ does not escape lowercase symbol" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern("HiThere");
    const s = try princOwned(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("HiThere", s);
}

test "prin1 leaves dot-prefixed name unescaped" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern(".FOO");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings(".FOO", s);
}

test "prin1 escapes name that starts with .digit" {
    const a = std.testing.allocator;
    var interner = symbol.Interner.init(a);
    defer interner.deinit();
    const sym = try interner.intern(".5A");
    const s = try fmtValue(a, sym);
    defer a.free(s);
    try std.testing.expectEqualStrings("|.5A|", s);
}
