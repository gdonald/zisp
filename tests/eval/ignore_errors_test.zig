//! `ignore-errors`: which failures it absorbs, what it returns for each
//! outcome, and which transfers of control it must let through.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

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

    fn evalStr(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| {
            result = try self.ev.eval(form);
        }
        return result;
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

test "a body that completes returns its last value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 3), (try fx.evalStr("(ignore-errors 1 2 3)")).toFixnum());
}

test "an empty body returns nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expect((try fx.evalStr("(ignore-errors)")).equalsRaw(value.NIL));
}

test "an error yields nil and a keyword naming it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr("(ignore-errors (no-such-function))");
    try testing.expect(v.equalsRaw(value.NIL));
    try testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
    try testing.expectEqualStrings("UnboundFunction", symbol_mod.name(fx.ev.values.items[1]));
}

test "an unbound variable is absorbed too" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expect((try fx.evalStr("(ignore-errors no-such-variable)")).equalsRaw(value.NIL));
    try testing.expectEqualStrings("UnboundVariable", symbol_mod.name(fx.ev.values.items[1]));
}

test "a type error from a builtin is absorbed" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expect((try fx.evalStr("(ignore-errors (rplaca 1 2))")).equalsRaw(value.NIL));
    try testing.expectEqualStrings("TypeError", symbol_mod.name(fx.ev.values.items[1]));
}

test "forms before the failing one still run for effect" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr(
        \\(defvar *seen* nil)
        \\(ignore-errors (setq *seen* 1) (no-such-function))
        \\*seen*
    );
    try testing.expectEqual(@as(i64, 1), v.toFixnum());
}

test "return-from passes through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr("(block out (ignore-errors (return-from out 7)) 0)");
    try testing.expectEqual(@as(i64, 7), v.toFixnum());
}

test "throw passes through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr("(catch 'tag (ignore-errors (throw 'tag 8)) 0)");
    try testing.expectEqual(@as(i64, 8), v.toFixnum());
}

test "go passes through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr(
        \\(let ((n 0))
        \\  (tagbody
        \\    (ignore-errors (go done))
        \\    (setq n 1)
        \\   done)
        \\  n)
    );
    try testing.expectEqual(@as(i64, 0), v.toFixnum());
}

test "a malformed body is absorbed like any other error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expect((try fx.evalStr("(ignore-errors . 5)")).equalsRaw(value.NIL));
    try testing.expectEqualStrings("BadArgList", symbol_mod.name(fx.ev.values.items[1]));
}
