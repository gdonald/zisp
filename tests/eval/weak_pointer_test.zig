//! A reference the collector does not follow.
//!
//! `tests/lisp/weak-pointer.lisp` holds the checks: each one signals an
//! error when it does not hold, and counts itself when it does.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const heap_mod = zisp.heap;
const Evaluator = zisp.eval.Evaluator;

const corpus_path = "tests/lisp/weak-pointer.lisp";
const expected_checks = 10;

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

test "every check in the weak pointer corpus holds" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    const checks = fx.global("*CHECKS*");
    try testing.expectEqual(@as(i64, expected_checks), checks.toFixnum());
}

test "a weak pointer holds nothing once the collector has broken it" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    try zisp.builtins.system.loadPath(&fx.ev, corpus_path);
    // What the corpus leaves behind is a broken pointer, which carries a
    // value no program can make rather than a nil the caller could
    // mistake for the referent.
    const broken = fx.global("*TO-DROPPED*");
    try testing.expect(heap_mod.isWeakPointer(broken));
    try testing.expect(heap_mod.asWeakPointer(broken).referent.equalsRaw(value.BROKEN));
}
