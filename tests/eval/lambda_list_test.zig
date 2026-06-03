//! Ordinary lambda-list binding: &optional, &rest, &key, &aux, supplied-p,
//! and argument-count / keyword-argument error handling.

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const heap_mod = zisp.heap;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;

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
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Read and evaluate a single form from source.
    fn eval(self: *Fixture, src: []const u8) !value.Value {
        var tk = Tokenizer.init(src);
        var rd = Reader.init(&tk, &self.heap, &self.interner);
        const form = (try rd.read()).?;
        return self.ev.eval(form);
    }

    /// Read, evaluate, and require the result to be a callable closure.
    fn closure(self: *Fixture, src: []const u8) !value.Value {
        return self.eval(src);
    }

    fn sym(self: *Fixture, name: []const u8) !value.Value {
        return self.interner.intern(name);
    }

    fn fix(n: i64) value.Value {
        return value.Value.fromFixnum(n);
    }
};

fn expectValues(fx: *Fixture, expected: []const i64) !void {
    try std.testing.expectEqual(expected.len, fx.ev.values.items.len);
    for (expected, fx.ev.values.items) |want, got| {
        try std.testing.expectEqual(want, got.toFixnum());
    }
}

test "required parameters bind positionally" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a b) (values a b))");
    _ = try fx.ev.callFunction(c, &.{ Fixture.fix(1), Fixture.fix(2) });
    try expectValues(fx, &.{ 1, 2 });
}

test "too few required arguments errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a b) a)");
    try std.testing.expectError(Error.WrongArgCount, fx.ev.callFunction(c, &.{Fixture.fix(1)}));
}

test "too many arguments without &rest or &key errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a) a)");
    try std.testing.expectError(Error.WrongArgCount, fx.ev.callFunction(c, &.{ Fixture.fix(1), Fixture.fix(2) }));
}

test "&optional uses the supplied value when present" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a &optional b) (values a b))");
    _ = try fx.ev.callFunction(c, &.{ Fixture.fix(1), Fixture.fix(9) });
    try expectValues(fx, &.{ 1, 9 });
}

test "&optional falls back to NIL and its default form" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // b defaults to NIL, c defaults to 7
    const c = try fx.closure("(lambda (a &optional b (c 7)) (values a b c))");
    _ = try fx.ev.callFunction(c, &.{Fixture.fix(1)});
    try std.testing.expectEqual(@as(usize, 3), fx.ev.values.items.len);
    try std.testing.expectEqual(@as(i64, 1), fx.ev.values.items[0].toFixnum());
    try std.testing.expect(fx.ev.values.items[1].equalsRaw(value.NIL));
    try std.testing.expectEqual(@as(i64, 7), fx.ev.values.items[2].toFixnum());
}

test "&optional default sees earlier parameters" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // c defaults to the value of a
    const c = try fx.closure("(lambda (a &optional (c a)) (values a c))");
    _ = try fx.ev.callFunction(c, &.{Fixture.fix(4)});
    try expectValues(fx, &.{ 4, 4 });
}

test "&optional supplied-p flags track presence" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&optional (b 0 b-p)) (values b b-p))");
    // present
    _ = try fx.ev.callFunction(c, &.{Fixture.fix(5)});
    try std.testing.expectEqual(@as(i64, 5), fx.ev.values.items[0].toFixnum());
    try std.testing.expect(fx.ev.values.items[1].equalsRaw(value.T));
    // absent
    _ = try fx.ev.callFunction(c, &.{});
    try std.testing.expectEqual(@as(i64, 0), fx.ev.values.items[0].toFixnum());
    try std.testing.expect(fx.ev.values.items[1].equalsRaw(value.NIL));
}

test "&rest collects the remaining arguments" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a &rest more) more)");
    const r = try fx.ev.callFunction(c, &.{ Fixture.fix(1), Fixture.fix(2), Fixture.fix(3) });
    try std.testing.expectEqual(@as(i64, 2), heap_mod.car(r).toFixnum());
    try std.testing.expectEqual(@as(i64, 3), heap_mod.car(heap_mod.cdr(r)).toFixnum());
    try std.testing.expect(heap_mod.cdr(heap_mod.cdr(r)).equalsRaw(value.NIL));
}

test "&rest is NIL when no extra arguments remain" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a &rest more) more)");
    const r = try fx.ev.callFunction(c, &.{Fixture.fix(1)});
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "&key binds by keyword and defaults the rest" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a (b 10)) (values a b))");
    const ka = try fx.sym(":A");
    _ = try fx.ev.callFunction(c, &.{ ka, Fixture.fix(1) });
    try expectValues(fx, &.{ 1, 10 });
}

test "&key supplied-p tracks presence" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key (a 0 a-p)) (values a a-p))");
    const ka = try fx.sym(":A");
    _ = try fx.ev.callFunction(c, &.{ ka, Fixture.fix(3) });
    try std.testing.expectEqual(@as(i64, 3), fx.ev.values.items[0].toFixnum());
    try std.testing.expect(fx.ev.values.items[1].equalsRaw(value.T));
    _ = try fx.ev.callFunction(c, &.{});
    try std.testing.expect(fx.ev.values.items[1].equalsRaw(value.NIL));
}

test "&key with an explicit keyword name" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // bind local var X via keyword :the-key
    const c = try fx.closure("(lambda (&key ((:the-key x) 0)) x)");
    const k = try fx.sym(":THE-KEY");
    const r = try fx.ev.callFunction(c, &.{ k, Fixture.fix(42) });
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "&key duplicate keyword: first occurrence wins" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a) a)");
    const ka = try fx.sym(":A");
    const r = try fx.ev.callFunction(c, &.{ ka, Fixture.fix(1), ka, Fixture.fix(2) });
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "&key unknown keyword errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a) a)");
    const kb = try fx.sym(":B");
    try std.testing.expectError(Error.ProgramError, fx.ev.callFunction(c, &.{ kb, Fixture.fix(1) }));
}

test "&key with &allow-other-keys accepts unknown keywords" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a &allow-other-keys) a)");
    const ka = try fx.sym(":A");
    const kb = try fx.sym(":B");
    const r = try fx.ev.callFunction(c, &.{ ka, Fixture.fix(1), kb, Fixture.fix(2) });
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "&key caller :allow-other-keys t overrides strictness" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a) a)");
    const ka = try fx.sym(":A");
    const kb = try fx.sym(":B");
    const aok = try fx.sym(":ALLOW-OTHER-KEYS");
    const r = try fx.ev.callFunction(c, &.{ ka, Fixture.fix(1), kb, Fixture.fix(2), aok, value.T });
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "&key caller :allow-other-keys nil keeps strictness" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a) a)");
    const ka = try fx.sym(":A");
    const kb = try fx.sym(":B");
    const aok = try fx.sym(":ALLOW-OTHER-KEYS");
    try std.testing.expectError(Error.ProgramError, fx.ev.callFunction(c, &.{ ka, Fixture.fix(1), kb, Fixture.fix(2), aok, value.NIL }));
}

test "&key odd number of keyword arguments errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a) a)");
    const ka = try fx.sym(":A");
    try std.testing.expectError(Error.ProgramError, fx.ev.callFunction(c, &.{ka}));
}

test "&key non-symbol in keyword position errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&key a) a)");
    try std.testing.expectError(Error.ProgramError, fx.ev.callFunction(c, &.{ Fixture.fix(7), Fixture.fix(1) }));
}

test "&rest and &key coexist over the same tail" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (&rest r &key a) (values a r))");
    const ka = try fx.sym(":A");
    _ = try fx.ev.callFunction(c, &.{ ka, Fixture.fix(5) });
    // a = 5; r = (:a 5)
    try std.testing.expectEqual(@as(i64, 5), fx.ev.values.items[0].toFixnum());
    const r = fx.ev.values.items[1];
    try std.testing.expect(heap_mod.car(r).equalsRaw(ka));
    try std.testing.expectEqual(@as(i64, 5), heap_mod.car(heap_mod.cdr(r)).toFixnum());
}

test "&aux binds locals from init forms" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a &aux (b a) c) (values a b c))");
    _ = try fx.ev.callFunction(c, &.{Fixture.fix(8)});
    try std.testing.expectEqual(@as(usize, 3), fx.ev.values.items.len);
    try std.testing.expectEqual(@as(i64, 8), fx.ev.values.items[0].toFixnum());
    try std.testing.expectEqual(@as(i64, 8), fx.ev.values.items[1].toFixnum());
    try std.testing.expect(fx.ev.values.items[2].equalsRaw(value.NIL));
}

test "full lambda list combines all sections" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const c = try fx.closure("(lambda (a &optional (b 2) &rest r &key (k 3)) (values a b r k))");
    const kk = try fx.sym(":K");
    _ = try fx.ev.callFunction(c, &.{ Fixture.fix(1), Fixture.fix(20), kk, Fixture.fix(30) });
    // a=1, b=20, r=(:k 30), k=30
    try std.testing.expectEqual(@as(i64, 1), fx.ev.values.items[0].toFixnum());
    try std.testing.expectEqual(@as(i64, 20), fx.ev.values.items[1].toFixnum());
    try std.testing.expectEqual(@as(i64, 30), fx.ev.values.items[3].toFixnum());
}

// --- malformed lambda lists rejected at closure construction ---

fn expectBadLambda(comptime src: []const u8, err: Error) !void {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);
    try std.testing.expectError(err, fx.eval(src));
}

test "dotted parameter list rejected" {
    try expectBadLambda("(lambda (a . b) a)", Error.BadArgList);
}

test "non-symbol required parameter rejected" {
    try expectBadLambda("(lambda (5) 1)", Error.TypeError);
}

test "&optional with a non-symbol name rejected" {
    try expectBadLambda("(lambda (&optional (5 0)) 1)", Error.TypeError);
}

test "&optional with a non-symbol supplied-p rejected" {
    try expectBadLambda("(lambda (&optional (a 0 5)) 1)", Error.TypeError);
}

test "&optional spec with trailing junk rejected" {
    try expectBadLambda("(lambda (&optional (a 0 a-p x)) 1)", Error.BadArgList);
}

test "&optional non-symbol non-list element rejected" {
    try expectBadLambda("(lambda (&optional 5) 1)", Error.BadArgList);
}

test "second &rest variable rejected" {
    try expectBadLambda("(lambda (&rest a b) a)", Error.BadArgList);
}

test "&rest with a non-symbol variable rejected" {
    try expectBadLambda("(lambda (&rest 5) 1)", Error.TypeError);
}

test "&rest with no variable rejected" {
    try expectBadLambda("(lambda (a &rest) a)", Error.BadArgList);
}

test "&key non-symbol element rejected" {
    try expectBadLambda("(lambda (&key 5) 1)", Error.BadArgList);
}

test "&key explicit keyword with non-symbol keyword rejected" {
    try expectBadLambda("(lambda (&key ((5 x))) 1)", Error.TypeError);
}

test "&key explicit keyword missing variable rejected" {
    try expectBadLambda("(lambda (&key ((:k))) 1)", Error.BadArgList);
}

test "&key explicit keyword with non-symbol variable rejected" {
    try expectBadLambda("(lambda (&key ((:k 5))) 1)", Error.TypeError);
}

test "&key explicit keyword with trailing junk rejected" {
    try expectBadLambda("(lambda (&key ((:k x y))) 1)", Error.BadArgList);
}

test "&aux with a non-symbol name rejected" {
    try expectBadLambda("(lambda (&aux (5 0)) 1)", Error.TypeError);
}

test "&aux spec with trailing junk rejected" {
    try expectBadLambda("(lambda (&aux (a 0 junk)) 1)", Error.BadArgList);
}

test "&aux spec with a dotted tail rejected" {
    try expectBadLambda("(lambda (&aux (a . 5)) 1)", Error.BadArgList);
}

test "&optional spec with a dotted tail rejected" {
    try expectBadLambda("(lambda (&optional (a . 5)) 1)", Error.BadArgList);
}

test "&optional spec with a dotted tail after the init rejected" {
    try expectBadLambda("(lambda (&optional (a 0 . 5)) 1)", Error.BadArgList);
}
