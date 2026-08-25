//! The nursery turned off, which is the collector without generations.
//!
//! `tests/lisp/gc-nursery-off.lisp` holds the checks: each one signals
//! an error when it does not hold, and counts itself when it does.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;

const corpus_path = "tests/lisp/gc-nursery-off.lisp";
const expected_checks = 9;

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

    fn eval(self: *Fixture, source: []const u8) !void {
        try zisp.builtins.system.evalSource(&self.ev, source);
    }
};

test "every check in the nursery-off corpus holds" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    const checks = fx.global("*CHECKS*");
    try testing.expectEqual(@as(i64, expected_checks), checks.toFixnum());
}

test "a tuning variable that has no value leaves the collector as it was" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    const capacity = fx.heap.objects.nursery_capacity;
    const threshold = fx.heap.objects.collect_threshold;
    try fx.eval("(defvar *gc-nursery-bytes*)");
    try fx.eval("(defvar *gc-trigger*)");
    try fx.eval("(defvar *gc-verbose*)");
    try fx.eval("(gc)");

    try testing.expectEqual(capacity, fx.heap.objects.nursery_capacity);
    try testing.expectEqual(threshold, fx.heap.objects.collect_threshold);
    // An unbound `*gc-verbose*` reads as off, so the collection reported
    // nothing.
    try testing.expectEqualStrings("", fx.aw.written());
}
