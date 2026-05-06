const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const heap = zisp.heap;
const Value = value.Value;

test "Cons is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(heap.Cons));
}

test "HeapHeader is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(heap.HeapHeader));
}

test "alloc cons round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());

    const v = try h.allocCons(Value.fromFixnum(1), Value.fromFixnum(2));
    try std.testing.expect(v.isCons());
    try std.testing.expectEqual(@as(i64, 1), heap.car(v).toFixnum());
    try std.testing.expectEqual(@as(i64, 2), heap.cdr(v).toFixnum());
}

test "setCar / setCdr modify in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());

    const v = try h.allocCons(Value.fromFixnum(1), Value.fromFixnum(2));
    heap.setCar(v, Value.fromFixnum(10));
    heap.setCdr(v, Value.fromFixnum(20));
    try std.testing.expectEqual(@as(i64, 10), heap.car(v).toFixnum());
    try std.testing.expectEqual(@as(i64, 20), heap.cdr(v).toFixnum());
}

test "1M-cell list allocation and traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());

    var head = value.SPECIAL_UNBOUND;
    var i: i64 = 1_000_000;
    while (i >= 1) : (i -= 1) {
        head = try h.allocCons(Value.fromFixnum(i), head);
    }

    var cur = head;
    var expected: i64 = 1;
    while (cur.isCons()) {
        try std.testing.expectEqual(expected, heap.car(cur).toFixnum());
        cur = heap.cdr(cur);
        expected += 1;
    }
    try std.testing.expectEqual(@as(i64, 1_000_001), expected);
}

test "nested cons (a (b c) d)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = heap.Heap.init(arena.allocator());

    const inner = try h.allocCons(
        Value.fromChar('b'),
        try h.allocCons(Value.fromChar('c'), value.SPECIAL_UNBOUND),
    );
    const outer = try h.allocCons(
        Value.fromChar('a'),
        try h.allocCons(
            inner,
            try h.allocCons(Value.fromChar('d'), value.SPECIAL_UNBOUND),
        ),
    );

    try std.testing.expectEqual(@as(u21, 'a'), heap.car(outer).toChar());
    const second = heap.car(heap.cdr(outer));
    try std.testing.expect(second.isCons());
    try std.testing.expectEqual(@as(u21, 'b'), heap.car(second).toChar());
    try std.testing.expectEqual(@as(u21, 'c'), heap.car(heap.cdr(second)).toChar());
    try std.testing.expectEqual(@as(u21, 'd'), heap.car(heap.cdr(heap.cdr(outer))).toChar());
}
