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

test "print heap-tagged value emits #<heap-object ...>" {
    const a = std.testing.allocator;
    // The printer doesn't dereference the heap pointer for Phase 0 — it just
    // formats the address. Any 8-byte-aligned dummy works.
    var dummy: u64 align(8) = 0;
    const v = Value.fromHeapAddr(@intFromPtr(&dummy));
    const s = try fmtValue(a, v);
    defer a.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "#<heap-object "));
    try std.testing.expect(std.mem.endsWith(u8, s, ">"));
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
