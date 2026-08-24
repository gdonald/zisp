//! Drives the ansi-test framework: define one test with `deftest`, run
//! `do-tests`, and read the report it prints.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;

const package_path = "vendor/ansi-test/rt-package.lsp";
const rt_path = "vendor/ansi-test/rt.lsp";
const cl_test_path = "vendor/ansi-test/cl-test-package.lsp";

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
        try zisp.builtins.system.loadPath(&fx.ev, package_path);
        try zisp.builtins.system.loadPath(&fx.ev, rt_path);
        try zisp.builtins.system.loadPath(&fx.ev, cl_test_path);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn run(self: *Fixture, source: []const u8) !void {
        try zisp.builtins.system.evalSource(&self.ev, source);
    }

    fn report(self: *Fixture) []const u8 {
        return self.aw.written();
    }
};

const passing_run =
    \\(in-package :cl-test)
    \\(deftest trivial 1 1)
    \\(do-tests)
;

const failing_run =
    \\(in-package :cl-test)
    \\(deftest trivial 1 1)
    \\(deftest wrong (+ 1 1) 3)
    \\(do-tests)
;

test "deftest registers a test and do-tests reports it as passing" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.run(passing_run);

    const report = fx.report();
    try testing.expect(std.mem.indexOf(u8, report, "Doing 1 pending test of 1 test total.") != null);
    try testing.expect(std.mem.indexOf(u8, report, "TRIVIAL") != null);
    try testing.expect(std.mem.indexOf(u8, report, "0 failures with 0 unexpected failures") != null);
    try testing.expect(std.mem.indexOf(u8, report, "No failures") != null);
}

test "do-tests returns T when every test passes" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.run(passing_run);
    try testing.expect(fx.ev.values.items[0].equalsRaw(value.T));
}

test "a test whose value differs is reported as a failure" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.run(failing_run);

    const report = fx.report();
    try testing.expect(std.mem.indexOf(u8, report, "Test WRONG failed") != null);
    try testing.expect(std.mem.indexOf(u8, report, "1 failure with 1 unexpected failure") != null);
    try testing.expect(fx.ev.values.items[0].equalsRaw(value.NIL));
}
