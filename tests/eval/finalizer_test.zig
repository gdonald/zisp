//! What runs once an object has been reclaimed.
//!
//! `tests/lisp/finalizer-recursion.lisp` holds the checks: each one
//! signals an error when it does not hold, and counts itself when it
//! does.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const heap_mod = zisp.heap;
const Evaluator = zisp.eval.Evaluator;

const corpus_path = "tests/lisp/finalizer-recursion.lisp";
const expected_checks = 5;

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

test "every check in the finalizer corpus holds" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    const checks = fx.global("*CHECKS*");
    try testing.expectEqual(@as(i64, expected_checks), checks.toFixnum());
}

test "the corpus leaves nothing registered and nothing waiting" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    // Every object it registered has gone, so every action has run and
    // the queue that held them is empty.
    try testing.expectEqual(@as(usize, 0), fx.ev.finalizers.items.len);
    try testing.expectEqual(@as(usize, 0), fx.ev.pending.items.len);
    try testing.expect(!fx.ev.draining);
}
