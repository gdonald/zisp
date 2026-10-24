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
        fx.ev.io = testing.io;
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
    try testing.expectEqual(@as(u32, 42), checked);
}

test "reader syntax corpus" {
    const checked = try runCorpus("reader-syntax", @embedFile("lisp/reader-syntax-corpus.lisp"));
    try testing.expectEqual(@as(u32, 26), checked);
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
    try testing.expectEqual(@as(u32, 21), checked);
}

test "macrolet corpus" {
    const checked = try runCorpus("macrolet", @embedFile("lisp/macrolet-corpus.lisp"));
    try testing.expectEqual(@as(u32, 12), checked);
}

test "restart corpus" {
    const checked = try runCorpus("restart", @embedFile("lisp/restart-corpus.lisp"));
    try testing.expectEqual(@as(u32, 34), checked);
}

test "with-condition-restarts corpus" {
    const checked = try runCorpus("with-condition-restarts", @embedFile("lisp/with-condition-restarts.lisp"));
    try testing.expectEqual(@as(u32, 6), checked);
}

test "symbol-macrolet corpus" {
    const checked = try runCorpus("symbol-macrolet", @embedFile("lisp/symbol-macrolet-corpus.lisp"));
    try testing.expectEqual(@as(u32, 10), checked);
}

test "special declaration corpus" {
    const checked = try runCorpus("special-declaration", @embedFile("lisp/special-declaration-corpus.lisp"));
    try testing.expectEqual(@as(u32, 8), checked);
}

test "function body corpus" {
    const checked = try runCorpus("function-body", @embedFile("lisp/function-body-corpus.lisp"));
    try testing.expectEqual(@as(u32, 19), checked);
}

test "subtypep corpus" {
    const checked = try runCorpus("subtypep", @embedFile("lisp/subtypep-corpus.lisp"));
    try testing.expectEqual(@as(u32, 155), checked);
}

test "unwind-protect corpus" {
    const checked = try runCorpus("unwind-protect", @embedFile("lisp/unwind-protect-corpus.lisp"));
    try testing.expectEqual(@as(u32, 22), checked);
}

test "defclass, slot options and slot access corpus" {
    const checked = try runCorpus("clos-classes", @embedFile("lisp/clos-classes.lisp"));
    try testing.expectEqual(@as(u32, 44), checked);
}

test "initialization protocol corpus" {
    const checked = try runCorpus("init-protocol", @embedFile("lisp/init-protocol.lisp"));
    try testing.expectEqual(@as(u32, 13), checked);
}

test "generic functions and method combinations corpus" {
    const checked = try runCorpus("clos-generic", @embedFile("lisp/clos-generic.lisp"));
    try testing.expectEqual(@as(u32, 49), checked);
}

test "define-method-combination long form corpus" {
    const checked = try runCorpus("dmc-long-form", @embedFile("lisp/dmc-long-form.lisp"));
    try testing.expectEqual(@as(u32, 15), checked);
}

test "class redefinition corpus" {
    const checked = try runCorpus("class-redef", @embedFile("lisp/class-redef.lisp"));
    try testing.expectEqual(@as(u32, 16), checked);
}

test "change-class corpus" {
    const checked = try runCorpus("clos-redef", @embedFile("lisp/clos-redef.lisp"));
    try testing.expectEqual(@as(u32, 11), checked);
}

test "class precedence list corpus" {
    const checked = try runCorpus("c3", @embedFile("lisp/c3-corpus.lisp"));
    try testing.expectEqual(@as(u32, 11), checked);
}

test "metaobject protocol corpus" {
    const checked = try runCorpus("clos-mop", @embedFile("lisp/clos-mop.lisp"));
    try testing.expectEqual(@as(u32, 33), checked);
}

test "define-method-combination long form parsing corpus" {
    const checked = try runCorpus("dmc-parse", @embedFile("lisp/dmc-parse.lisp"));
    try testing.expectEqual(@as(u32, 5), checked);
}

test "slot definition introspection corpus" {
    const checked = try runCorpus("slot-introspection", @embedFile("lisp/slot-introspection.lisp"));
    try testing.expectEqual(@as(u32, 8), checked);
}

test "validate-superclass corpus" {
    const checked = try runCorpus("validate-superclass", @embedFile("lisp/validate-superclass.lisp"));
    try testing.expectEqual(@as(u32, 4), checked);
}

test "print-object dispatch corpus" {
    const checked = try runCorpus("print-object", @embedFile("lisp/print-object-dispatch.lisp"));
    try testing.expectEqual(@as(u32, 22), checked);
}
