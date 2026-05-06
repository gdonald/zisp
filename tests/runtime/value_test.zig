const std = @import("std");
const value = @import("zisp").value;
const Value = value.Value;

test "fixnum round-trip basic values" {
    try std.testing.expectEqual(@as(i64, 0), Value.fromFixnum(0).toFixnum());
    try std.testing.expectEqual(@as(i64, 1), Value.fromFixnum(1).toFixnum());
    try std.testing.expectEqual(@as(i64, -1), Value.fromFixnum(-1).toFixnum());
    try std.testing.expectEqual(@as(i64, 42), Value.fromFixnum(42).toFixnum());
    try std.testing.expectEqual(@as(i64, -42), Value.fromFixnum(-42).toFixnum());
}

test "fixnum round-trip extremes" {
    try std.testing.expectEqual(value.FIXNUM_MAX, Value.fromFixnum(value.FIXNUM_MAX).toFixnum());
    try std.testing.expectEqual(value.FIXNUM_MIN, Value.fromFixnum(value.FIXNUM_MIN).toFixnum());
}

test "fixnum predicate" {
    try std.testing.expect(Value.fromFixnum(42).isFixnum());
    try std.testing.expect(!Value.fromFixnum(42).isCons());
    try std.testing.expect(!Value.fromFixnum(42).isSymbol());
    try std.testing.expect(!Value.fromFixnum(42).isChar());
}

test "fixnum direct addition without untag" {
    const a = Value.fromFixnum(5);
    const b = Value.fromFixnum(7);
    const sum: Value = .{ .raw = a.raw +% b.raw };
    try std.testing.expectEqual(@as(i64, 12), sum.toFixnum());
}

test "cons pointer round-trip" {
    const addr: u64 = 0x1000;
    const v = Value.fromConsAddr(addr);
    try std.testing.expect(v.isCons());
    try std.testing.expectEqual(addr, v.toConsAddr());
}

test "cons pointer aligned address" {
    const aligned: u64 = 0xDEADBEEF & ~value.TAG_MASK;
    const v = Value.fromConsAddr(aligned);
    try std.testing.expectEqual(aligned, v.toConsAddr());
}

test "symbol pointer round-trip" {
    const addr: u64 = 0x2000;
    const v = Value.fromSymbolAddr(addr);
    try std.testing.expect(v.isSymbol());
    try std.testing.expectEqual(addr, v.toSymbolAddr());
}

test "heap pointer round-trip" {
    const addr: u64 = 0x3000;
    const v = Value.fromHeapAddr(addr);
    try std.testing.expect(v.isHeap());
    try std.testing.expectEqual(addr, v.toHeapAddr());
}

test "character round-trip ascii" {
    const v = Value.fromChar('A');
    try std.testing.expect(v.isChar());
    try std.testing.expectEqual(@as(u21, 'A'), v.toChar());
}

test "character round-trip unicode" {
    const v = Value.fromChar(0x1F600);
    try std.testing.expect(v.isChar());
    try std.testing.expectEqual(@as(u21, 0x1F600), v.toChar());
}

test "character max codepoint" {
    const max: u21 = 0x10FFFF;
    const v = Value.fromChar(max);
    try std.testing.expectEqual(max, v.toChar());
}

test "special immediates distinct" {
    try std.testing.expect(value.SPECIAL_UNBOUND.isSpecial());
    try std.testing.expect(value.SPECIAL_EOF.isSpecial());
    try std.testing.expect(!value.SPECIAL_UNBOUND.equalsRaw(value.SPECIAL_EOF));
    try std.testing.expectEqual(@as(u8, 0), value.SPECIAL_UNBOUND.toSpecialIndex());
    try std.testing.expectEqual(@as(u8, 1), value.SPECIAL_EOF.toSpecialIndex());
}

test "tags are pairwise distinct" {
    const fix = Value.fromFixnum(1);
    const cns = Value.fromConsAddr(0x1000);
    const sym = Value.fromSymbolAddr(0x2000);
    const heap_v = Value.fromHeapAddr(0x3000);
    const ch = Value.fromChar('x');
    const spec = value.SPECIAL_UNBOUND;

    const all = [_]Value{ fix, cns, sym, heap_v, ch, spec };
    for (all, 0..) |a, i| {
        for (all, 0..) |b, j| {
            if (i != j) try std.testing.expect(a.tag() != b.tag());
        }
    }
}
