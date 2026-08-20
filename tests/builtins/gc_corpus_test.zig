//! Fragmentation and coalescing.
//!
//! Reads `tests/lisp/gc-fragmentation.lisp` and evaluates each form. Every
//! form is self-checking and must come back T.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;

const corpus_text = @embedFile("../lisp/gc-fragmentation.lisp");

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
};

test "every form in the collector corpus evaluates to T" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var tk = zisp.reader.Tokenizer.init(corpus_text);
    var rd = zisp.reader.Reader.init(&tk, &fx.heap, &fx.interner);
    var checked: u32 = 0;
    while (true) {
        // The same safe point the file driver collects at.
        try zisp.eval.collect.maybeCollect(&fx.ev);
        const form = (try rd.read()) orelse break;
        checked += 1;
        const got = fx.ev.eval(form) catch |e| {
            std.debug.print("collector corpus form {d}: eval error {s}\n", .{ checked, @errorName(e) });
            return e;
        };
        if (!got.equalsRaw(value.T)) {
            std.debug.print("collector corpus form {d}: expected T\n", .{checked});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(u32, 11), checked);
    try testing.expect(fx.ev.gc_count >= 2);
}
