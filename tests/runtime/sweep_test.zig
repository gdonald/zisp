//! Sweeping through the heap, where a dead object takes what it holds on
//! the host allocator with it. Every test here runs on the testing
//! allocator, so anything left behind is reported as a leak.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const gc = zisp.gc;
const heap_mod = zisp.heap;
const Value = value.Value;

/// Reclaimed blocks go straight back on the free lists here, whatever
/// the build's torture setting, so what a sweep hands back is what these
/// tests read.
fn newHeap() zisp.Heap {
    var h = zisp.Heap.init(testing.allocator);
    h.objects.quarantine = false;
    h.objects.nursery_capacity = 0;
    h.torture = 0;
    return h;
}

test "a dead string releases its characters" {
    var h = newHeap();
    defer h.deinit();
    _ = try h.allocString("a string long enough to need its own storage");
    h.sweep();
}

test "a dead array releases its dimensions and its storage" {
    var h = newHeap();
    defer h.deinit();
    _ = try h.allocArray(&.{ 3, 4 }, .t);
    _ = try h.allocVector(&.{ value.NIL, value.NIL });
    h.sweep();
}

test "a dead bignum releases its limbs" {
    var h = newHeap();
    defer h.deinit();
    const limbs = try testing.allocator.alloc(std.math.big.Limb, 4);
    @memset(limbs, 7);
    _ = try h.allocBignum(.{ .limbs = limbs, .positive = true });
    h.sweep();
}

test "a dead hash table releases its entries and buckets" {
    var h = newHeap();
    defer h.deinit();
    const table = try h.allocHashTable();
    var bucket: std.ArrayListUnmanaged(u32) = .empty;
    try bucket.append(h.allocator, 0);
    try heap_mod.asHashTable(table).buckets.put(h.allocator, 1, bucket);
    try heap_mod.asHashTable(table).entries.append(
        h.allocator,
        .{ .key = value.NIL, .value = value.NIL, .live = true },
    );
    h.sweep();
}

test "a live object keeps what it holds" {
    var h = newHeap();
    defer h.deinit();
    const text = try h.allocString("kept");
    _ = h.objects.mark(text.toHeapAddr());

    h.sweep();

    try testing.expectEqualSlices(u32, &.{ 'k', 'e', 'p', 't' }, heap_mod.asString(text).slice());

    // Nothing else frees it, so the sweep that runs once it is dead has
    // to, or the testing allocator reports the leak.
    h.sweep();
}

test "a swept cons cell is handed out again" {
    var h = newHeap();
    defer h.deinit();
    const cell = try h.allocCons(Value.fromFixnum(1), value.NIL);
    h.sweep();

    const reused = try h.allocCons(Value.fromFixnum(2), value.NIL);

    try testing.expectEqual(cell.raw, reused.raw);
}
