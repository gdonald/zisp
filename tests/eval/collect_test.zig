//! What a collection keeps and what it reclaims.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const collect = zisp.eval.collect;
const Evaluator = zisp.eval.Evaluator;
const Value = value.Value;

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
        // These tests drive collections themselves and read what came
        // back, so the torture setting stays out of the way.
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

    /// Evaluate every form in `source` and return the last value.
    fn eval(self: *Fixture, source: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(source);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var last = value.NIL;
        while (try rd.read()) |form| last = try self.ev.eval(form);
        return last;
    }

    fn liveBytes(self: *Fixture) usize {
        return self.heap.objects.stats.live_bytes;
    }
};

test "a value a global holds comes through a collection" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval("(defparameter *kept* (list 1 2 3))");

    try collect.collect(&fx.ev);

    const seen = try fx.eval("(car (cdr *kept*))");
    try testing.expectEqual(@as(i64, 2), seen.toFixnum());
}

test "a value nothing holds is reclaimed" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval("(defparameter *dropped* (list 1 2 3 4 5 6 7 8 9 10))");
    // The tenured space is what these figures are about, and a
    // collection of the nursery alone leaves it where it is.
    try collect.collectScoped(&fx.ev, .major);
    const before = fx.liveBytes();

    _ = try fx.eval("(setq *dropped* nil)");
    try collect.collectScoped(&fx.ev, .major);

    try testing.expect(fx.liveBytes() < before);
}

test "a closure keeps what it captured" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval(
        \\(defparameter *counter*
        \\  (let ((held (list 40 2)))
        \\    (lambda () (+ (car held) (car (cdr held))))))
    );

    try collect.collect(&fx.ev);

    const seen = try fx.eval("(funcall *counter*)");
    try testing.expectEqual(@as(i64, 42), seen.toFixnum());
}

test "what a finished call bound is not kept" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval("(defun churn () (let ((scratch (list 1 2 3 4 5 6 7 8 9 10))) (length scratch)))");
    try collect.collect(&fx.ev);
    const before = fx.liveBytes();

    _ = try fx.eval("(churn) (churn) (churn)");
    try collect.collect(&fx.ev);

    try testing.expect(fx.liveBytes() <= before);
}

test "a pinned value comes through a collection, at its new address" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    const held = try fx.heap.allocCons(Value.fromFixnum(7), value.NIL);
    try fx.ev.pin(held);

    try collect.collect(&fx.ev);

    // The collection copied the cell out of the nursery and rewrote the
    // pin, so the pin is where the value is read back from. A Zig local
    // that held the old value is stale from here on.
    const moved = fx.ev.pinned.items[fx.ev.pinned.items.len - 1];
    try testing.expect(!moved.equalsRaw(held));
    try testing.expectEqual(@as(i64, 7), heap_mod.car(moved).toFixnum());
    try testing.expect(fx.heap.objects.stats.live_bytes > 0);
    fx.ev.unpin();
}

test "collecting twice in a row reclaims nothing the second time" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval("(defparameter *kept* (list 1 2 3))");
    try collect.collect(&fx.ev);
    const settled = fx.liveBytes();

    try collect.collect(&fx.ev);

    try testing.expectEqual(settled, fx.liveBytes());
}

test "the trigger fires once enough has been allocated" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    fx.heap.objects.collect_threshold = 4096;
    _ = try fx.eval("(setq *gc-trigger* 4096)");
    _ = try fx.eval("(defun churn (n) (if (> n 0) (progn (list 1 2 3) (churn (- n 1))) t))");

    _ = try fx.eval("(churn 500)");
    try collect.maybeCollect(&fx.ev);

    try testing.expectEqual(@as(u64, 1), fx.ev.gc_count);
}

test "the trigger holds off until the threshold is passed" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval("(setq *gc-trigger* 1000000000)");

    try collect.maybeCollect(&fx.ev);

    try testing.expectEqual(@as(u64, 0), fx.ev.gc_count);
}

test "gc asks for a collection at the next safe point" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.eval("(setq *gc-trigger* 1000000000)");

    _ = try fx.eval("(gc)");
    try testing.expectEqual(@as(u64, 0), fx.ev.gc_count);

    try collect.maybeCollect(&fx.ev);
    try testing.expectEqual(@as(u64, 1), fx.ev.gc_count);
}

test "room reports the heap figures" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    const regions = try fx.eval("(getf (room) :regions)");

    try testing.expectEqual(
        @as(i64, @intCast(fx.heap.objects.regionCount())),
        regions.toFixnum(),
    );
}

test "room prints when asked to" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    _ = try fx.eval("(room t)");

    try testing.expect(std.mem.indexOf(u8, fx.aw.written(), "LIVE-BYTES:") != null);
}

test "a source position for a dead cons does not outlive it" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var table = zisp.PositionTable.init(testing.allocator);
    defer table.deinit();
    fx.ev.positions = &table;
    const dead = try fx.heap.allocCons(value.NIL, value.NIL);
    try table.record(dead, .{ .file = "probe.lisp", .line = 1, .column = 1 });

    try collect.collect(&fx.ev);

    try testing.expectEqual(@as(u32, 0), table.count());
}

test "a value held on the Lisp stack comes through a collection" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var held = fx.ev.protect();
    defer held.close();
    try held.push(try fx.heap.allocCons(Value.fromFixnum(7), value.NIL));

    try collect.collect(&fx.ev);

    try testing.expectEqual(@as(i64, 7), heap_mod.car(held.items()[0]).toFixnum());
}

test "a value the Lisp stack no longer holds is reclaimed" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try collect.collectScoped(&fx.ev, .major);
    const before = fx.liveBytes();
    {
        var held = fx.ev.protect();
        defer held.close();
        try held.push(try fx.heap.allocCons(Value.fromFixnum(7), value.NIL));
        try collect.collectScoped(&fx.ev, .major);
        try testing.expect(fx.liveBytes() > before);
    }

    try collect.collectScoped(&fx.ev, .major);

    try testing.expectEqual(before, fx.liveBytes());
}
