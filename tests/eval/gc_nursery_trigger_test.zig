//! The collection that runs while one form is still going.
//!
//! `tests/lisp/gc-nursery-trigger.lisp` holds the checks: each one
//! signals an error when it does not hold, and counts itself when it
//! does.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;

const corpus_path = "tests/lisp/gc-nursery-trigger.lisp";
const expected_checks = 6;

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

test "every check in the nursery trigger corpus holds" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    const checks = fx.global("*CHECKS*");
    try testing.expectEqual(@as(i64, expected_checks), checks.toFixnum());
}

test "the garbage a long-running form makes does not reach the tenured space" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    // The loop hands out about 3.2 MB of conses. Without a collection
    // while it runs, every byte past the first megabyte would come out
    // of the tenured regions and they would have to grow to hold it.
    const grown = fx.heap.objects.stats.region_bytes -
        2 * fx.heap.objects.nursery_capacity;
    try testing.expect(grown < fx.heap.objects.nursery_capacity);
}
