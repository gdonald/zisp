//! Acceptance corpora written in Lisp.
//!
//! Each file under `tests/lisp/` listed here holds self-checking forms:
//! every top-level form must evaluate to T.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
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
            .interner = try symbol_mod.Interner.init(allocator),
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

/// Evaluate every form in `text`, requiring T from each, and return how
/// many were checked.
fn runCorpus(name: []const u8, text: []const u8) !u32 {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var tk = zisp.reader.Tokenizer.init(text);
    var rd = zisp.reader.Reader.init(&tk, &fx.heap, &fx.interner);
    rd.read_eval = .{ .context = @ptrCast(&fx.ev), .call = &Evaluator.readEval };
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
    return checked;
}

test "loop corpus" {
    const checked = try runCorpus("loop", @embedFile("lisp/loop-corpus.lisp"));
    try testing.expectEqual(@as(u32, 39), checked);
}

test "do, dolist, dotimes and psetq corpus" {
    const checked = try runCorpus("iteration", @embedFile("lisp/iteration-corpus.lisp"));
    try testing.expectEqual(@as(u32, 16), checked);
}

test "do and do* corpus" {
    const checked = try runCorpus("do", @embedFile("lisp/do-corpus.lisp"));
    try testing.expectEqual(@as(u32, 9), checked);
}

test "list and plist corpus" {
    const checked = try runCorpus("list", @embedFile("lisp/list-corpus.lisp"));
    try testing.expectEqual(@as(u32, 79), checked);
}

test "sequence corpus" {
    const checked = try runCorpus("sequence", @embedFile("lisp/sequence-corpus.lisp"));
    try testing.expectEqual(@as(u32, 30), checked);
}

test "handler-case corpus" {
    const checked = try runCorpus("handler-case", @embedFile("lisp/handler-case-corpus.lisp"));
    try testing.expectEqual(@as(u32, 11), checked);
}

test "closure capture corpus" {
    const checked = try runCorpus("closure-capture", @embedFile("lisp/closure-capture-corpus.lisp"));
    try testing.expectEqual(@as(u32, 8), checked);
}

test "format directives corpus" {
    const checked = try runCorpus("format", @embedFile("lisp/format-directives-corpus.lisp"));
    try testing.expectEqual(@as(u32, 22), checked);
}

test "reader syntax corpus" {
    const checked = try runCorpus("reader-syntax", @embedFile("lisp/reader-syntax-corpus.lisp"));
    try testing.expectEqual(@as(u32, 19), checked);
}

test "displaced string corpus" {
    const checked = try runCorpus("displaced-string", @embedFile("lisp/displaced-string-corpus.lisp"));
    try testing.expectEqual(@as(u32, 8), checked);
}

test "condition class corpus" {
    const checked = try runCorpus("condition-class", @embedFile("lisp/condition-class-corpus.lisp"));
    try testing.expectEqual(@as(u32, 49), checked);
}

test "handler search corpus" {
    const checked = try runCorpus("handler-search", @embedFile("lisp/handler-search.lisp"));
    try testing.expectEqual(@as(u32, 12), checked);
}
