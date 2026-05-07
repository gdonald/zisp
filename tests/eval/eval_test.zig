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
};

test "self-evaluating: fixnum returns itself" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const v = value.Value.fromFixnum(42);
    const r = try fx.ev.eval(v);
    try std.testing.expect(r.equalsRaw(v));
}

test "self-evaluating: NIL and T" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expect((try fx.ev.eval(value.NIL)).equalsRaw(value.NIL));
    try std.testing.expect((try fx.ev.eval(value.T)).equalsRaw(value.T));
}

test "self-evaluating: character" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const ch = value.Value.fromChar('A');
    const r = try fx.ev.eval(ch);
    try std.testing.expect(r.equalsRaw(ch));
}

test "self-evaluating: string" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const s = try fx.heap.allocString("hello");
    const r = try fx.ev.eval(s);
    try std.testing.expect(r.equalsRaw(s));
}

test "self-evaluating: float" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const f = try fx.heap.allocSingleFloat(3.14);
    const r = try fx.ev.eval(f);
    try std.testing.expect(r.equalsRaw(f));
}

test "self-evaluating: keyword" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const kw = try fx.sym(":FOO");
    const r = try fx.ev.eval(kw);
    try std.testing.expect(r.equalsRaw(kw));
}

test "self-evaluating: special (EOF immediate)" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.ev.eval(value.SPECIAL_EOF);
    try std.testing.expect(r.equalsRaw(value.SPECIAL_EOF));
}

test "symbol eval: lexical binding wins" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const x = try fx.sym("X");
    try fx.ev.env.bindValue(x, value.Value.fromFixnum(10));
    const r = try fx.ev.eval(x);
    try std.testing.expectEqual(@as(i64, 10), r.toFixnum());
}

test "symbol eval: falls back to global value cell" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const x = try fx.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(7);
    const r = try fx.ev.eval(x);
    try std.testing.expectEqual(@as(i64, 7), r.toFixnum());
}

test "symbol eval: unbound returns UnboundVariable" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const x = try fx.sym("X");
    try std.testing.expectError(Error.UnboundVariable, fx.ev.eval(x));
}

fn testQuote(ev: *Evaluator, args: value.Value) Error!value.Value {
    _ = ev;
    if (!args.isCons()) return Error.BadArgList;
    return heap_mod.car(args);
}

test "special form dispatch: registered handler runs" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try fx.ev.registerSpecialForm("QUOTE", &testQuote);
    const quote_sym = fx.interner.lookup("QUOTE").?;
    const inner = value.Value.fromFixnum(99);
    const arglist = try fx.heap.allocCons(inner, value.NIL);
    const form = try fx.heap.allocCons(quote_sym, arglist);

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(inner));
}

test "lookupSpecialForm returns null for unknown symbol" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const sym = try fx.sym("UNKNOWN");
    try std.testing.expect(fx.ev.lookupSpecialForm(sym) == null);
}

const StubExpander = struct {
    var fixed_result: ?value.Value = null;

    fn expand(ev: *Evaluator, form: value.Value) Error!?value.Value {
        _ = ev;
        _ = form;
        return fixed_result;
    }
};

test "macro_expander default returns null (no expansion happens)" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const sym = try fx.sym("UNBOUND-MACRO");
    const form = try fx.heap.allocCons(sym, value.NIL);
    // No special form, no global function → falls to UnboundFunction.
    try std.testing.expectError(Error.UnboundFunction, fx.ev.eval(form));
}

test "macro_expander hook: expanded form is recursively evaluated" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // Stub macro expander rewrites every cons form to the literal 42.
    StubExpander.fixed_result = value.Value.fromFixnum(42);
    fx.ev.macro_expander = &StubExpander.expand;
    defer StubExpander.fixed_result = null;

    const sym = try fx.sym("MAC");
    const form = try fx.heap.allocCons(sym, value.NIL);

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "eval rejects reserved-tag values with TypeError" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const bogus = value.Value{ .raw = 0b110 };
    try std.testing.expectError(Error.TypeError, fx.ev.eval(bogus));
}

fn nativeAddTwo(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    _ = ev_opaque;
    if (args.len != 2) return error.WrongArgCount;
    return value.Value.fromFixnum(args[0].toFixnum() + args[1].toFixnum());
}

test "function application: native primitive evaluates args and returns" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);
    const add = fx.interner.lookup("ADD2").?;
    const arg2 = try fx.heap.allocCons(value.Value.fromFixnum(5), value.NIL);
    const arg1 = try fx.heap.allocCons(value.Value.fromFixnum(3), arg2);
    const form = try fx.heap.allocCons(add, arg1);

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 8), r.toFixnum());
}

test "function application: arguments are evaluated before call" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);
    const add = fx.interner.lookup("ADD2").?;
    const x = try fx.sym("X");
    try fx.ev.env.bindValue(x, value.Value.fromFixnum(40));

    const arg2 = try fx.heap.allocCons(value.Value.fromFixnum(2), value.NIL);
    const arg1 = try fx.heap.allocCons(x, arg2);
    const form = try fx.heap.allocCons(add, arg1);

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 42), r.toFixnum());
}

test "function application: unbound function symbol errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const f = try fx.sym("MISSING");
    const form = try fx.heap.allocCons(f, value.NIL);
    try std.testing.expectError(Error.UnboundFunction, fx.ev.eval(form));
}

test "function application: non-function in function cell errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const f = try fx.sym("BOGUS");
    // Stuff a fixnum into the function cell.
    symbol_mod.symbol(f).function_cell = value.Value.fromFixnum(0);
    const form = try fx.heap.allocCons(f, value.NIL);
    try std.testing.expectError(Error.NotCallable, fx.ev.eval(form));
}

test "function application: dotted arg list rejected" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ADD2", &nativeAddTwo);
    const add = fx.interner.lookup("ADD2").?;
    // (ADD2 3 . 5) — dotted tail is not a valid arg list.
    const dotted = try fx.heap.allocCons(value.Value.fromFixnum(3), value.Value.fromFixnum(5));
    const form = try fx.heap.allocCons(add, dotted);

    try std.testing.expectError(Error.BadArgList, fx.ev.eval(form));
}

test "cons with non-symbol head errors NotCallable" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // ((1 2) 3) — head is a list, not a symbol; lambda forms wait for 2.3.7.
    const inner_b = try fx.heap.allocCons(value.Value.fromFixnum(2), value.NIL);
    const inner_head = try fx.heap.allocCons(value.Value.fromFixnum(1), inner_b);
    const tail = try fx.heap.allocCons(value.Value.fromFixnum(3), value.NIL);
    const form = try fx.heap.allocCons(inner_head, tail);

    try std.testing.expectError(Error.NotCallable, fx.ev.eval(form));
}

test "isFunction returns false for non-heap values" {
    try std.testing.expect(!zisp.eval.function.isFunction(value.Value.fromFixnum(0)));
    try std.testing.expect(!zisp.eval.function.isFunction(value.NIL));
}

fn nativeArgErrorPropagator(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    _ = ev_opaque;
    _ = args;
    return error.WrongArgCount;
}

test "native primitive errors propagate to caller" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ERR", &nativeArgErrorPropagator);
    const f = fx.interner.lookup("ERR").?;
    const form = try fx.heap.allocCons(f, value.NIL);

    try std.testing.expectError(Error.WrongArgCount, fx.ev.eval(form));
}

test "eval inside special form handler can recurse" {
    const Local = struct {
        fn handler(ev: *Evaluator, args: value.Value) Error!value.Value {
            // Evaluate the single arg form (recursive eval).
            return ev.eval(heap_mod.car(args));
        }
    };
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try fx.ev.registerSpecialForm("EVAL-INNER", &Local.handler);
    const sym = fx.interner.lookup("EVAL-INNER").?;
    const x = try fx.sym("X");
    try fx.ev.env.bindValue(x, value.Value.fromFixnum(11));

    const arg = try fx.heap.allocCons(x, value.NIL);
    const form = try fx.heap.allocCons(sym, arg);

    const r = try fx.ev.eval(form);
    try std.testing.expectEqual(@as(i64, 11), r.toFixnum());
}
