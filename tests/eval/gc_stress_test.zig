//! The collector under a form that allocates for a long time.
//!
//! `tests/lisp/gc-stress.lisp` holds the checks: each one signals an
//! error when it does not hold, and counts itself when it does. The
//! corpus runs at the size it carries by default here; `zig build
//! gc-stress` runs the same file at a hundred million cells.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;

const corpus_path = "tests/lisp/gc-stress.lisp";
const expected_checks = 7;

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
        // The corpus is about what collections give back and how big the
        // heap stays, so a build that holds reclaimed blocks back stays
        // out of the way.
        fx.heap.torture = 0;
        fx.heap.objects.quarantine = false;
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        fx.ev.io = testing.io;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        try zisp.builtins.registerSystem(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn global(self: *Fixture, name: []const u8) value.Value {
        const found = self.interner.cl_user.findSymbol(name).?;
        return symbol_mod.symbol(found.sym).value_cell;
    }
};

test "every check in the stress corpus holds" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    const checks = fx.global("*CHECKS*");
    try testing.expectEqual(@as(i64, expected_checks), checks.toFixnum());
}

test "the tenured space is sized by the retained cells" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    const iterations = fx.global("*GC-STRESS-ITERATIONS*").toFixnum();
    const stats = fx.heap.objects.stats;

    // Two passes of the loop hand out one cell per iteration.
    const churned: usize = @intCast(2 * iterations * @as(i64, 16));
    // What the heap holds is the nursery, which is a fixed size, plus
    // room for what is live and the regions it is spread over. None of
    // that grows with how long the loop ran, and all of it together is a
    // fraction of what the loop handed out.
    const bound = 2 * fx.heap.objects.nursery_capacity +
        4 * stats.live_bytes + 8 * zisp.gc.REGION_BYTES;
    try testing.expect(stats.region_bytes < bound);
    try testing.expect(bound < churned / 2);

    // Each retained cell costs the cell itself and the list cell holding
    // it, whichever pass kept it.
    const pairs = [_]struct { count: []const u8, bytes: []const u8 }{
        .{ .count = "*SMALL-COUNT*", .bytes = "*SMALL-BYTES*" },
        .{ .count = "*LARGE-COUNT*", .bytes = "*LARGE-BYTES*" },
    };
    for (pairs) |pair| {
        const count = fx.global(pair.count).toFixnum();
        const bytes = fx.global(pair.bytes).toFixnum();
        try testing.expect(count > 0);
        try testing.expect(bytes >= count * 32);
        try testing.expect(bytes <= count * 48);
    }
}
