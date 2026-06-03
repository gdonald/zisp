const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
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

    fn sym(self: *Fixture, name: []const u8) !value.Value {
        return self.interner.intern(name);
    }

    /// Build a proper list `(elements...)`.
    fn list(self: *Fixture, elements: []const value.Value) !value.Value {
        var tail = value.NIL;
        var i: usize = elements.len;
        while (i > 0) {
            i -= 1;
            tail = try self.heap.allocCons(elements[i], tail);
        }
        return tail;
    }
};

test "quote returns its argument unevaluated" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const quote = fx.interner.lookup("QUOTE").?;
    const x = try fx.sym("X");
    // (quote x) — note x is not bound; if quote evaluated it we'd see
    // UnboundVariable.
    const form = try fx.list(&.{ quote, x });
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(x));
}

test "quote rejects zero args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const quote = fx.interner.lookup("QUOTE").?;
    const form = try fx.list(&.{quote});
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "quote rejects extra args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const quote = fx.interner.lookup("QUOTE").?;
    const a = try fx.sym("A");
    const b = try fx.sym("B");
    const form = try fx.list(&.{ quote, a, b });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "quote rejects dotted args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const quote = fx.interner.lookup("QUOTE").?;
    // (quote . X) — dotted
    const form = try fx.heap.allocCons(quote, try fx.sym("X"));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "if: true branch fires when test is non-NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const form = try fx.list(&.{ if_s, value.T, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "if: else branch fires when test is NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const form = try fx.list(&.{ if_s, value.NIL, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 2), r.toFixnum());
}

test "if: missing else returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const form = try fx.list(&.{ if_s, value.NIL, value.Value.fromFixnum(1) });
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "if: any non-NIL value is truthy (including 0)" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const form = try fx.list(&.{
        if_s,
        value.Value.fromFixnum(0),
        value.Value.fromFixnum(99),
        value.Value.fromFixnum(-1),
    });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 99), r.toFixnum());
}

test "if: untaken branch is not evaluated" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const unbound = try fx.sym("UNBOUND-VAR");
    // (if t 42 unbound) — unbound must not be touched.
    const form = try fx.list(&.{ if_s, value.T, value.Value.fromFixnum(42), unbound });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "if: too few args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{if_s})));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ if_s, value.T })));
}

test "if: too many args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const form = try fx.list(&.{
        if_s,
        value.T,
        value.Value.fromFixnum(1),
        value.Value.fromFixnum(2),
        value.Value.fromFixnum(3),
    });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "if: dotted arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const if_s = fx.interner.lookup("IF").?;
    const dotted_tail = try fx.heap.allocCons(value.Value.fromFixnum(1), value.Value.fromFixnum(2));
    const form = try fx.heap.allocCons(if_s, dotted_tail);
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "progn: empty body returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const progn = fx.interner.lookup("PROGN").?;
    const form = try fx.list(&.{progn});
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "progn: returns last form's value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const progn = fx.interner.lookup("PROGN").?;
    const form = try fx.list(&.{
        progn,
        value.Value.fromFixnum(1),
        value.Value.fromFixnum(2),
        value.Value.fromFixnum(3),
    });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "progn: evaluates each form (side effects via setq)" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const progn = fx.interner.lookup("PROGN").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");

    const set_x_to_5 = try fx.list(&.{ setq, x, value.Value.fromFixnum(5) });
    const form = try fx.list(&.{ progn, set_x_to_5, x });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
}

test "progn: dotted body errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const progn = fx.interner.lookup("PROGN").?;
    const dotted = try fx.heap.allocCons(value.Value.fromFixnum(1), value.Value.fromFixnum(2));
    const form = try fx.heap.allocCons(progn, dotted);
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "setq: assigns global when symbol is unbound" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const form = try fx.list(&.{ setq, x, value.Value.fromFixnum(42) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
    try std.testing.expectEqual(@as(i64, 42), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "setq: returns the LAST assigned value with multiple pairs" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const y = try fx.sym("Y");
    const form = try fx.list(&.{
        setq,
        x,
        value.Value.fromFixnum(1),
        y,
        value.Value.fromFixnum(2),
    });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 2), r.toFixnum());
    try std.testing.expectEqual(@as(i64, 1), symbol_mod.symbol(x).value_cell.toFixnum());
    try std.testing.expectEqual(@as(i64, 2), symbol_mod.symbol(y).value_cell.toFixnum());
}

test "setq: pairs evaluate left-to-right (later pair sees earlier)" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const y = try fx.sym("Y");
    // (setq x 7 y x) — y should observe x=7
    const form = try fx.list(&.{ setq, x, value.Value.fromFixnum(7), y, x });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), symbol_mod.symbol(y).value_cell.toFixnum());
}

test "setq: zero pairs returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const form = try fx.list(&.{setq});
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "setq: trailing odd symbol errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const form = try fx.list(&.{ setq, x });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "setq: non-symbol target errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const form = try fx.list(&.{ setq, value.Value.fromFixnum(0), value.Value.fromFixnum(1) });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "setq: dotted args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const dotted = try fx.heap.allocCons(x, value.Value.fromFixnum(1));
    const form = try fx.heap.allocCons(setq, dotted);
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "setq: mutates innermost lexical binding" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const x = try fx.sym("X");
    try fx.ev.env.bindValue(x, value.Value.fromFixnum(0));

    const setq = fx.interner.lookup("SETQ").?;
    const form = try fx.list(&.{ setq, x, value.Value.fromFixnum(99) });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 99), fx.ev.env.lookupValue(x).?.toFixnum());
}

test "let: bindings visible in body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    const bind = try fx.list(&.{ x, value.Value.fromFixnum(42) });
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, x });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "let: bindings restored after exit" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(7);

    const bind = try fx.list(&.{ x, value.Value.fromFixnum(99) });
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, x });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 99), r.toFixnum());
    // After the let returns, the global is unaffected.
    try std.testing.expectEqual(@as(i64, 7), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "let: parallel binding — init forms see OUTER environment" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(10);

    const let = fx.interner.lookup("LET").?;
    const y = try fx.sym("Y");
    // (let ((x 1) (y x)) y) — y should see outer x=10, not inner x=1.
    const bx = try fx.list(&.{ x, value.Value.fromFixnum(1) });
    const by = try fx.list(&.{ y, x });
    const bindings = try fx.list(&.{ bx, by });
    const form = try fx.list(&.{ let, bindings, y });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 10), r.toFixnum());
}

test "let*: sequential binding — init forms see prior bindings" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lstar = fx.interner.lookup("LET*").?;
    const x = try fx.sym("X");
    const y = try fx.sym("Y");
    // (let* ((x 5) (y x)) y) — y should see inner x=5.
    const bx = try fx.list(&.{ x, value.Value.fromFixnum(5) });
    const by = try fx.list(&.{ y, x });
    const bindings = try fx.list(&.{ bx, by });
    const form = try fx.list(&.{ lstar, bindings, y });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
}

test "let: empty bindings list" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const form = try fx.list(&.{ let, value.NIL, value.Value.fromFixnum(42) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "let: empty body returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    const bind = try fx.list(&.{ x, value.Value.fromFixnum(1) });
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "let: bare-symbol binding defaults to NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    const bindings = try fx.list(&.{x});
    const form = try fx.list(&.{ let, bindings, x });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "let: parenthesised symbol with no init defaults to NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    const bind = try fx.list(&.{x});
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, x });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "let: malformed binding (not symbol or list) errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    // (let (5) ...) — 5 is not a valid binding.
    const bindings = try fx.list(&.{value.Value.fromFixnum(5)});
    const form = try fx.list(&.{ let, bindings, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let: binding with non-symbol head errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    // (let ((5 1)) ...) — 5 isn't a symbol.
    const bind = try fx.list(&.{ value.Value.fromFixnum(5), value.Value.fromFixnum(1) });
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, value.NIL });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "let: binding with too many forms errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    // (let ((x 1 2)) ...) — extra value form.
    const bind = try fx.list(&.{ x, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let: dotted binding pair tail errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    // ((x . 1)) — dotted pair instead of (x 1)
    const bind = try fx.heap.allocCons(x, value.Value.fromFixnum(1));
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let: dotted bindings list errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const x = try fx.sym("X");
    const dotted = try fx.heap.allocCons(x, x);
    const form = try fx.list(&.{ let, dotted, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let: dotted args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const form = try fx.heap.allocCons(let, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let*: dotted args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lstar = fx.interner.lookup("LET*").?;
    const form = try fx.heap.allocCons(lstar, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let*: dotted bindings list errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lstar = fx.interner.lookup("LET*").?;
    const x = try fx.sym("X");
    const dotted = try fx.heap.allocCons(x, x);
    const form = try fx.list(&.{ lstar, dotted, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "let*: bare symbol binding defaults to NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lstar = fx.interner.lookup("LET*").?;
    const x = try fx.sym("X");
    const bindings = try fx.list(&.{x});
    const form = try fx.list(&.{ lstar, bindings, x });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "nested: (let ((x 1)) (if x 'yes 'no))" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const if_s = fx.interner.lookup("IF").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const x = try fx.sym("X");
    const yes = try fx.sym("YES");
    const no = try fx.sym("NO");

    const bind = try fx.list(&.{ x, value.Value.fromFixnum(1) });
    const bindings = try fx.list(&.{bind});
    const yes_form = try fx.list(&.{ quote, yes });
    const no_form = try fx.list(&.{ quote, no });
    const if_form = try fx.list(&.{ if_s, x, yes_form, no_form });
    const form = try fx.list(&.{ let, bindings, if_form });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(yes));
}

fn nativeAddTwo(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    _ = ev_opaque;
    if (args.len != 2) return error.WrongArgCount;
    return value.Value.fromFixnum(args[0].toFixnum() + args[1].toFixnum());
}

test "lambda: returns a callable function value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");
    const params = try fx.list(&.{x});
    // (lambda (x) x)
    const form = try fx.list(&.{ lambda, params, x });

    const r = try fx.ev.eval(form);
    try std.testing.expect(zisp.eval.function.isFunction(r));
    const f = zisp.eval.function.asFunction(r);
    try std.testing.expectEqual(zisp.eval.function.Kind.closure, f.kind);
}

test "lambda: identity via funcall-style application" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");
    const params = try fx.list(&.{x});
    const form = try fx.list(&.{ lambda, params, x });
    const closure = try fx.ev.eval(form);

    const args = [_]value.Value{value.Value.fromFixnum(42)};
    const r = try fx.ev.callFunction(closure, &args);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "lambda: multi-form body returns last value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    // (lambda () 1 2 3)
    const form = try fx.list(&.{
        lambda,
        value.NIL,
        value.Value.fromFixnum(1),
        value.Value.fromFixnum(2),
        value.Value.fromFixnum(3),
    });
    const closure = try fx.ev.eval(form);
    const r = try fx.ev.callFunction(closure, &.{});
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "lambda: empty body returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const form = try fx.list(&.{ lambda, value.NIL });
    const closure = try fx.ev.eval(form);
    const r = try fx.ev.callFunction(closure, &.{});
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "lambda: wrong arg count errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");
    const params = try fx.list(&.{x});
    const form = try fx.list(&.{ lambda, params, x });
    const closure = try fx.ev.eval(form);

    try std.testing.expectError(Error.WrongArgCount, fx.ev.callFunction(closure, &.{}));
    const too_many = [_]value.Value{ value.Value.fromFixnum(1), value.Value.fromFixnum(2) };
    try std.testing.expectError(Error.WrongArgCount, fx.ev.callFunction(closure, &too_many));
}

test "lambda: missing args list errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const form = try fx.list(&.{lambda});
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "lambda: dotted args list errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const form = try fx.heap.allocCons(lambda, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "lambda: non-symbol param rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const params = try fx.list(&.{value.Value.fromFixnum(0)});
    const form = try fx.list(&.{ lambda, params, value.NIL });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "lambda: dotted param list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");
    const dotted_params = try fx.heap.allocCons(x, x);
    const form = try fx.list(&.{ lambda, dotted_params, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "closure: captures lexical environment (counter survives let)" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const lambda = fx.interner.lookup("LAMBDA").?;
    const setq = fx.interner.lookup("SETQ").?;
    const progn = fx.interner.lookup("PROGN").?;
    const counter = try fx.sym("COUNTER");

    // (let ((counter 0)) (lambda () (setq counter (+ counter 1)) counter))
    // Use addTwo as +.
    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);
    const add = fx.interner.lookup("ADD2").?;

    const inc_call = try fx.list(&.{ add, counter, value.Value.fromFixnum(1) });
    const set_form = try fx.list(&.{ setq, counter, inc_call });
    const body = try fx.list(&.{ progn, set_form, counter });
    const lam = try fx.list(&.{ lambda, value.NIL, body });
    const bind = try fx.list(&.{ counter, value.Value.fromFixnum(0) });
    const bindings = try fx.list(&.{bind});
    const let_form = try fx.list(&.{ let, bindings, lam });

    const closure = try fx.ev.eval(let_form);
    // The let frame is gone (popped), but the closure captured it. Each
    // call should see and mutate the captured `counter`.
    try std.testing.expectEqual(@as(i64, 1), (try fx.ev.callFunction(closure, &.{})).toFixnum());
    try std.testing.expectEqual(@as(i64, 2), (try fx.ev.callFunction(closure, &.{})).toFixnum());
    try std.testing.expectEqual(@as(i64, 3), (try fx.ev.callFunction(closure, &.{})).toFixnum());
}

test "closure: sees definition env, not call-site env" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const lambda = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");

    // (let ((x 1)) (lambda () x)) — later bind x to 99 around call site.
    const lam = try fx.list(&.{ lambda, value.NIL, x });
    const bind = try fx.list(&.{ x, value.Value.fromFixnum(1) });
    const bindings = try fx.list(&.{bind});
    const let_form = try fx.list(&.{ let, bindings, lam });
    const closure = try fx.ev.eval(let_form);

    // Now establish a different x in the current env. Closure ignores it.
    try fx.ev.env.bindValue(x, value.Value.fromFixnum(99));
    const r = try fx.ev.callFunction(closure, &.{});
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "function: looks up function cell of a symbol" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);
    const add = fx.interner.lookup("ADD2").?;
    const fn_form = fx.interner.lookup("FUNCTION").?;
    const form = try fx.list(&.{ fn_form, add });

    const r = try fx.ev.eval(form);
    try std.testing.expect(zisp.eval.function.isFunction(r));
}

test "function: unbound function symbol errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const fn_form = fx.interner.lookup("FUNCTION").?;
    const missing = try fx.sym("MISSING-FN");
    const form = try fx.list(&.{ fn_form, missing });
    try std.testing.expectError(Error.UnboundFunction, fx.ev.eval(form));
}

test "function: (function (lambda ...)) returns a closure" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const fn_form = fx.interner.lookup("FUNCTION").?;
    const lambda_sym = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");
    const params = try fx.list(&.{x});
    const lam = try fx.list(&.{ lambda_sym, params, x });
    const form = try fx.list(&.{ fn_form, lam });

    const r = try fx.ev.eval(form);
    try std.testing.expect(zisp.eval.function.isFunction(r));
    const args = [_]value.Value{value.Value.fromFixnum(7)};
    try std.testing.expectEqual(@as(i64, 7), (try fx.ev.callFunction(r, &args)).toFixnum());
}

test "function: non-symbol non-list errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const fn_form = fx.interner.lookup("FUNCTION").?;
    const form = try fx.list(&.{ fn_form, value.Value.fromFixnum(0) });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "function: list whose head isn't LAMBDA errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const fn_form = fx.interner.lookup("FUNCTION").?;
    const foo = try fx.sym("FOO");
    const inner = try fx.list(&.{foo});
    const form = try fx.list(&.{ fn_form, inner });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "function: list with non-symbol head errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const fn_form = fx.interner.lookup("FUNCTION").?;
    const inner = try fx.list(&.{value.Value.fromFixnum(0)});
    const form = try fx.list(&.{ fn_form, inner });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "calling a closure as the head of an evaluated form" {
    // ((function (lambda (x) x)) 5) — head is a symbol bound to a closure
    // via the global function cell.
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const x = try fx.sym("X");
    const params = try fx.list(&.{x});
    const lam_form = try fx.list(&.{ lambda, params, x });
    const closure = try fx.ev.eval(lam_form);

    const id = try fx.sym("ID");
    symbol_mod.symbol(id).function_cell = closure;

    const call = try fx.list(&.{ id, value.Value.fromFixnum(11) });
    const r = try fx.ev.eval(call);
    try std.testing.expectEqual(@as(i64, 11), r.toFixnum());
}

test "callFunction rejects non-function" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.NotCallable, fx.ev.callFunction(value.Value.fromFixnum(0), &.{}));
}

test "flet: local function callable within body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    const x = try fx.sym("X");
    // (flet ((f (x) x)) (f 42))
    const params = try fx.list(&.{x});
    const def = try fx.list(&.{ f, params, x });
    const defs = try fx.list(&.{def});
    const call = try fx.list(&.{ f, value.Value.fromFixnum(42) });
    const form = try fx.list(&.{ flet, defs, call });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "flet: local function not visible after body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    const params = try fx.list(&.{});
    const def = try fx.list(&.{ f, params, value.Value.fromFixnum(1) });
    const defs = try fx.list(&.{def});
    const form = try fx.list(&.{ flet, defs, value.Value.fromFixnum(0) });
    _ = try fx.ev.eval(form);

    // After the flet returns, calling f is an unbound function.
    const call = try fx.list(&.{f});
    try std.testing.expectError(Error.UnboundFunction, fx.ev.eval(call));
}

test "flet: definitions cannot see sibling definitions" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    const g = try fx.sym("G");
    // (flet ((f () 1) (g () (f))) (g))
    // g's body refers to f, but in flet f is NOT visible to g's definition,
    // so calling g signals an unbound function.
    const f_def = try fx.list(&.{ f, value.NIL, value.Value.fromFixnum(1) });
    const g_body = try fx.list(&.{f});
    const g_def = try fx.list(&.{ g, value.NIL, g_body });
    const defs = try fx.list(&.{ f_def, g_def });
    const call = try fx.list(&.{g});
    const form = try fx.list(&.{ flet, defs, call });

    try std.testing.expectError(Error.UnboundFunction, fx.ev.eval(form));
}

test "labels: definitions can call each other" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const labels = fx.interner.lookup("LABELS").?;
    const f = try fx.sym("F");
    const g = try fx.sym("G");
    // (labels ((f () 7) (g () (f))) (g)) — g sees f.
    const f_def = try fx.list(&.{ f, value.NIL, value.Value.fromFixnum(7) });
    const g_body = try fx.list(&.{f});
    const g_def = try fx.list(&.{ g, value.NIL, g_body });
    const defs = try fx.list(&.{ f_def, g_def });
    const call = try fx.list(&.{g});
    const form = try fx.list(&.{ labels, defs, call });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), r.toFixnum());
}

test "labels: recursive self-reference" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const labels = fx.interner.lookup("LABELS").?;
    const if_s = fx.interner.lookup("IF").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const f = try fx.sym("F");
    const n = try fx.sym("N");
    const done = try fx.sym("DONE");

    // (labels ((f (n) (if n (f nil) 'done))) (f t))
    // Called with T: n is truthy, recurse with NIL; n is NIL, return 'done.
    const done_form = try fx.list(&.{ quote, done });
    const rec_call = try fx.list(&.{ f, value.NIL });
    const if_form = try fx.list(&.{ if_s, n, rec_call, done_form });
    const params = try fx.list(&.{n});
    const def = try fx.list(&.{ f, params, if_form });
    const defs = try fx.list(&.{def});
    const call = try fx.list(&.{ f, value.T });
    const form = try fx.list(&.{ labels, defs, call });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(done));
}

test "flet: captures lexical value environment" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const let = fx.interner.lookup("LET").?;
    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    const x = try fx.sym("X");
    // (let ((x 5)) (flet ((f () x)) (f))) — f returns captured x.
    const f_body = x;
    const def = try fx.list(&.{ f, value.NIL, f_body });
    const defs = try fx.list(&.{def});
    const call = try fx.list(&.{f});
    const flet_form = try fx.list(&.{ flet, defs, call });
    const bind = try fx.list(&.{ x, value.Value.fromFixnum(5) });
    const bindings = try fx.list(&.{bind});
    const form = try fx.list(&.{ let, bindings, flet_form });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
}

test "flet: dotted args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const form = try fx.heap.allocCons(flet, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "flet: dotted definitions list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    const def = try fx.list(&.{ f, value.NIL, value.Value.fromFixnum(1) });
    const dotted_defs = try fx.heap.allocCons(def, f);
    const form = try fx.list(&.{ flet, dotted_defs, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "flet: non-cons definition rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const defs = try fx.list(&.{value.Value.fromFixnum(0)});
    const form = try fx.list(&.{ flet, defs, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "flet: non-symbol name rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const def = try fx.list(&.{ value.Value.fromFixnum(0), value.NIL });
    const defs = try fx.list(&.{def});
    const form = try fx.list(&.{ flet, defs, value.NIL });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "flet: definition missing lambda list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    // (flet ((f)) ...) — no lambda list.
    const def = try fx.list(&.{f});
    const defs = try fx.list(&.{def});
    const form = try fx.list(&.{ flet, defs, value.NIL });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "flet: invalid param list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const f = try fx.sym("F");
    // (flet ((f (5)) ...)) — 5 is not a valid parameter symbol.
    const params = try fx.list(&.{value.Value.fromFixnum(5)});
    const def = try fx.list(&.{ f, params, value.NIL });
    const defs = try fx.list(&.{def});
    const form = try fx.list(&.{ flet, defs, value.NIL });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "flet: empty definitions and empty body returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const flet = fx.interner.lookup("FLET").?;
    const form = try fx.list(&.{ flet, value.NIL });
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "labels: shadows outer function of same name within definitions" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const labels = fx.interner.lookup("LABELS").?;
    const g = try fx.sym("G");
    const f = try fx.sym("F");
    // Global f returns via native, but labels f shadows it; g calls f.
    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);

    // (labels ((f () 100) (g () (f))) (g)) — g must reach the local f (100).
    const f_def = try fx.list(&.{ f, value.NIL, value.Value.fromFixnum(100) });
    const g_body = try fx.list(&.{f});
    const g_def = try fx.list(&.{ g, value.NIL, g_body });
    const defs = try fx.list(&.{ f_def, g_def });
    const call = try fx.list(&.{g});
    const form = try fx.list(&.{ labels, defs, call });

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 100), r.toFixnum());
}

test "block: returns last form when no return-from" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const name = try fx.sym("FOO");
    // (block foo 1 2 3)
    const form = try fx.list(&.{
        block,
        name,
        value.Value.fromFixnum(1),
        value.Value.fromFixnum(2),
        value.Value.fromFixnum(3),
    });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "block: empty body returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const name = try fx.sym("FOO");
    const form = try fx.list(&.{ block, name });
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "return-from: exits block with a value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const name = try fx.sym("FOO");
    // (block foo (return-from foo 42) 99) — 99 must not be reached.
    const ret = try fx.list(&.{ rf, name, value.Value.fromFixnum(42) });
    const form = try fx.list(&.{ block, name, ret, value.Value.fromFixnum(99) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "return-from: skips forms after it" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const setq = fx.interner.lookup("SETQ").?;
    const name = try fx.sym("FOO");
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);

    // (block foo (return-from foo 1) (setq x 100))
    const ret = try fx.list(&.{ rf, name, value.Value.fromFixnum(1) });
    const side = try fx.list(&.{ setq, x, value.Value.fromFixnum(100) });
    const form = try fx.list(&.{ block, name, ret, side });
    _ = try fx.ev.eval(form);
    // The setq after the return must not have run.
    try std.testing.expectEqual(@as(i64, 0), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "return-from: no value form returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const name = try fx.sym("FOO");
    // (block foo (return-from foo) 99)
    const ret = try fx.list(&.{ rf, name });
    const form = try fx.list(&.{ block, name, ret, value.Value.fromFixnum(99) });
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "return-from: returns from the named outer block, not inner" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const outer = try fx.sym("OUTER");
    const inner = try fx.sym("INNER");

    // (block outer (block inner (return-from outer 7) 8) 9)
    // return-from outer unwinds past the inner block; the trailing 9 is skipped.
    const ret = try fx.list(&.{ rf, outer, value.Value.fromFixnum(7) });
    const inner_block = try fx.list(&.{ block, inner, ret, value.Value.fromFixnum(8) });
    const form = try fx.list(&.{ block, outer, inner_block, value.Value.fromFixnum(9) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), r.toFixnum());
}

test "return-from: innermost block of matching name wins" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const name = try fx.sym("FOO");

    // (block foo (block foo (return-from foo 1) 2) 3)
    // The return targets the inner foo (value 1), so the inner block yields 1
    // and the outer block then yields 3.
    const ret = try fx.list(&.{ rf, name, value.Value.fromFixnum(1) });
    const inner_block = try fx.list(&.{ block, name, ret, value.Value.fromFixnum(2) });
    const form = try fx.list(&.{ block, name, inner_block, value.Value.fromFixnum(3) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "return-from: unknown block name signals control-error" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const rf = fx.interner.lookup("RETURN-FROM").?;
    const name = try fx.sym("NOPE");
    const form = try fx.list(&.{ rf, name, value.Value.fromFixnum(1) });
    try std.testing.expectError(Error.ControlError, fx.ev.eval(form));
}

test "return-from: escaping an exited block signals control-error" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const lambda = fx.interner.lookup("LAMBDA").?;
    const name = try fx.sym("FOO");

    // (block foo (lambda () (return-from foo 1))) — returns the closure.
    const ret = try fx.list(&.{ rf, name, value.Value.fromFixnum(1) });
    const lam = try fx.list(&.{ lambda, value.NIL, ret });
    const form = try fx.list(&.{ block, name, lam });
    const closure = try fx.ev.eval(form);
    // The block has exited; invoking the closure now must signal control-error.
    try std.testing.expectError(Error.ControlError, fx.ev.callFunction(closure, &.{}));
}

test "block: name must be a symbol" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const form = try fx.list(&.{ block, value.Value.fromFixnum(0) });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "block: missing name errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const form = try fx.list(&.{block});
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "block: dotted args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const form = try fx.heap.allocCons(block, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "return-from: missing name errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const rf = fx.interner.lookup("RETURN-FROM").?;
    const form = try fx.list(&.{rf});
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "return-from: dotted args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const rf = fx.interner.lookup("RETURN-FROM").?;
    const form = try fx.heap.allocCons(rf, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "return-from: non-symbol name errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const rf = fx.interner.lookup("RETURN-FROM").?;
    const form = try fx.list(&.{ rf, value.Value.fromFixnum(0) });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "return-from: extra value forms rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block = fx.interner.lookup("BLOCK").?;
    const rf = fx.interner.lookup("RETURN-FROM").?;
    const name = try fx.sym("FOO");
    // (block foo (return-from foo 1 2)) — two value forms is malformed.
    const ret = try fx.list(&.{ rf, name, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const form = try fx.list(&.{ block, name, ret });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "return-from: dotted value tail rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const rf = fx.interner.lookup("RETURN-FROM").?;
    const name = try fx.sym("FOO");
    // (return-from foo . 1) — dotted tail after the name.
    const dotted = try fx.heap.allocCons(name, value.Value.fromFixnum(1));
    const form = try fx.heap.allocCons(rf, dotted);
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

fn nativeSub1(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    _ = ev_opaque;
    if (args.len != 1) return error.WrongArgCount;
    return value.Value.fromFixnum(args[0].toFixnum() - 1);
}

fn nativeZerop(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    _ = ev_opaque;
    if (args.len != 1) return error.WrongArgCount;
    return if (args[0].toFixnum() == 0) value.T else value.NIL;
}

test "tagbody: empty body returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const r = try fx.ev.eval(try fx.list(&.{tb}));
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "tagbody: only tags, no statements, returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const a = try fx.sym("A");
    const b = try fx.sym("B");
    const r = try fx.ev.eval(try fx.list(&.{ tb, a, b }));
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "tagbody: statements run in order, returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);

    const s1 = try fx.list(&.{ setq, x, value.Value.fromFixnum(5) });
    const r = try fx.ev.eval(try fx.list(&.{ tb, s1 }));
    try std.testing.expect(r.equalsRaw(value.NIL));
    try std.testing.expectEqual(@as(i64, 5), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "go: forward jump skips intervening statements" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const skip = try fx.sym("SKIP");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(1);

    // (tagbody (go skip) (setq x 99) skip (setq x 2))
    const go_skip = try fx.list(&.{ go, skip });
    const set99 = try fx.list(&.{ setq, x, value.Value.fromFixnum(99) });
    const set2 = try fx.list(&.{ setq, x, value.Value.fromFixnum(2) });
    const form = try fx.list(&.{ tb, go_skip, set99, skip, set2 });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 2), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "go: backward jump builds a loop" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);
    _ = try fx.ev.defineNative("SUB1", &nativeSub1);
    _ = try fx.ev.defineNative("ZEROP", &nativeZerop);
    const add = fx.interner.lookup("ADD2").?;
    const sub1 = fx.interner.lookup("SUB1").?;
    const zerop = fx.interner.lookup("ZEROP").?;

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const setq = fx.interner.lookup("SETQ").?;
    const if_s = fx.interner.lookup("IF").?;
    const i = try fx.sym("I");
    const acc = try fx.sym("ACC");
    const top = try fx.sym("TOP");
    symbol_mod.symbol(i).value_cell = value.Value.fromFixnum(3);
    symbol_mod.symbol(acc).value_cell = value.Value.fromFixnum(0);

    // top: (setq acc (+ acc i)) (setq i (- i 1)) (if (zerop i) nil (go top))
    const acc_plus = try fx.list(&.{ add, acc, i });
    const set_acc = try fx.list(&.{ setq, acc, acc_plus });
    const i_minus = try fx.list(&.{ sub1, i });
    const set_i = try fx.list(&.{ setq, i, i_minus });
    const test_form = try fx.list(&.{ zerop, i });
    const go_top = try fx.list(&.{ go, top });
    const if_form = try fx.list(&.{ if_s, test_form, value.NIL, go_top });
    const form = try fx.list(&.{ tb, top, set_acc, set_i, if_form });
    _ = try fx.ev.eval(form);
    // 3 + 2 + 1 = 6
    try std.testing.expectEqual(@as(i64, 6), symbol_mod.symbol(acc).value_cell.toFixnum());
}

test "go: jumps out of a nested tagbody to an outer tag" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const setq = fx.interner.lookup("SETQ").?;
    const r = try fx.sym("R");
    const outer_tag = try fx.sym("OUTER-TAG");
    symbol_mod.symbol(r).value_cell = value.Value.fromFixnum(0);

    // (tagbody (tagbody (go outer-tag)) (setq r 1) outer-tag (setq r 5))
    const go_outer = try fx.list(&.{ go, outer_tag });
    const inner_tb = try fx.list(&.{ tb, go_outer });
    const set1 = try fx.list(&.{ setq, r, value.Value.fromFixnum(1) });
    const set5 = try fx.list(&.{ setq, r, value.Value.fromFixnum(5) });
    const form = try fx.list(&.{ tb, inner_tb, set1, outer_tag, set5 });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 5), symbol_mod.symbol(r).value_cell.toFixnum());
}

test "go: integer tags are supported" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);

    // (tagbody (go 1) (setq x 99) 1 (setq x 7))
    const go1 = try fx.list(&.{ go, value.Value.fromFixnum(1) });
    const set99 = try fx.list(&.{ setq, x, value.Value.fromFixnum(99) });
    const set7 = try fx.list(&.{ setq, x, value.Value.fromFixnum(7) });
    const form = try fx.list(&.{ tb, go1, set99, value.Value.fromFixnum(1), set7 });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "go: unknown tag signals control-error" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const nope = try fx.sym("NOPE");
    // (tagbody (go nope)) — no such tag anywhere.
    const go_nope = try fx.list(&.{ go, nope });
    const form = try fx.list(&.{ tb, go_nope });
    try std.testing.expectError(Error.ControlError, fx.ev.eval(form));
}

test "go: outside any tagbody signals control-error" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const go = fx.interner.lookup("GO").?;
    const foo = try fx.sym("FOO");
    try std.testing.expectError(Error.ControlError, fx.ev.eval(try fx.list(&.{ go, foo })));
}

test "go: escaping an exited tagbody signals control-error" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const lambda = fx.interner.lookup("LAMBDA").?;
    const setq = fx.interner.lookup("SETQ").?;
    const a = try fx.sym("A");
    const f = try fx.sym("F");

    // (tagbody a (setq f (lambda () (go a)))) — capture a closure that gos to a.
    const go_a = try fx.list(&.{ go, a });
    const lam = try fx.list(&.{ lambda, value.NIL, go_a });
    const set_f = try fx.list(&.{ setq, f, lam });
    const form = try fx.list(&.{ tb, a, set_f });
    _ = try fx.ev.eval(form);

    // The tagbody has exited; invoking the closure now must error.
    const closure = symbol_mod.symbol(f).value_cell;
    try std.testing.expectError(Error.ControlError, fx.ev.callFunction(closure, &.{}));
}

test "tagbody: dotted body rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const form = try fx.heap.allocCons(tb, value.Value.fromFixnum(0));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "go: missing tag rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const go = fx.interner.lookup("GO").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{go})));
}

test "go: extra args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const go = fx.interner.lookup("GO").?;
    const a = try fx.sym("A");
    const b = try fx.sym("B");
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ go, a, b })));
}

test "go: non-symbol non-integer tag rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    // (tagbody (go (foo))) — tag is a list, which is not a valid go tag.
    const foo = try fx.sym("FOO");
    const tag_list = try fx.list(&.{foo});
    const go_form = try fx.list(&.{ go, tag_list });
    const form = try fx.list(&.{ tb, go_form });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "catch: body with no throw returns last value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    const tag = try fx.sym(":A");
    // (catch :a 1 2 3)
    const form = try fx.list(&.{
        catch_s,                   tag,
        value.Value.fromFixnum(1), value.Value.fromFixnum(2),
        value.Value.fromFixnum(3),
    });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "throw: transfers value to matching catch" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    const throw_s = fx.interner.lookup("THROW").?;
    const tag = try fx.sym(":A");
    // (catch :a (throw :a 42) 99)
    const thr = try fx.list(&.{ throw_s, tag, value.Value.fromFixnum(42) });
    const form = try fx.list(&.{ catch_s, tag, thr, value.Value.fromFixnum(99) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "catch: empty arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{catch_s})));
}

test "throw: missing tag rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const throw_s = fx.interner.lookup("THROW").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{throw_s})));
}

test "throw: missing result rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const throw_s = fx.interner.lookup("THROW").?;
    const tag = try fx.sym(":A");
    // (throw :a) — no result form
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ throw_s, tag })));
}

test "throw: extra args rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const throw_s = fx.interner.lookup("THROW").?;
    const tag = try fx.sym(":A");
    // (throw :a 1 2) — too many forms
    const form = try fx.list(&.{ throw_s, tag, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "throw: no matching catch signals control-error" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const throw_s = fx.interner.lookup("THROW").?;
    const tag = try fx.sym(":A");
    // (throw :a 1) with no enclosing catch
    const form = try fx.list(&.{ throw_s, tag, value.Value.fromFixnum(1) });
    try std.testing.expectError(Error.ControlError, fx.ev.eval(form));
}

test "throw: unmatched tag propagates past a different catch" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    const throw_s = fx.interner.lookup("THROW").?;
    const a = try fx.sym(":A");
    const b = try fx.sym(":B");
    // (catch :a (catch :b (throw :a 7)) 99) — throw :a skips the :b catch.
    const thr = try fx.list(&.{ throw_s, a, value.Value.fromFixnum(7) });
    const inner = try fx.list(&.{ catch_s, b, thr });
    const form = try fx.list(&.{ catch_s, a, inner, value.Value.fromFixnum(99) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), r.toFixnum());
}

test "unwind-protect: normal completion runs cleanup, returns protected value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    const setq = fx.interner.lookup("SETQ").?;
    const r = try fx.sym("R");
    const cl = try fx.sym("CL");
    symbol_mod.symbol(r).value_cell = value.Value.fromFixnum(0);
    symbol_mod.symbol(cl).value_cell = value.Value.fromFixnum(0);

    // (unwind-protect (setq r 4) (setq cl 8))
    const protected = try fx.list(&.{ setq, r, value.Value.fromFixnum(4) });
    const cleanup = try fx.list(&.{ setq, cl, value.Value.fromFixnum(8) });
    const form = try fx.list(&.{ uwp, protected, cleanup });
    const result = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 4), result.toFixnum());
    try std.testing.expectEqual(@as(i64, 8), symbol_mod.symbol(cl).value_cell.toFixnum());
}

test "unwind-protect: cleanup runs while a throw is in flight" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    const throw_s = fx.interner.lookup("THROW").?;
    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    const setq = fx.interner.lookup("SETQ").?;
    const tag = try fx.sym(":A");
    const cl = try fx.sym("CL");
    symbol_mod.symbol(cl).value_cell = value.Value.fromFixnum(0);

    // (catch :a (unwind-protect (throw :a 1) (setq cl 5)))
    const thr = try fx.list(&.{ throw_s, tag, value.Value.fromFixnum(1) });
    const cleanup = try fx.list(&.{ setq, cl, value.Value.fromFixnum(5) });
    const prot = try fx.list(&.{ uwp, thr, cleanup });
    const form = try fx.list(&.{ catch_s, tag, prot });
    const result = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 1), result.toFixnum());
    try std.testing.expectEqual(@as(i64, 5), symbol_mod.symbol(cl).value_cell.toFixnum());
}

test "unwind-protect: cleanup runs while a go is in flight" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const cl = try fx.sym("CL");
    const skip = try fx.sym("SKIP");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);
    symbol_mod.symbol(cl).value_cell = value.Value.fromFixnum(0);

    // (tagbody (unwind-protect (go skip) (setq cl 5)) (setq x 99) skip (setq x 7))
    const go_skip = try fx.list(&.{ go, skip });
    const cleanup = try fx.list(&.{ setq, cl, value.Value.fromFixnum(5) });
    const prot = try fx.list(&.{ uwp, go_skip, cleanup });
    const set99 = try fx.list(&.{ setq, x, value.Value.fromFixnum(99) });
    const set7 = try fx.list(&.{ setq, x, value.Value.fromFixnum(7) });
    const form = try fx.list(&.{ tb, prot, set99, skip, set7 });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), symbol_mod.symbol(x).value_cell.toFixnum());
    try std.testing.expectEqual(@as(i64, 5), symbol_mod.symbol(cl).value_cell.toFixnum());
}

test "unwind-protect: cleanup runs while a return-from is in flight" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block_s = fx.interner.lookup("BLOCK").?;
    const ret = fx.interner.lookup("RETURN-FROM").?;
    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    const setq = fx.interner.lookup("SETQ").?;
    const b = try fx.sym("B");
    const cl = try fx.sym("CL");
    symbol_mod.symbol(cl).value_cell = value.Value.fromFixnum(0);

    // (block b (unwind-protect (return-from b 3) (setq cl 9)))
    const rf = try fx.list(&.{ ret, b, value.Value.fromFixnum(3) });
    const cleanup = try fx.list(&.{ setq, cl, value.Value.fromFixnum(9) });
    const prot = try fx.list(&.{ uwp, rf, cleanup });
    const form = try fx.list(&.{ block_s, b, prot });
    const result = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 3), result.toFixnum());
    try std.testing.expectEqual(@as(i64, 9), symbol_mod.symbol(cl).value_cell.toFixnum());
}

test "unwind-protect: cleanup's own non-local exit supersedes" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const tb = fx.interner.lookup("TAGBODY").?;
    const go = fx.interner.lookup("GO").?;
    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    const out = try fx.sym("OUT");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);

    // (tagbody (unwind-protect (setq x 1) (go out)) (setq x 2) out (setq x 5))
    const set1 = try fx.list(&.{ setq, x, value.Value.fromFixnum(1) });
    const go_out = try fx.list(&.{ go, out });
    const prot = try fx.list(&.{ uwp, set1, go_out });
    const set2 = try fx.list(&.{ setq, x, value.Value.fromFixnum(2) });
    const set5 = try fx.list(&.{ setq, x, value.Value.fromFixnum(5) });
    const form = try fx.list(&.{ tb, prot, set2, out, set5 });
    _ = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 5), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "unwind-protect: cleanup's own catch does not divert the in-flight throw" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    const throw_s = fx.interner.lookup("THROW").?;
    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    const a = try fx.sym(":A");
    const b = try fx.sym(":B");

    // (catch :a (unwind-protect (throw :a 11) (catch :b (throw :b 22))))
    // The cleanup completes a throw of its own; the outer :a throw must still win.
    const thr_a = try fx.list(&.{ throw_s, a, value.Value.fromFixnum(11) });
    const thr_b = try fx.list(&.{ throw_s, b, value.Value.fromFixnum(22) });
    const inner_catch = try fx.list(&.{ catch_s, b, thr_b });
    const prot = try fx.list(&.{ uwp, thr_a, inner_catch });
    const form = try fx.list(&.{ catch_s, a, prot });
    const result = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 11), result.toFixnum());
}

test "unwind-protect: empty arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const uwp = fx.interner.lookup("UNWIND-PROTECT").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{uwp})));
}

test "the: evaluates the form and ignores the type" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const the = fx.interner.lookup("THE").?;
    const integer = try fx.sym("INTEGER");
    // (the integer 5)
    const form = try fx.list(&.{ the, integer, value.Value.fromFixnum(5) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
}

test "the: a compound type specifier is accepted and ignored" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const the = fx.interner.lookup("THE").?;
    const integer = try fx.sym("INTEGER");
    // (the (integer 0 10) 7) — the unevaluated compound type is ignored.
    const type_spec = try fx.list(&.{ integer, value.Value.fromFixnum(0), value.Value.fromFixnum(10) });
    const form = try fx.list(&.{ the, type_spec, value.Value.fromFixnum(7) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 7), r.toFixnum());
}

test "the: missing arguments rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const the = fx.interner.lookup("THE").?;
    const integer = try fx.sym("INTEGER");
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{the})));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ the, integer })));
}

test "the: extra arguments rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const the = fx.interner.lookup("THE").?;
    const integer = try fx.sym("INTEGER");
    const form = try fx.list(&.{ the, integer, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "declare: accepted and ignored, yields NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const declare = fx.interner.lookup("DECLARE").?;
    const ignore = try fx.sym("IGNORE");
    const x = try fx.sym("X");
    // (declare (ignore x))
    const spec = try fx.list(&.{ ignore, x });
    const form = try fx.list(&.{ declare, spec });
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.NIL));

    // (declare) with no specifiers is also accepted.
    const empty = try fx.ev.eval(try fx.list(&.{declare}));
    try std.testing.expect(empty.equalsRaw(value.NIL));
}

fn nativeList(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    const ev = zisp.eval.Evaluator.fromOpaque(ev_opaque);
    var list = value.NIL;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(args[i], list);
    }
    return list;
}

fn listLen(v: value.Value) usize {
    var n: usize = 0;
    var cur = v;
    while (cur.isCons()) : (cur = heap_mod.cdr(cur)) n += 1;
    return n;
}

test "values: returns all arguments, primary is the first" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const values = fx.interner.lookup("VALUES").?;
    const form = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2), value.Value.fromFixnum(3) });
    const primary = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 1), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 3), fx.ev.values.items.len);
    try std.testing.expectEqual(@as(i64, 3), fx.ev.values.items[2].toFixnum());
}

test "values: no arguments yields zero values, primary NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const values = fx.interner.lookup("VALUES").?;
    const primary = try fx.ev.eval(try fx.list(&.{values}));
    try std.testing.expect(primary.equalsRaw(value.NIL));
    try std.testing.expectEqual(@as(usize, 0), fx.ev.values.items.len);
}

test "values: dotted argument list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const values = fx.interner.lookup("VALUES").?;
    // (values . 5)
    const form = try fx.heap.allocCons(values, value.Value.fromFixnum(5));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "values-list: spreads a list into values" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const vl = fx.interner.lookup("VALUES-LIST").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const list = try fx.list(&.{ value.Value.fromFixnum(10), value.Value.fromFixnum(20) });
    // (values-list '(10 20))
    const form = try fx.list(&.{ vl, try fx.list(&.{ quote, list }) });
    const primary = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 10), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
}

test "values-list: a non-list argument is rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const vl = fx.interner.lookup("VALUES-LIST").?;
    // (values-list 5) — 5 is not a list
    const form = try fx.list(&.{ vl, value.Value.fromFixnum(5) });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "multiple-value-list: collects the values into a fresh list" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvl = fx.interner.lookup("MULTIPLE-VALUE-LIST").?;
    const values = fx.interner.lookup("VALUES").?;
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2), value.Value.fromFixnum(3) });
    // (multiple-value-list (values 1 2 3)) => (1 2 3)
    const r = try fx.ev.eval(try fx.list(&.{ mvl, producer }));
    try std.testing.expectEqual(@as(usize, 3), listLen(r));
    try std.testing.expectEqual(@as(i64, 1), heap_mod.car(r).toFixnum());
    // The list itself is a single value.
    try std.testing.expectEqual(@as(usize, 1), fx.ev.values.items.len);
}

test "multiple-value-call: concatenates producers and applies the function" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("LIST", &nativeList);
    const mvc = fx.interner.lookup("MULTIPLE-VALUE-CALL").?;
    const fn_s = fx.interner.lookup("FUNCTION").?;
    const list_s = fx.interner.lookup("LIST").?;
    const values = fx.interner.lookup("VALUES").?;

    // (multiple-value-call #'list (values 1 2) (values 3 4)) => (1 2 3 4)
    const fref = try fx.list(&.{ fn_s, list_s });
    const p1 = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const p2 = try fx.list(&.{ values, value.Value.fromFixnum(3), value.Value.fromFixnum(4) });
    const r = try fx.ev.eval(try fx.list(&.{ mvc, fref, p1, p2 }));
    try std.testing.expectEqual(@as(usize, 4), listLen(r));
    try std.testing.expectEqual(@as(i64, 4), heap_mod.car(heap_mod.cdr(heap_mod.cdr(heap_mod.cdr(r)))).toFixnum());
}

test "multiple-value-call: resolves a symbol function designator" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("LIST", &nativeList);
    const mvc = fx.interner.lookup("MULTIPLE-VALUE-CALL").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const list_s = fx.interner.lookup("LIST").?;
    const values = fx.interner.lookup("VALUES").?;

    // (multiple-value-call 'list (values 1 2)) => (1 2)
    const fref = try fx.list(&.{ quote, list_s });
    const p1 = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const r = try fx.ev.eval(try fx.list(&.{ mvc, fref, p1 }));
    try std.testing.expectEqual(@as(usize, 2), listLen(r));
}

test "multiple-value-call: empty arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvc = fx.interner.lookup("MULTIPLE-VALUE-CALL").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{mvc})));
}

test "multiple-value-call: dotted arg forms rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("LIST", &nativeList);
    const mvc = fx.interner.lookup("MULTIPLE-VALUE-CALL").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const list_s = fx.interner.lookup("LIST").?;
    const fref = try fx.list(&.{ quote, list_s });
    // (multiple-value-call 'list . 5)
    const form = try fx.heap.allocCons(mvc, try fx.heap.allocCons(fref, value.Value.fromFixnum(5)));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "multiple-value-call: non-callable designator rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvc = fx.interner.lookup("MULTIPLE-VALUE-CALL").?;
    // (multiple-value-call 5) — 5 is neither a function nor a symbol
    try std.testing.expectError(Error.TypeError, fx.ev.eval(try fx.list(&.{ mvc, value.Value.fromFixnum(5) })));
}

test "multiple-value-call: unbound symbol designator rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvc = fx.interner.lookup("MULTIPLE-VALUE-CALL").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const nope = try fx.sym("NOPE");
    const fref = try fx.list(&.{ quote, nope });
    try std.testing.expectError(Error.UnboundFunction, fx.ev.eval(try fx.list(&.{ mvc, fref })));
}

test "multiple-value-prog1: keeps the first form's values, runs the rest for effect" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvp = fx.interner.lookup("MULTIPLE-VALUE-PROG1").?;
    const values = fx.interner.lookup("VALUES").?;
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);

    // (multiple-value-prog1 (values 7 8) (setq x 1))
    const first = try fx.list(&.{ values, value.Value.fromFixnum(7), value.Value.fromFixnum(8) });
    const eff = try fx.list(&.{ setq, x, value.Value.fromFixnum(1) });
    const primary = try fx.ev.eval(try fx.list(&.{ mvp, first, eff }));
    try std.testing.expectEqual(@as(i64, 7), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
    try std.testing.expectEqual(@as(i64, 1), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "multiple-value-prog1: empty arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvp = fx.interner.lookup("MULTIPLE-VALUE-PROG1").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{mvp})));
}

test "multiple-value-prog1: dotted rest rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvp = fx.interner.lookup("MULTIPLE-VALUE-PROG1").?;
    // (multiple-value-prog1 1 . 2)
    const form = try fx.heap.allocCons(mvp, try fx.heap.allocCons(value.Value.fromFixnum(1), value.Value.fromFixnum(2)));
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "multiple-value-bind: binds values, missing become NIL, body propagates" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvb = fx.interner.lookup("MULTIPLE-VALUE-BIND").?;
    const values = fx.interner.lookup("VALUES").?;
    const a = try fx.sym("A");
    const b = try fx.sym("B");
    // (multiple-value-bind (a b) (values 10) (values a b)) => 10, NIL
    const vars = try fx.list(&.{ a, b });
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(10) });
    const body = try fx.list(&.{ values, a, b });
    const primary = try fx.ev.eval(try fx.list(&.{ mvb, vars, producer, body }));
    try std.testing.expectEqual(@as(i64, 10), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
    try std.testing.expect(fx.ev.values.items[1].equalsRaw(value.NIL));
}

test "multiple-value-bind: extra values are ignored" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvb = fx.interner.lookup("MULTIPLE-VALUE-BIND").?;
    const values = fx.interner.lookup("VALUES").?;
    const a = try fx.sym("A");
    // (multiple-value-bind (a) (values 1 2 3) a) => 1
    const vars = try fx.list(&.{a});
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2), value.Value.fromFixnum(3) });
    const r = try fx.ev.eval(try fx.list(&.{ mvb, vars, producer, a }));
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "multiple-value-bind: empty arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvb = fx.interner.lookup("MULTIPLE-VALUE-BIND").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{mvb})));
}

test "multiple-value-bind: missing values form rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvb = fx.interner.lookup("MULTIPLE-VALUE-BIND").?;
    const a = try fx.sym("A");
    // (multiple-value-bind (a)) — no values form
    const vars = try fx.list(&.{a});
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ mvb, vars })));
}

test "multiple-value-bind: dotted variable list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvb = fx.interner.lookup("MULTIPLE-VALUE-BIND").?;
    const values = fx.interner.lookup("VALUES").?;
    const a = try fx.sym("A");
    // (multiple-value-bind (a . b) (values 1) a) — dotted var list
    const vars = try fx.heap.allocCons(a, try fx.sym("B"));
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1) });
    const form = try fx.list(&.{ mvb, vars, producer, a });
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "multiple-value-bind: non-symbol variable rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const mvb = fx.interner.lookup("MULTIPLE-VALUE-BIND").?;
    const values = fx.interner.lookup("VALUES").?;
    // (multiple-value-bind (5) (values 1) 5) — 5 is not a variable name
    const vars = try fx.list(&.{value.Value.fromFixnum(5)});
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1) });
    const form = try fx.list(&.{ mvb, vars, producer, value.Value.fromFixnum(5) });
    try std.testing.expectError(Error.TypeError, fx.ev.eval(form));
}

test "return-from: carries multiple values out of the block" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const block_s = fx.interner.lookup("BLOCK").?;
    const ret = fx.interner.lookup("RETURN-FROM").?;
    const values = fx.interner.lookup("VALUES").?;
    const b = try fx.sym("B");
    // (block b (return-from b (values 1 2)))
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const rf = try fx.list(&.{ ret, b, producer });
    const primary = try fx.ev.eval(try fx.list(&.{ block_s, b, rf }));
    try std.testing.expectEqual(@as(i64, 1), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
    try std.testing.expectEqual(@as(i64, 2), fx.ev.values.items[1].toFixnum());
}

test "throw: carries multiple values out of the catch" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const catch_s = fx.interner.lookup("CATCH").?;
    const throw_s = fx.interner.lookup("THROW").?;
    const values = fx.interner.lookup("VALUES").?;
    const tag = try fx.sym(":A");
    // (catch :a (throw :a (values 1 2)))
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const thr = try fx.list(&.{ throw_s, tag, producer });
    const primary = try fx.ev.eval(try fx.list(&.{ catch_s, tag, thr }));
    try std.testing.expectEqual(@as(i64, 1), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
}

test "the: propagates multiple values from its form" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const the = fx.interner.lookup("THE").?;
    const values = fx.interner.lookup("VALUES").?;
    const t_sym = try fx.sym("T");
    // (the t (values 1 2))
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const primary = try fx.ev.eval(try fx.list(&.{ the, t_sym, producer }));
    try std.testing.expectEqual(@as(i64, 1), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
}

test "eval-when: :execute runs the body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    const execute = try fx.sym(":EXECUTE");
    // (eval-when (:execute) 1 2 3)
    const sits = try fx.list(&.{execute});
    const form = try fx.list(&.{ ew, sits, value.Value.fromFixnum(1), value.Value.fromFixnum(2), value.Value.fromFixnum(3) });
    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "eval-when: deprecated eval situation runs the body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    const eval_s = try fx.sym("EVAL");
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);
    // (eval-when (eval) (setq x 5))
    const sits = try fx.list(&.{eval_s});
    const eff = try fx.list(&.{ setq, x, value.Value.fromFixnum(5) });
    const r = try fx.ev.eval(try fx.list(&.{ ew, sits, eff }));
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
    try std.testing.expectEqual(@as(i64, 5), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "eval-when: compile/load-only situations skip the body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    const ct = try fx.sym(":COMPILE-TOPLEVEL");
    const lt = try fx.sym(":LOAD-TOPLEVEL");
    const setq = fx.interner.lookup("SETQ").?;
    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(0);
    // (eval-when (:compile-toplevel :load-toplevel) (setq x 9))
    const sits = try fx.list(&.{ ct, lt });
    const eff = try fx.list(&.{ setq, x, value.Value.fromFixnum(9) });
    const r = try fx.ev.eval(try fx.list(&.{ ew, sits, eff }));
    try std.testing.expect(r.equalsRaw(value.NIL));
    // The body did not run.
    try std.testing.expectEqual(@as(i64, 0), symbol_mod.symbol(x).value_cell.toFixnum());
}

test "eval-when: empty situation list yields NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    // (eval-when () 1)
    const r = try fx.ev.eval(try fx.list(&.{ ew, value.NIL, value.Value.fromFixnum(1) }));
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "eval-when: empty arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ew})));
}

test "eval-when: situations must be a proper list" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    const execute = try fx.sym(":EXECUTE");
    // (eval-when :execute 1) — situations is an atom, not a list
    try std.testing.expectError(Error.BadArgList, fx.ev.eval(try fx.list(&.{ ew, execute, value.Value.fromFixnum(1) })));
}

test "eval-when: non-symbol situation rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    // (eval-when (5) 1)
    const sits = try fx.list(&.{value.Value.fromFixnum(5)});
    try std.testing.expectError(Error.TypeError, fx.ev.eval(try fx.list(&.{ ew, sits, value.Value.fromFixnum(1) })));
}

test "eval-when: propagates multiple values from the body" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ew = fx.interner.lookup("EVAL-WHEN").?;
    const execute = try fx.sym(":EXECUTE");
    const values = fx.interner.lookup("VALUES").?;
    // (eval-when (:execute) (values 1 2))
    const sits = try fx.list(&.{execute});
    const producer = try fx.list(&.{ values, value.Value.fromFixnum(1), value.Value.fromFixnum(2) });
    const primary = try fx.ev.eval(try fx.list(&.{ ew, sits, producer }));
    try std.testing.expectEqual(@as(i64, 1), primary.toFixnum());
    try std.testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
}

test "closure: dotted body errors at call time" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // Build a closure with a dotted body manually via allocClosure since the
    // lambda special form would reject this at construction.
    const dotted_body = try fx.heap.allocCons(value.Value.fromFixnum(1), value.Value.fromFixnum(2));
    const closure = try zisp.eval.function.allocClosure(
        fx.heap.allocator,
        null,
        value.NIL,
        dotted_body,
        null,
        null,
    );
    try std.testing.expectError(Error.BadArgList, fx.ev.callFunction(closure, &.{}));
}
