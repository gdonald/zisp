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
