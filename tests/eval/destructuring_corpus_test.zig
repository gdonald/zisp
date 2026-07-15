//! Macro lambda-list destructuring corpora.
//!
//! Each file under `tests/lisp/destructuring/` holds self-checking top-level
//! forms: every form defines a macro, calls it, and compares the result with
//! equal, evaluating to T. The same files evaluate to all-T under SBCL.

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

fn runCorpus(comptime name: []const u8, src: []const u8, expected_forms: u32) !void {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    var tk = Tokenizer.init(src);
    var rd = Reader.init(&tk, &fx.heap, &fx.interner);
    var checked: u32 = 0;
    while (try rd.read()) |form| {
        checked += 1;
        const got = fx.ev.eval(form) catch |e| {
            std.debug.print("{s} form {d}: eval error {s}\n", .{ name, checked, @errorName(e) });
            return e;
        };
        if (!got.equalsRaw(value.T)) {
            std.debug.print("{s} form {d}: expected T\n", .{ name, checked });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(expected_forms, checked);
}

test "destructuring corpus: basic" {
    try runCorpus("basic", @embedFile("../lisp/destructuring/basic.lisp"), 6);
}

test "destructuring corpus: body" {
    try runCorpus("body", @embedFile("../lisp/destructuring/body.lisp"), 4);
}

test "destructuring corpus: whole" {
    try runCorpus("whole", @embedFile("../lisp/destructuring/whole.lisp"), 3);
}

test "destructuring corpus: environment" {
    try runCorpus("environment", @embedFile("../lisp/destructuring/environment.lisp"), 3);
}

test "destructuring corpus: nested" {
    try runCorpus("nested", @embedFile("../lisp/destructuring/nested.lisp"), 5);
}

test "destructuring corpus: nested-deep" {
    try runCorpus("nested-deep", @embedFile("../lisp/destructuring/nested-deep.lisp"), 5);
}

test "destructuring corpus: macroexpand-1 expansions" {
    try runCorpus("expansions", @embedFile("../lisp/macro-destructuring-corpus.lisp"), 30);
}
