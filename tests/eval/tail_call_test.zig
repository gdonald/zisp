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

fn zerop(ev_opaque: *anyopaque, args: []const value.Value) Error!value.Value {
    _ = ev_opaque;
    if (args.len != 1) return Error.WrongArgCount;
    return if (args[0].isFixnum() and args[0].toFixnum() == 0) value.T else value.NIL;
}

fn oneMinus(ev_opaque: *anyopaque, args: []const value.Value) Error!value.Value {
    _ = ev_opaque;
    if (args.len != 1) return Error.WrongArgCount;
    return value.Value.fromFixnum(args[0].toFixnum() - 1);
}

// Records the native stack-pointer at each tail bounce. The trampoline calls a
// closure body, returns, then loops; with tail-call elimination every bounce
// runs at the same native-stack depth, so the address of a fresh local here is
// identical across calls. Without elimination each recursion would deepen the
// stack and the address would drift. The probe returns its argument so it can
// sit transparently inside the recursive call's argument form.
var probe_first_addr: usize = 0;
var probe_seen: bool = false;
var probe_stable: bool = true;
var probe_calls: usize = 0;

fn resetProbe() void {
    probe_first_addr = 0;
    probe_seen = false;
    probe_stable = true;
    probe_calls = 0;
}

fn stackProbe(ev_opaque: *anyopaque, args: []const value.Value) Error!value.Value {
    _ = ev_opaque;
    var marker: usize = undefined;
    const addr = @intFromPtr(&marker);
    marker = addr;
    std.mem.doNotOptimizeAway(marker);
    if (!probe_seen) {
        probe_first_addr = addr;
        probe_seen = true;
    } else if (addr != probe_first_addr) {
        probe_stable = false;
    }
    probe_calls += 1;
    return if (args.len == 1) args[0] else value.NIL;
}

// Few enough to run instantly; enough to expose any per-bounce stack growth.
const BOUNCES: i64 = 64;

test "direct self tail recursion does not grow the native stack" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);
    resetProbe();

    _ = try fx.ev.defineNative("ZEROP", &zerop);
    _ = try fx.ev.defineNative("1-", &oneMinus);
    _ = try fx.ev.defineNative("PROBE", &stackProbe);

    const labels = fx.interner.lookup("LABELS").?;
    const if_s = fx.interner.lookup("IF").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const zerop_s = try fx.sym("ZEROP");
    const minus_s = try fx.sym("1-");
    const probe_s = try fx.sym("PROBE");
    const f = try fx.sym("F");
    const n = try fx.sym("N");
    const done = try fx.sym("DONE");

    // (labels ((f (n) (if (zerop n) 'done (f (probe (1- n)))))) (f BOUNCES))
    const test_form = try fx.list(&.{ zerop_s, n });
    const done_form = try fx.list(&.{ quote, done });
    const dec = try fx.list(&.{ minus_s, n });
    const probed = try fx.list(&.{ probe_s, dec });
    const rec = try fx.list(&.{ f, probed });
    const if_form = try fx.list(&.{ if_s, test_form, done_form, rec });
    const def = try fx.list(&.{ f, try fx.list(&.{n}), if_form });
    const call = try fx.list(&.{ f, value.Value.fromFixnum(BOUNCES) });
    const form = try fx.list(&.{ labels, try fx.list(&.{def}), call });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(done));
    try std.testing.expectEqual(@as(usize, BOUNCES), probe_calls);
    try std.testing.expect(probe_stable);
}

test "tail recursion through progn does not grow the native stack" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);
    resetProbe();

    _ = try fx.ev.defineNative("ZEROP", &zerop);
    _ = try fx.ev.defineNative("1-", &oneMinus);
    _ = try fx.ev.defineNative("PROBE", &stackProbe);

    const labels = fx.interner.lookup("LABELS").?;
    const if_s = fx.interner.lookup("IF").?;
    const progn = fx.interner.lookup("PROGN").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const zerop_s = try fx.sym("ZEROP");
    const minus_s = try fx.sym("1-");
    const probe_s = try fx.sym("PROBE");
    const f = try fx.sym("F");
    const n = try fx.sym("N");
    const done = try fx.sym("DONE");

    // (labels ((f (n) (if (zerop n) 'done (progn (f (probe (1- n))))))) (f BOUNCES))
    const test_form = try fx.list(&.{ zerop_s, n });
    const done_form = try fx.list(&.{ quote, done });
    const dec = try fx.list(&.{ minus_s, n });
    const probed = try fx.list(&.{ probe_s, dec });
    const rec = try fx.list(&.{ f, probed });
    const progn_form = try fx.list(&.{ progn, rec });
    const if_form = try fx.list(&.{ if_s, test_form, done_form, progn_form });
    const def = try fx.list(&.{ f, try fx.list(&.{n}), if_form });
    const call = try fx.list(&.{ f, value.Value.fromFixnum(BOUNCES) });
    const form = try fx.list(&.{ labels, try fx.list(&.{def}), call });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(done));
    try std.testing.expectEqual(@as(usize, BOUNCES), probe_calls);
    try std.testing.expect(probe_stable);
}

test "mutual tail recursion does not grow the native stack" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);
    resetProbe();

    _ = try fx.ev.defineNative("ZEROP", &zerop);
    _ = try fx.ev.defineNative("1-", &oneMinus);
    _ = try fx.ev.defineNative("PROBE", &stackProbe);

    const labels = fx.interner.lookup("LABELS").?;
    const if_s = fx.interner.lookup("IF").?;
    const zerop_s = try fx.sym("ZEROP");
    const minus_s = try fx.sym("1-");
    const probe_s = try fx.sym("PROBE");
    const ev_fn = try fx.sym("EV");
    const od_fn = try fx.sym("OD");
    const n = try fx.sym("N");

    // (labels ((ev (n) (if (zerop n) t (od (probe (1- n)))))
    //          (od (n) (if (zerop n) nil (ev (probe (1- n))))))
    //   (ev BOUNCES))
    const ztest = try fx.list(&.{ zerop_s, n });
    const probed = try fx.list(&.{ probe_s, try fx.list(&.{ minus_s, n }) });

    const ev_rec = try fx.list(&.{ od_fn, probed });
    const ev_if = try fx.list(&.{ if_s, ztest, value.T, ev_rec });
    const ev_def = try fx.list(&.{ ev_fn, try fx.list(&.{n}), ev_if });

    const od_rec = try fx.list(&.{ ev_fn, probed });
    const od_if = try fx.list(&.{ if_s, ztest, value.NIL, od_rec });
    const od_def = try fx.list(&.{ od_fn, try fx.list(&.{n}), od_if });

    const defs = try fx.list(&.{ ev_def, od_def });
    const call = try fx.list(&.{ ev_fn, value.Value.fromFixnum(BOUNCES) });
    const form = try fx.list(&.{ labels, defs, call });

    // BOUNCES is even, so ev returns T.
    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(value.T));
    try std.testing.expectEqual(@as(usize, BOUNCES), probe_calls);
    try std.testing.expect(probe_stable);
}

test "tail call returns the correct value" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.ev.defineNative("ZEROP", &zerop);
    _ = try fx.ev.defineNative("1-", &oneMinus);

    const labels = fx.interner.lookup("LABELS").?;
    const if_s = fx.interner.lookup("IF").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const zerop_s = try fx.sym("ZEROP");
    const minus_s = try fx.sym("1-");
    const f = try fx.sym("F");
    const n = try fx.sym("N");
    const done = try fx.sym("DONE");

    const test_form = try fx.list(&.{ zerop_s, n });
    const done_form = try fx.list(&.{ quote, done });
    const dec = try fx.list(&.{ minus_s, n });
    const rec = try fx.list(&.{ f, dec });
    const if_form = try fx.list(&.{ if_s, test_form, done_form, rec });
    const def = try fx.list(&.{ f, try fx.list(&.{n}), if_form });
    const call = try fx.list(&.{ f, value.Value.fromFixnum(3) });
    const form = try fx.list(&.{ labels, try fx.list(&.{def}), call });

    const r = try fx.ev.eval(form);
    try std.testing.expect(r.equalsRaw(done));
}

// Expands (IDMAC x) to x; returns null for everything else so ordinary forms
// pass through untouched.
fn idMacro(ev: *Evaluator, form: value.Value) Error!?value.Value {
    _ = ev;
    if (!form.isCons()) return null;
    const head = heap_mod.car(form);
    if (!head.isSymbol()) return null;
    if (!std.mem.eql(u8, symbol_mod.symbol(head).name, "IDMAC")) return null;
    const rest = heap_mod.cdr(form);
    if (!rest.isCons()) return Error.BadArgList;
    return heap_mod.car(rest);
}

test "macro in tail position is expanded and the expansion evaluated" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);
    fx.ev.macro_expander = &idMacro;

    const lambda = fx.interner.lookup("LAMBDA").?;
    const quote = fx.interner.lookup("QUOTE").?;
    const idmac = try fx.sym("IDMAC");
    const ok = try fx.sym("OK");

    // ((lambda () (idmac 'ok))) — the macro call sits in tail position.
    const quoted = try fx.list(&.{ quote, ok });
    const mac_call = try fx.list(&.{ idmac, quoted });
    const lam = try fx.list(&.{ lambda, value.NIL, mac_call });
    const closure = try fx.ev.eval(lam);

    const r = try fx.ev.callFunction(closure, &.{});
    try std.testing.expect(r.equalsRaw(ok));
}

test "if in tail position rejects a dotted tail after the then-form" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const if_s = fx.interner.lookup("IF").?;

    // ((lambda () (if t t . 5))) — the if has an improper tail.
    const dotted = try fx.heap.allocCons(value.T, value.Value.fromFixnum(5));
    const after_test = try fx.heap.allocCons(value.T, dotted);
    const if_form = try fx.heap.allocCons(if_s, after_test);
    const lam = try fx.list(&.{ lambda, value.NIL, if_form });
    const closure = try fx.ev.eval(lam);

    try std.testing.expectError(Error.BadArgList, fx.ev.callFunction(closure, &.{}));
}

test "if in tail position with false test and no else returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const if_s = fx.interner.lookup("IF").?;

    // ((lambda () (if nil t))) — false test, no else branch.
    const if_form = try fx.list(&.{ if_s, value.NIL, value.T });
    const lam = try fx.list(&.{ lambda, value.NIL, if_form });
    const closure = try fx.ev.eval(lam);

    const r = try fx.ev.callFunction(closure, &.{});
    try std.testing.expect(r.equalsRaw(value.NIL));
}

test "empty progn in tail position returns NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const lambda = fx.interner.lookup("LAMBDA").?;
    const progn = fx.interner.lookup("PROGN").?;

    // ((lambda () (progn))) — empty progn in tail position.
    const progn_form = try fx.list(&.{progn});
    const lam = try fx.list(&.{ lambda, value.NIL, progn_form });
    const closure = try fx.ev.eval(lam);

    const r = try fx.ev.callFunction(closure, &.{});
    try std.testing.expect(r.equalsRaw(value.NIL));
}
