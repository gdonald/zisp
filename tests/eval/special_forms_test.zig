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
    );
    try std.testing.expectError(Error.BadArgList, fx.ev.callFunction(closure, &.{}));
}
