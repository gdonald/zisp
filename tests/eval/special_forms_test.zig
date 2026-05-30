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
