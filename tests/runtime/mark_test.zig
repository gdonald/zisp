//! The mark phase: mark bits, traversal of every heap type, and a
//! worklist deep enough that the host stack is never the limit.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const mark_mod = zisp.mark;
const Value = value.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        // Mark bits live on the regions, so these allocate straight into
        // the tenured space rather than the nursery.
        fx.heap.objects.nursery_capacity = 0;
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.heap.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn marker(self: *Fixture) mark_mod.Marker {
        return mark_mod.Marker.init(testing.allocator, &self.heap);
    }

    fn isMarked(self: *Fixture, v: Value) bool {
        const address = if (v.isCons()) v.toConsAddr() else v.toHeapAddr();
        return self.heap.objects.isMarked(address);
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

test "marking one cons sets its bit and leaves its neighbour alone" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const marked = try fx.heap.allocCons(value.NIL, value.NIL);
    const untouched = try fx.heap.allocCons(value.NIL, value.NIL);

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(marked);
    try marker.run();

    try testing.expect(fx.isMarked(marked));
    try testing.expect(!fx.isMarked(untouched));
}

test "clearing marks puts every bit back" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const cell = try fx.heap.allocCons(value.NIL, value.NIL);

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(cell);
    try marker.run();
    try testing.expect(fx.isMarked(cell));

    fx.heap.objects.clearMarks();
    try testing.expect(!fx.isMarked(cell));
}

test "marking the head of a list reaches every cell" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    var cells: [100]Value = undefined;
    var list = value.NIL;
    for (&cells) |*cell| {
        list = try fx.heap.allocCons(Value.fromFixnum(1), list);
        cell.* = list;
    }

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(list);
    try marker.run();

    for (cells) |cell| try testing.expect(fx.isMarked(cell));
}

test "a cycle terminates rather than looping" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const cell = try fx.heap.allocCons(Value.fromFixnum(1), value.NIL);
    heap_mod.setCdr(cell, cell);

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(cell);
    try marker.run();
    try testing.expect(fx.isMarked(cell));
}

test "an object outside the collected heap is passed over" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    var marker = fx.marker();
    defer marker.deinit();
    // Fixnums, characters and NIL carry no pointer at all.
    try marker.push(Value.fromFixnum(7));
    try marker.push(Value.fromChar('a'));
    try marker.push(value.NIL);
    try marker.run();
}

// --- one case per heap type ---

test "a symbol's value, function and property cells are followed" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const sym = try fx.interner.intern("HOLDER");
    const held = try fx.heap.allocCons(Value.fromFixnum(1), value.NIL);
    const in_plist = try fx.heap.allocCons(Value.fromFixnum(2), value.NIL);
    symbol_mod.symbol(sym).value_cell = held;
    symbol_mod.symbol(sym).plist = in_plist;

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(sym);
    try marker.run();

    try testing.expect(fx.isMarked(held));
    try testing.expect(fx.isMarked(in_plist));
}

test "a symbol whose value is itself terminates" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const sym = try fx.interner.intern("SELF");
    symbol_mod.symbol(sym).value_cell = sym;

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(sym);
    try marker.run();
}

test "a string has nothing inside to follow" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const text = try fx.heap.allocString("abc");

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(text);
    try marker.run();
    try testing.expect(fx.isMarked(text));
}

test "every element of a vector is reached" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const first = try fx.heap.allocCons(Value.fromFixnum(1), value.NIL);
    const second = try fx.heap.allocCons(Value.fromFixnum(2), value.NIL);
    const vector = try fx.heap.allocVector(&.{ first, second });

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(vector);
    try marker.run();

    try testing.expect(fx.isMarked(vector));
    try testing.expect(fx.isMarked(first));
    try testing.expect(fx.isMarked(second));
}

test "a displaced array reaches its target rather than its own storage" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const held = try fx.heap.allocCons(Value.fromFixnum(1), value.NIL);
    const target = try fx.heap.allocVector(&.{held});
    const window = try fx.heap.allocArray(&.{1}, .t);
    heap_mod.asArray(window).displaced_to = target;

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(window);
    try marker.run();

    try testing.expect(fx.isMarked(target));
    try testing.expect(fx.isMarked(held));
}

test "both halves of every hash table entry are reached" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const key = try fx.heap.allocCons(Value.fromFixnum(1), value.NIL);
    const held = try fx.heap.allocCons(Value.fromFixnum(2), value.NIL);
    const table = try fx.heap.allocHashTable();
    try heap_mod.asHashTable(table).entries.append(
        fx.heap.allocator,
        .{ .key = key, .value = held, .live = true },
    );

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(table);
    try marker.run();

    try testing.expect(fx.isMarked(table));
    try testing.expect(fx.isMarked(key));
    try testing.expect(fx.isMarked(held));
}

test "a ratio, a complex and a pathname reach their components" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const big = try fx.heap.allocString("wide");
    const ratio = try fx.heap.allocRatio(Value.fromFixnum(1), Value.fromFixnum(2));
    const complex = try fx.heap.allocComplex(Value.fromFixnum(1), Value.fromFixnum(2));
    const path = try fx.heap.allocPathname(.{
        .host = value.NIL,
        .device = value.NIL,
        .directory = value.NIL,
        .name = big,
        .type_ = value.NIL,
        .version = value.NIL,
    });

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(ratio);
    try marker.push(complex);
    try marker.push(path);
    try marker.run();

    try testing.expect(fx.isMarked(ratio));
    try testing.expect(fx.isMarked(complex));
    try testing.expect(fx.isMarked(path));
    try testing.expect(fx.isMarked(big));
}

test "a structure reaches its name and its slots" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const slot = try fx.heap.allocCons(Value.fromFixnum(1), value.NIL);
    const name = try fx.interner.intern("POINT");
    const instance = try fx.heap.allocStructure(name, &.{slot});

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(instance);
    try marker.run();

    try testing.expect(fx.isMarked(instance));
    try testing.expect(fx.isMarked(slot));
}

// --- depth ---

test "a list of a million cells marks without exhausting the stack" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    var list = value.NIL;
    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {
        list = try fx.heap.allocCons(Value.fromFixnum(1), list);
    }

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(list);
    try marker.run();

    // Walk the list back and check every cell came out marked.
    var cell = list;
    var seen: usize = 0;
    while (cell.isCons()) : (cell = heap_mod.cdr(cell)) {
        try testing.expect(fx.isMarked(cell));
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1_000_000), seen);
}

test "a structure nested deeply through the car marks without exhausting the stack" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    // Nesting through the car rather than the cdr, so the traversal
    // cannot lean on a list-shaped special case.
    var nest = value.NIL;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        nest = try fx.heap.allocCons(nest, value.NIL);
    }

    var marker = fx.marker();
    defer marker.deinit();
    try marker.push(nest);
    try marker.run();
    try testing.expect(fx.isMarked(nest));
}
