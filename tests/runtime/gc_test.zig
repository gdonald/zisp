//! The object allocator: regions, the free list, and the size classes.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const gc = zisp.gc;

fn newAllocator() gc.Allocator {
    var allocator = gc.Allocator.init(testing.allocator);
    // These tests read the free lists, which a build that holds
    // reclaimed blocks back does not fill in.
    allocator.quarantine = false;
    // They are about the tenured space: the regions, the free lists and
    // the sweep. With a nursery in front nothing would reach them.
    allocator.nursery_capacity = 0;
    return allocator;
}

test "an allocation comes back aligned and large enough" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const block = try allocator.alloc(16);
    try testing.expect(block.len >= 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(block.ptr) % gc.ALIGNMENT);
}

test "a tiny request still gets room for a free block" {
    var allocator = newAllocator();
    defer allocator.deinit();
    // A reclaimed block has to thread itself onto a free list, so
    // nothing smaller than that is ever handed out.
    const block = try allocator.alloc(1);
    try testing.expect(block.len >= gc.MIN_PAYLOAD);
}

test "allocations inside one region do not overlap" {
    var allocator = newAllocator();
    defer allocator.deinit();
    var blocks: [64][]align(gc.ALIGNMENT) u8 = undefined;
    for (&blocks) |*block| {
        block.* = try allocator.alloc(32);
        @memset(block.*, 0);
    }
    for (blocks, 0..) |block, i| {
        @memset(block, @intCast(i));
    }
    for (blocks, 0..) |block, i| {
        for (block) |byte| try testing.expectEqual(@as(u8, @intCast(i)), byte);
    }
}

test "a freed block is handed out again rather than growing the heap" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const first = try allocator.alloc(32);
    const regions_before = allocator.regionCount();
    allocator.free(first);
    try testing.expectEqual(@as(usize, 1), allocator.stats.free_blocks);

    const second = try allocator.alloc(32);
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(@as(usize, 0), allocator.stats.free_blocks);
    try testing.expectEqual(regions_before, allocator.regionCount());
}

test "live bytes rise and fall with the blocks handed out" {
    var allocator = newAllocator();
    defer allocator.deinit();
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
    const block = try allocator.alloc(64);
    try testing.expectEqual(@as(usize, 64), allocator.stats.live_bytes);
    allocator.free(block);
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
    try testing.expectEqual(@as(usize, 64), allocator.stats.free_bytes);
}

test "a request larger than a region gets a region of its own" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const block = try allocator.alloc(gc.REGION_BYTES * 2);
    try testing.expect(block.len >= gc.REGION_BYTES * 2);
    try testing.expect(allocator.stats.region_bytes >= gc.REGION_BYTES * 2);
}

test "ten thousand allocate and free cycles leave the free list sound" {
    var allocator = newAllocator();
    defer allocator.deinit();

    // Every block carries its own index, and a later pass checks it is
    // still there. A double free would put one block on the list twice
    // and hand the same memory to two holders, which the check catches.
    var live: [128][]align(gc.ALIGNMENT) u8 = undefined;
    var sizes: [128]usize = undefined;
    var prng = std.Random.DefaultPrng.init(0x6C0FFEE);
    const random = prng.random();

    for (&live, &sizes, 0..) |*block, *size, i| {
        size.* = 16 + (i % 4) * 16;
        block.* = try allocator.alloc(size.*);
        @memset(block.*, @intCast(i));
    }

    var cycle: usize = 0;
    while (cycle < 10_000) : (cycle += 1) {
        const slot = random.uintLessThan(usize, live.len);
        // What is there now must still be what was written to it.
        for (live[slot]) |byte| {
            try testing.expectEqual(@as(u8, @intCast(slot)), byte);
        }
        allocator.free(live[slot]);
        live[slot] = try allocator.alloc(sizes[slot]);
        @memset(live[slot], @intCast(slot));
    }

    for (live, 0..) |block, i| {
        for (block) |byte| try testing.expectEqual(@as(u8, @intCast(i)), byte);
    }
    for (live) |block| allocator.free(block);
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
}

test "two live blocks never share memory across a free and reallocate" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const a = try allocator.alloc(32);
    const b = try allocator.alloc(32);
    try testing.expect(a.ptr != b.ptr);
    allocator.free(a);
    const c = try allocator.alloc(32);
    try testing.expect(c.ptr != b.ptr);
}

test "each size class reuses its own freed blocks" {
    var allocator = newAllocator();
    defer allocator.deinit();

    // Fill each class, free half of it, then allocate the same class
    // again: the freed blocks come back and no new region is needed.
    for (gc.SIZE_CLASSES) |class| {
        var blocks: [1000][]align(gc.ALIGNMENT) u8 = undefined;
        for (&blocks) |*block| block.* = try allocator.alloc(class);

        var i: usize = 0;
        while (i < blocks.len) : (i += 2) allocator.free(blocks[i]);
        const freed = blocks.len / 2;
        try testing.expectEqual(freed, allocator.stats.free_blocks);

        const regions_before = allocator.regionCount();
        i = 0;
        while (i < freed) : (i += 1) _ = try allocator.alloc(class);
        try testing.expectEqual(regions_before, allocator.regionCount());
        try testing.expectEqual(@as(usize, 0), allocator.stats.free_blocks);
    }
}

test "a large request is served from the oversized list" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const big = try allocator.alloc(1024);
    allocator.free(big);
    const again = try allocator.alloc(1024);
    try testing.expectEqual(big.ptr, again.ptr);
}

test "a class with nothing free falls through to a larger one" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const large = try allocator.alloc(128);
    allocator.free(large);
    // Nothing is free at 16 bytes, so the 128-byte block serves instead
    // of the heap growing.
    const small = try allocator.alloc(16);
    try testing.expectEqual(large.ptr, small.ptr);
}

test "the collection counter tracks what has been handed out" {
    var allocator = newAllocator();
    defer allocator.deinit();
    _ = try allocator.alloc(32);
    _ = try allocator.alloc(64);
    try testing.expectEqual(@as(usize, 96), allocator.stats.bytes_since_collection);
}

// --- sweep ---

test "an unmarked block is reclaimed and a marked one is kept" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const kept = try allocator.alloc(32);
    const dropped = try allocator.alloc(32);
    _ = allocator.mark(@intFromPtr(kept.ptr));

    allocator.sweep(.everything, null);

    try testing.expectEqual(kept.len, allocator.stats.live_bytes);
    try testing.expectEqual(@as(usize, 1), allocator.stats.free_blocks);
    try testing.expectEqual(dropped.len, allocator.stats.free_bytes);
}

test "neighbouring dead blocks come back as one free block" {
    var allocator = newAllocator();
    defer allocator.deinit();
    for (0..8) |_| _ = try allocator.alloc(24);

    allocator.sweep(.everything, null);

    try testing.expectEqual(@as(usize, 1), allocator.stats.free_blocks);
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
}

test "a merged block is split back down for a small request" {
    var allocator = newAllocator();
    defer allocator.deinit();
    for (0..8) |_| _ = try allocator.alloc(24);
    allocator.sweep(.everything, null);
    const before = allocator.stats.free_bytes;

    const block = try allocator.alloc(16);

    try testing.expectEqual(@as(usize, 16), block.len);
    try testing.expect(allocator.stats.free_bytes < before);
    try testing.expectEqual(@as(usize, 1), allocator.stats.free_blocks);
}

test "a merged block serves an allocation too large for any original one" {
    var allocator = newAllocator();
    defer allocator.deinit();
    for (0..8) |_| _ = try allocator.alloc(24);
    allocator.sweep(.everything, null);
    const regions = allocator.regionCount();

    const block = try allocator.alloc(200);

    try testing.expectEqual(@as(usize, 200), block.len);
    try testing.expectEqual(regions, allocator.regionCount());
}

test "a live block between two dead ones keeps their runs apart" {
    var allocator = newAllocator();
    defer allocator.deinit();
    _ = try allocator.alloc(24);
    const kept = try allocator.alloc(24);
    _ = try allocator.alloc(24);
    _ = allocator.mark(@intFromPtr(kept.ptr));

    allocator.sweep(.everything, null);

    try testing.expectEqual(@as(usize, 2), allocator.stats.free_blocks);
}

test "sweeping twice leaves the free lists as they were" {
    var allocator = newAllocator();
    defer allocator.deinit();
    for (0..8) |_| _ = try allocator.alloc(24);
    allocator.sweep(.everything, null);
    const blocks = allocator.stats.free_blocks;
    const bytes = allocator.stats.free_bytes;

    allocator.sweep(.everything, null);

    try testing.expectEqual(blocks, allocator.stats.free_blocks);
    try testing.expectEqual(bytes, allocator.stats.free_bytes);
}

test "an unmarked cons cell goes back on the cons free list" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const kept = try allocator.allocCons();
    _ = try allocator.allocCons();
    _ = allocator.mark(@intFromPtr(kept.ptr));

    allocator.sweep(.everything, null);

    try testing.expectEqual(@as(usize, 1), allocator.stats.free_conses);
    try testing.expectEqual(gc.CONS_BYTES, allocator.stats.live_bytes);
}

test "a swept cons cell is handed out again before the region grows" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const cell = try allocator.allocCons();
    allocator.sweep(.everything, null);

    const reused = try allocator.allocCons();

    try testing.expectEqual(@intFromPtr(cell.ptr), @intFromPtr(reused.ptr));
    try testing.expectEqual(@as(usize, 0), allocator.stats.free_conses);
}

test "a finalizer runs once for each dead object and not for a live one" {
    const Counter = struct {
        var seen: usize = 0;
        fn run(context: *anyopaque, object: [*]align(gc.ALIGNMENT) u8) void {
            _ = context;
            _ = object;
            seen += 1;
        }
    };
    Counter.seen = 0;
    var allocator = newAllocator();
    defer allocator.deinit();
    const kept = try allocator.alloc(32);
    _ = try allocator.alloc(32);
    _ = try allocator.alloc(32);
    _ = allocator.mark(@intFromPtr(kept.ptr));

    var context: usize = 0;
    allocator.sweep(.everything, .{ .context = &context, .run = Counter.run });
    allocator.sweep(.everything, .{ .context = &context, .run = Counter.run });

    try testing.expectEqual(@as(usize, 3), Counter.seen);
}

test "worst-case fragmentation collapses once the survivors die" {
    var allocator = newAllocator();
    defer allocator.deinit();
    const count = 10_000;
    var blocks: [count][]align(gc.ALIGNMENT) u8 = undefined;
    for (&blocks, 0..) |*block, i| {
        block.* = try allocator.alloc(16 + (i % 7) * 24);
    }

    // Every other block survives, so no two dead blocks touch.
    for (blocks, 0..) |block, i| {
        if (i % 2 == 0) _ = allocator.mark(@intFromPtr(block.ptr));
    }
    allocator.sweep(.everything, null);
    try testing.expect(allocator.stats.free_blocks >= count / 2 - allocator.regionCount());
    try testing.expect(!allocator.isMarked(@intFromPtr(blocks[0].ptr)));

    // With the survivors gone, every run merges: what is left is one
    // free block per region.
    allocator.sweep(.everything, null);
    try testing.expectEqual(allocator.regionCount(), allocator.stats.free_blocks);
    try testing.expect(allocator.stats.free_blocks <= count / 100);
}

/// An allocator with the nursery in front, which is where a young
/// allocation lands and where a collection between allocations reclaims.
fn newNurseryAllocator() gc.Allocator {
    var allocator = gc.Allocator.init(testing.allocator);
    allocator.quarantine = false;
    return allocator;
}

test "a young object is handed out from the nursery" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const block = try allocator.alloc(32);
    try testing.expect(allocator.inNursery(@intFromPtr(block.ptr)));
    try testing.expect(allocator.stats.nursery_bytes > 0);
    // The nursery is counted on its own: nothing there has survived a
    // collection yet.
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
}

test "a freed young block is handed out again by the nursery" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const first = try allocator.alloc(32);
    allocator.free(first);
    const second = try allocator.alloc(32);
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
}

test "a freed young cons is handed out again by the nursery" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const first = try allocator.allocCons();
    allocator.freeCons(first);
    const second = try allocator.allocCons();
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expect(allocator.inNursery(@intFromPtr(second.ptr)));
}

test "a sweep reclaims the young cells nothing marked" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const kept = try allocator.allocCons();
    const dropped = try allocator.allocCons();
    _ = allocator.mark(@intFromPtr(kept.ptr));
    allocator.sweep(.everything, null);

    const next = try allocator.allocCons();
    try testing.expectEqual(dropped.ptr, next.ptr);
    // What the sweep reclaimed is young space still, so it never counts
    // as tenured.
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
}

test "a sweep reclaims the young objects nothing marked" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const kept = try allocator.alloc(32);
    const dropped = try allocator.alloc(32);
    _ = allocator.mark(@intFromPtr(kept.ptr));
    allocator.sweep(.everything, null);

    const next = try allocator.alloc(32);
    try testing.expectEqual(dropped.ptr, next.ptr);
}

test "a young allocation the nursery cannot serve comes from the tenured space" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    allocator.nursery_capacity = 16 * gc.CONS_BYTES;
    var young: usize = 0;
    while (young < 16) : (young += 1) _ = try allocator.allocCons();

    try testing.expect(allocator.nurseryFull());
    // Nothing has had to spill yet, so there is nothing to reclaim.
    try testing.expect(!allocator.nurseryDue());

    const spilled = try allocator.allocCons();
    try testing.expect(!allocator.inNursery(@intFromPtr(spilled.ptr)));
    try testing.expectEqual(@as(usize, gc.CONS_BYTES), allocator.stats.live_bytes);
    try testing.expect(allocator.nurseryDue());
}

test "a tenured allocation is never served out of the nursery" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const young_cons = try allocator.allocCons();
    const young_object = try allocator.alloc(32);
    allocator.freeCons(young_cons);
    allocator.free(young_object);

    const cell = try allocator.allocTenuredCons();
    const object = try allocator.allocTenured(32);
    try testing.expect(!allocator.inNursery(@intFromPtr(cell.ptr)));
    try testing.expect(!allocator.inNursery(@intFromPtr(object.ptr)));
}

test "resetting the nursery puts its bump pointers back to the start" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const first = try allocator.allocCons();
    _ = try allocator.alloc(32);
    allocator.resetNursery();

    try testing.expectEqual(@as(usize, 0), allocator.stats.nursery_bytes);
    try testing.expect(!allocator.inNursery(@intFromPtr(first.ptr)));
    try testing.expectEqual(first.ptr, (try allocator.allocCons()).ptr);
}

test "an allocator with no nursery never asks for a collection to make young room" {
    var allocator = newAllocator();
    defer allocator.deinit();
    _ = try allocator.alloc(32);
    _ = try allocator.allocCons();
    try testing.expect(!allocator.nurseryFull());
    try testing.expect(!allocator.nurseryDue());
}

test "a young cons region with no survivors goes back to its bump pointer" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    allocator.nursery_capacity = 64 * gc.CONS_BYTES;
    const first = try allocator.allocCons();
    var made: usize = 1;
    while (made < 64) : (made += 1) _ = try allocator.allocCons();

    allocator.sweep(.everything, null);

    // Nothing was threaded onto a free list: the region is simply empty
    // again.
    try testing.expectEqual(@as(usize, 0), allocator.stats.nursery_bytes);
    try testing.expectEqual(@as(usize, 0), allocator.stats.free_conses);
    try testing.expectEqual(first.ptr, (try allocator.allocCons()).ptr);
}

test "a young cons region with room left keeps serving young allocations" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    allocator.nursery_capacity = 64 * gc.CONS_BYTES;
    var cells: [64][]align(gc.ALIGNMENT) u8 = undefined;
    for (&cells) |*cell| cell.* = try allocator.allocCons();
    for (cells[0..10]) |cell| _ = allocator.mark(@intFromPtr(cell.ptr));

    allocator.sweep(.everything, null);

    try testing.expect(allocator.inNursery(@intFromPtr(cells[0].ptr)));
    // Young bytes are counted on their own, so nothing here is tenured.
    try testing.expectEqual(@as(usize, 0), allocator.stats.live_bytes);
    try testing.expectEqual(@as(usize, 54), allocator.stats.free_conses);
}

test "a young cons region crowded with survivors is handed to the tenured space" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    allocator.nursery_capacity = 64 * gc.CONS_BYTES;
    var cells: [64][]align(gc.ALIGNMENT) u8 = undefined;
    for (&cells) |*cell| cell.* = try allocator.allocCons();
    for (cells[0..40]) |cell| _ = allocator.mark(@intFromPtr(cell.ptr));

    allocator.sweep(.everything, null);

    try testing.expect(!allocator.inNursery(@intFromPtr(cells[0].ptr)));
    try testing.expectEqual(@as(usize, 40 * gc.CONS_BYTES), allocator.stats.live_bytes);

    // The next young allocation comes from a region of its own rather
    // than from what is left of the one that filled up.
    const fresh = try allocator.allocCons();
    try testing.expect(allocator.inNursery(@intFromPtr(fresh.ptr)));
}

test "a pause is counted in the bucket for its order of magnitude" {
    var allocator = newAllocator();
    defer allocator.deinit();
    allocator.recordPause(500);
    allocator.recordPause(5 * std.time.ns_per_us);
    allocator.recordPause(5 * std.time.ns_per_ms);
    allocator.recordPause(5 * std.time.ns_per_s);

    try testing.expectEqual(@as(u32, 1), allocator.stats.pauses[0]);
    try testing.expectEqual(@as(u32, 1), allocator.stats.pauses[1]);
    try testing.expectEqual(@as(u32, 1), allocator.stats.pauses[4]);
    try testing.expectEqual(@as(u32, 1), allocator.stats.pauses[gc.PAUSE_BUCKETS - 1]);
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), allocator.stats.gc_pause_max_ns);
    try testing.expectEqual(
        @as(u64, 500 + 5 * std.time.ns_per_us + 5 * std.time.ns_per_ms + 5 * std.time.ns_per_s),
        allocator.stats.gc_time_ns,
    );
}

test "every collection lands in a bucket" {
    var allocator = newAllocator();
    defer allocator.deinit();
    for ([_]u64{ 0, 1, std.time.ns_per_s * 100 }) |nanoseconds| {
        allocator.recordPause(nanoseconds);
    }
    var counted: u32 = 0;
    for (allocator.stats.pauses) |count| counted += count;
    try testing.expectEqual(@as(u32, 3), counted);
}

test "a tenured object made to point at a young one marks its card" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const old = try allocator.allocTenuredCons();
    const young = try allocator.allocCons();

    try testing.expect(!allocator.cardMarked(@intFromPtr(old.ptr)));
    allocator.noteWrite(@intFromPtr(old.ptr), @intFromPtr(young.ptr));
    try testing.expect(allocator.cardMarked(@intFromPtr(old.ptr)));
}

test "a pointer that stays inside one generation marks nothing" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const old = try allocator.allocTenuredCons();
    const older = try allocator.allocTenuredCons();
    const young = try allocator.allocCons();
    const younger = try allocator.allocCons();

    // Old to old: a collection of the nursery has no reason to read it.
    allocator.noteWrite(@intFromPtr(old.ptr), @intFromPtr(older.ptr));
    try testing.expect(!allocator.cardMarked(@intFromPtr(old.ptr)));

    // Young to young: the roots reach both.
    allocator.noteWrite(@intFromPtr(young.ptr), @intFromPtr(younger.ptr));
    try testing.expect(!allocator.cardMarked(@intFromPtr(young.ptr)));
}

test "a collection that has read the cards forgets them" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const old = try allocator.allocTenuredCons();
    const young = try allocator.allocCons();
    allocator.noteWrite(@intFromPtr(old.ptr), @intFromPtr(young.ptr));

    allocator.clearCards();

    try testing.expect(!allocator.cardMarked(@intFromPtr(old.ptr)));
}

const Seen = struct {
    conses: usize = 0,
    objects: usize = 0,

    fn cell(self: *Seen, address: [*]align(gc.ALIGNMENT) u8) anyerror!void {
        _ = address;
        self.conses += 1;
    }

    fn object(self: *Seen, address: [*]align(gc.ALIGNMENT) u8) anyerror!void {
        _ = address;
        self.objects += 1;
    }
};

test "only the cards that were marked are handed to a scan" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const old = try allocator.allocTenuredCons();
    const young = try allocator.allocCons();

    var before: Seen = .{};
    try allocator.scanConses(.dirty_cards, &before, Seen.cell);
    try testing.expectEqual(@as(usize, 0), before.conses);

    allocator.noteWrite(@intFromPtr(old.ptr), @intFromPtr(young.ptr));

    var after: Seen = .{};
    try allocator.scanConses(.dirty_cards, &after, Seen.cell);
    try testing.expectEqual(@as(usize, 1), after.conses);
}

test "a cell the collector reclaimed is passed over by a card scan" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const kept = try allocator.allocTenuredCons();
    const dropped = try allocator.allocTenuredCons();
    const young = try allocator.allocCons();
    allocator.noteWrite(@intFromPtr(kept.ptr), @intFromPtr(young.ptr));
    allocator.noteWrite(@intFromPtr(dropped.ptr), @intFromPtr(young.ptr));

    _ = allocator.mark(@intFromPtr(kept.ptr));
    allocator.sweep(.everything, null);

    // Both sit on the same card, and only the one that survived holds a
    // pair for the scan to read.
    var seen: Seen = .{};
    try allocator.scanConses(.dirty_cards, &seen, Seen.cell);
    try testing.expectEqual(@as(usize, 1), seen.conses);
}

test "a tenured object on a dirty card is handed to a scan" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    const old = try allocator.allocTenured(32);
    const young = try allocator.allocCons();

    var before: Seen = .{};
    try allocator.scanObjects(.dirty_cards, &before, Seen.object);
    try testing.expectEqual(@as(usize, 0), before.objects);

    allocator.noteWrite(@intFromPtr(old.ptr), @intFromPtr(young.ptr));

    var after: Seen = .{};
    try allocator.scanObjects(.dirty_cards, &after, Seen.object);
    try testing.expectEqual(@as(usize, 1), after.objects);
}

test "a young region handed to the tenured space starts every card dirty" {
    var allocator = newNurseryAllocator();
    defer allocator.deinit();
    allocator.nursery_capacity = 64 * gc.CONS_BYTES;
    var cells: [64][]align(gc.ALIGNMENT) u8 = undefined;
    for (&cells) |*cell| cell.* = try allocator.allocCons();
    for (cells[0..40]) |cell| _ = allocator.mark(@intFromPtr(cell.ptr));

    allocator.sweep(.everything, null);

    // Nothing recorded what the cells pointed at while they were young,
    // so the whole region has to be read.
    try testing.expect(allocator.cardMarked(@intFromPtr(cells[0].ptr)));
    try testing.expect(allocator.cardMarked(@intFromPtr(cells[63].ptr)));
}
