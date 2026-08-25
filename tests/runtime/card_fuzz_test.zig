//! Every reference from the tenured space into the nursery sits on a
//! card the write barrier marked.
//!
//! A hundred thousand random stores go through the mutators a program
//! uses, and the tenured space is then read from end to end: for each
//! slot found pointing at a young object, the card its container sits on
//! has to be marked. The walk here is written out rather than shared
//! with the collector, so a mistake in one does not hide in the other.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const gc = zisp.gc;
const symbol_mod = zisp.symbol;
const collect = zisp.eval.collect;
const Evaluator = zisp.eval.Evaluator;
const Value = value.Value;

const mutations = 100_000;
const containers = 200;
/// The population is built from every kind of object a store can name.
const kinds = 4;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    aw: std.Io.Writer.Allocating,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.heap.torture = 0;
        fx.heap.objects.quarantine = false;
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// What the fuzz counts, so a run that never crossed a generation is
/// reported as a broken fuzzer rather than a passing check.
const Tally = struct {
    stores: usize = 0,
    crossings: usize = 0,
};

/// The address a value refers to, or null when it refers to nothing in
/// the heap.
fn addressOf(v: Value) ?usize {
    if (v.isCons()) return v.toConsAddr();
    if (v.tag() == .heap) return v.toHeapAddr();
    return null;
}

const Checker = struct {
    allocator: *gc.Allocator,
    slots: usize = 0,
    crossing: usize = 0,

    fn check(self: *Checker, container: usize, held: Value) !void {
        self.slots += 1;
        const target = addressOf(held) orelse return;
        if (!self.allocator.inNursery(target)) return;
        self.crossing += 1;
        if (!self.allocator.cardMarked(container)) {
            std.debug.print(
                "unmarked card: 0x{x} refers to young 0x{x}\n",
                .{ container, target },
            );
            return error.CrossGenerationPointerNotRecorded;
        }
    }

    fn cell(self: *Checker, address: [*]align(gc.ALIGNMENT) u8) anyerror!void {
        const container = @intFromPtr(address);
        const pair: *const heap_mod.Cons = @ptrCast(@alignCast(address));
        try self.check(container, pair.car);
        try self.check(container, pair.cdr);
    }

    fn object(self: *Checker, address: [*]align(gc.ALIGNMENT) u8) anyerror!void {
        const container = @intFromPtr(address);
        const v = Value.fromHeapAddr(container);
        switch (heap_mod.heapType(v)) {
            .vector => {
                const array = heap_mod.asArray(v);
                try self.check(container, array.displaced_to);
                if (array.displaced_to.equalsRaw(value.NIL)) {
                    for (array.storage[0..array.storage_len]) |element| {
                        try self.check(container, element);
                    }
                }
            },
            .structure => {
                const record = heap_mod.asStructure(v);
                try self.check(container, record.name);
                for (record.slice()) |slot| try self.check(container, slot);
            },
            .hash_table => {
                for (heap_mod.asHashTable(v).entries.items) |entry| {
                    try self.check(container, entry.key);
                    try self.check(container, entry.value);
                }
            },
            .ratio => {
                const r = heap_mod.asRatio(v);
                try self.check(container, r.numerator);
                try self.check(container, r.denominator);
            },
            .complex => {
                const z = heap_mod.asComplex(v);
                try self.check(container, z.realpart);
                try self.check(container, z.imagpart);
            },
            .pathname => {
                const p = heap_mod.asPathname(v);
                for ([_]Value{ p.host, p.device, p.directory, p.name, p.type_, p.version }) |part| {
                    try self.check(container, part);
                }
            },
            .stream => {
                const s = heap_mod.asStream(v);
                try self.check(container, s.path);
                try self.check(container, s.target);
                try self.check(container, s.delete_on_close);
            },
            .string => {
                const text = heap_mod.asString(v);
                if (text.isDisplaced()) try self.check(container, text.displaced_to);
            },
            // Nothing inside these refers to another object.
            .bignum, .single_float, .double_float, .random_state, .package, .readtable => {},
            else => {},
        }
    }
};

/// Objects of every kind a store can name, held where a collection can
/// see them so the population survives being promoted.
fn buildPopulation(fx: *Fixture, held: *std.ArrayListUnmanaged(Value)) !void {
    const allocator = testing.allocator;
    var i: usize = 0;
    while (i < containers) : (i += 1) {
        const v = switch (i % kinds) {
            0 => try fx.heap.allocCons(value.NIL, value.NIL),
            1 => try fx.heap.allocArray(&.{4}, .t),
            2 => try fx.heap.allocStructure(value.NIL, &.{ value.NIL, value.NIL }),
            else => try fx.heap.allocHashTable(),
        };
        try held.append(allocator, v);
        try fx.ev.pin(v);
    }
}

/// Store `held` into a slot of `container`, through the same three calls
/// a program's own stores go through.
fn store(fx: *Fixture, container: Value, held: Value, choice: usize) !void {
    if (container.isCons()) {
        if (choice % 2 == 0) {
            heap_mod.setCar(&fx.heap, container, held);
        } else {
            heap_mod.setCdr(&fx.heap, container, held);
        }
        return;
    }
    switch (heap_mod.heapType(container)) {
        .vector => heap_mod.setSlot(&fx.heap, container, choice % 4, held),
        .structure => heap_mod.setSlot(&fx.heap, container, choice % 2, held),
        .hash_table => {
            const table = heap_mod.asHashTable(container);
            if (table.entries.items.len == 0) {
                try table.entries.append(fx.heap.allocator, .{
                    .key = value.NIL,
                    .value = value.NIL,
                    .live = true,
                });
            }
            heap_mod.setSlot(&fx.heap, container, choice % table.entries.items.len, held);
        },
        else => unreachable,
    }
}

test "every cross-generation pointer sits on a marked card" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var population: std.ArrayListUnmanaged(Value) = .empty;
    defer population.deinit(testing.allocator);
    try buildPopulation(fx, &population);

    // Promote the population, so a store into one of them is a store
    // into the tenured space.
    try collect.collect(&fx.ev);
    for (population.items, 0..) |_, i| {
        population.items[i] = fx.ev.pinned.items[i];
    }
    for (population.items) |v| {
        try testing.expect(!fx.heap.objects.inNursery(addressOf(v).?));
    }

    var prng = std.Random.DefaultPrng.init(0x2b3c4d5e);
    const random = prng.random();
    var tally: Tally = .{};
    var round: usize = 0;
    while (round < mutations) : (round += 1) {
        const container = population.items[random.uintLessThan(usize, population.items.len)];
        // Most stores name something made just now, which is what puts a
        // young object under an old one.
        const held = if (random.uintLessThan(u8, 4) == 0)
            population.items[random.uintLessThan(usize, population.items.len)]
        else
            try fx.heap.allocCons(Value.fromFixnum(@intCast(round)), value.NIL);

        try store(fx, container, held, random.uintLessThan(usize, 8));
        tally.stores += 1;
        if (fx.heap.objects.inNursery(addressOf(held).?)) tally.crossings += 1;
    }

    // A run that crossed generations rarely would not be testing the
    // barrier at all, so the fuzz reports itself broken rather than
    // passing.
    try testing.expectEqual(mutations, tally.stores);
    try testing.expect(tally.crossings * 10 >= tally.stores);

    var checker: Checker = .{ .allocator = &fx.heap.objects };
    try fx.heap.objects.scanConses(.everything, &checker, Checker.cell);
    try fx.heap.objects.scanObjects(.everything, &checker, Checker.object);

    // The walk has to have found the references it is checking, or it
    // proved nothing.
    try testing.expect(checker.crossing > 0);

    // What the cards recorded has to be enough for a collection to act
    // on: it copies the young objects out and rewrites every slot that
    // named one, so nothing in the tenured space refers to the nursery
    // afterwards. A store the barrier had missed would leave one behind.
    try collect.collect(&fx.ev);

    var after: Checker = .{ .allocator = &fx.heap.objects };
    try fx.heap.objects.scanConses(.everything, &after, Checker.cell);
    try fx.heap.objects.scanObjects(.everything, &after, Checker.object);
    try testing.expectEqual(@as(usize, 0), after.crossing);
}
