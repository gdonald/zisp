//! Arithmetic over the real tower: fixnums, bignums, ratios and floats.
//!
//! A rational operand is viewed as a numerator over a positive
//! denominator, so one set of formulas covers integers and ratios alike.
//! Results go back through `makeRatio`, which reduces and collapses a
//! denominator of one, so an integer result is always an integer.
//!
//! A float anywhere in an operation makes the result a float, of the
//! widest float format present, per CLHS 12.1.4.1. Comparisons are the
//! exception: there the float is converted to the rational it exactly
//! denotes, so no precision is lost against a bignum.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const bignum = @import("../runtime/bignum.zig");
const equality = @import("../runtime/equality.zig");
const complex = @import("../runtime/complex.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const Managed = std.math.big.int.Managed;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

const ZERO = Value.fromFixnum(0);
const ONE = Value.fromFixnum(1);

pub fn registerNumbers(ev: *Evaluator) !void {
    _ = try ev.defineNative("+", &addFn);
    _ = try ev.defineNative("-", &subFn);
    _ = try ev.defineNative("*", &mulFn);
    _ = try ev.defineNative("/", &divideExactFn);
    _ = try ev.defineNative("1+", &onePlusFn);
    _ = try ev.defineNative("1-", &oneMinusFn);
    _ = try ev.defineNative("ABS", &absFn);
    _ = try ev.defineNative("MIN", &minFn);
    _ = try ev.defineNative("MAX", &maxFn);
    _ = try ev.defineNative("MOD", &modFn);
    _ = try ev.defineNative("REM", &remFn);
    _ = try ev.defineNative("INTEGERP", &integerpFn);
    _ = try ev.defineNative("RATIONALP", &rationalpFn);
    _ = try ev.defineNative("FLOATP", &floatpFn);
    _ = try ev.defineNative("REALP", &realpFn);
    _ = try ev.defineNative("FLOAT", &floatFn);
    _ = try ev.defineNative("RATIONAL", &rationalFn);
    _ = try ev.defineNative("COMPLEXP", &complexpFn);
    _ = try ev.defineNative("COMPLEX", &complexFn);
    _ = try ev.defineNative("REALPART", &realpartFn);
    _ = try ev.defineNative("IMAGPART", &imagpartFn);
    _ = try ev.defineNative("CONJUGATE", &conjugateFn);
    _ = try ev.defineNative("PHASE", &phaseFn);
    _ = try ev.defineNative("EXP", unaryFn(.exp));
    _ = try ev.defineNative("LOG", &logFn);
    _ = try ev.defineNative("SQRT", unaryFn(.sqrt));
    _ = try ev.defineNative("ISQRT", &isqrtFn);
    _ = try ev.defineNative("EXPT", &exptFn);
    _ = try ev.defineNative("SIN", unaryFn(.sin));
    _ = try ev.defineNative("COS", unaryFn(.cos));
    _ = try ev.defineNative("TAN", unaryFn(.tan));
    _ = try ev.defineNative("ASIN", unaryFn(.asin));
    _ = try ev.defineNative("ACOS", unaryFn(.acos));
    _ = try ev.defineNative("ATAN", &atanFn);
    _ = try ev.defineNative("SINH", unaryFn(.sinh));
    _ = try ev.defineNative("COSH", unaryFn(.cosh));
    _ = try ev.defineNative("TANH", unaryFn(.tanh));
    _ = try ev.defineNative("ASINH", unaryFn(.asinh));
    _ = try ev.defineNative("ACOSH", unaryFn(.acosh));
    _ = try ev.defineNative("ATANH", unaryFn(.atanh));
    _ = try ev.defineNative("NUMERATOR", &numeratorFn);
    _ = try ev.defineNative("DENOMINATOR", &denominatorFn);
    _ = try ev.defineNative("=", cmpFn(.eq));
    _ = try ev.defineNative("/=", cmpFn(.ne));
    _ = try ev.defineNative("<", cmpFn(.lt));
    _ = try ev.defineNative(">", cmpFn(.gt));
    _ = try ev.defineNative("<=", cmpFn(.le));
    _ = try ev.defineNative(">=", cmpFn(.ge));
    _ = try ev.defineNative("ZEROP", signPred(.zero));
    _ = try ev.defineNative("PLUSP", signPred(.plus));
    _ = try ev.defineNative("MINUSP", signPred(.minus));
    _ = try ev.defineNative("EVENP", parityPred(true));
    _ = try ev.defineNative("ODDP", parityPred(false));
    _ = try ev.defineNative("LOGAND", bitwiseFn(.@"and"));
    _ = try ev.defineNative("LOGIOR", bitwiseFn(.ior));
    _ = try ev.defineNative("LOGXOR", bitwiseFn(.xor));
    _ = try ev.defineNative("LOGNOT", &lognotFn);
    _ = try ev.defineNative("ASH", &ashFn);
    _ = try ev.defineNative("INTEGER-LENGTH", &integerLengthFn);
    _ = try ev.defineNative("GCD", &gcdFn);
    _ = try ev.defineNative("LCM", &lcmFn);

    _ = try ev.defineNative("RANDOM", &randomFn);
    _ = try ev.defineNative("MAKE-RANDOM-STATE", &makeRandomStateFn);
    _ = try ev.defineNative("RANDOM-STATE-P", &randomStatePFn);

    const initial = std.Random.Xoshiro256.init(DEFAULT_RANDOM_SEED);
    const random_state = try ev.interner.intern("*RANDOM-STATE*");
    symbol_mod.symbol(random_state).value_cell = try ev.heap.allocRandomState(initial.s);

    // The standard numeric constants. `pi` is a double-float, as CLHS
    // specifies, and the fixnum bounds describe this implementation.
    const pi_sym = try ev.interner.intern("PI");
    symbol_mod.symbol(pi_sym).value_cell = try ev.heap.allocDoubleFloat(std.math.pi);
    const most_positive = try ev.interner.intern("MOST-POSITIVE-FIXNUM");
    symbol_mod.symbol(most_positive).value_cell = Value.fromFixnum(value.FIXNUM_MAX);
    const most_negative = try ev.interner.intern("MOST-NEGATIVE-FIXNUM");
    symbol_mod.symbol(most_negative).value_cell = Value.fromFixnum(value.FIXNUM_MIN);
    try registerFloatConstants(ev);

    // Each returns a quotient and a remainder.
    for ([_]struct { name: []const u8, native: function.NativeFn }{
        .{ .name = "FLOOR", .native = divideFn(.floor) },
        .{ .name = "CEILING", .native = divideFn(.ceiling) },
        .{ .name = "TRUNCATE", .native = divideFn(.truncate) },
        .{ .name = "ROUND", .native = divideFn(.round) },
    }) |entry| {
        function.asFunction(try ev.defineNative(entry.name, entry.native)).preserves_values = true;
    }
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

// --- operand views ---

/// A rational seen as a numerator over a positive denominator. An integer
/// is itself over one.
const Rational = struct {
    num: Value,
    den: Value,

    fn of(v: Value) Error!Rational {
        if (heap.isRatio(v)) {
            const r = heap.asRatio(v);
            return .{ .num = r.numerator, .den = r.denominator };
        }
        if (bignum.isInteger(v)) return .{ .num = v, .den = ONE };
        return Error.TypeError;
    }

    fn isInteger(self: Rational) bool {
        return bignum.compare(self.den, ONE) == .eq;
    }
};

fn expectRational(v: Value) Error!void {
    if (!bignum.isRational(v)) return Error.TypeError;
}

fn isFloat(v: Value) bool {
    return heap.isSingleFloat(v) or heap.isDoubleFloat(v);
}

fn isReal(v: Value) bool {
    return bignum.isRational(v) or isFloat(v);
}

fn expectReal(v: Value) Error!void {
    if (!isReal(v)) return Error.TypeError;
}

/// The float format an operation's result takes, which is the widest one
/// among its arguments.
const Contagion = enum { rational, single, double };

fn contagionOf(args: []const Value) Error!Contagion {
    var kind = Contagion.rational;
    for (args) |a| {
        if (heap.isDoubleFloat(a)) {
            kind = .double;
        } else if (heap.isSingleFloat(a)) {
            if (kind != .double) kind = .single;
        } else {
            try expectRational(a);
        }
    }
    return kind;
}

fn asF64(v: Value) f64 {
    return equality.toF64(v);
}

fn boxFloat(ev: *Evaluator, comptime T: type, x: T) Error!Value {
    if (T == f32) return ev.heap.allocSingleFloat(x);
    return ev.heap.allocDoubleFloat(x);
}

fn expectInteger(v: Value) Error!void {
    if (!bignum.isInteger(v)) return Error.TypeError;
}

fn allFixnums(args: []const Value) bool {
    for (args) |a| {
        if (!a.isFixnum()) return false;
    }
    return true;
}

// --- addition, subtraction, multiplication ---

const BinaryOp = enum { add, sub, mul };

fn applyFix(op: BinaryOp, a: i128, b: i128) i128 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
    };
}

fn combine(ev: *Evaluator, op: BinaryOp, a: Rational, b: Rational) Error!Rational {
    const h = ev.heap;
    return switch (op) {
        .mul => .{
            .num = try bignum.mul(h, a.num, b.num),
            .den = try bignum.mul(h, a.den, b.den),
        },
        .add, .sub => blk: {
            const left = try bignum.mul(h, a.num, b.den);
            const right = try bignum.mul(h, b.num, a.den);
            break :blk .{
                .num = if (op == .add)
                    try bignum.add(h, left, right)
                else
                    try bignum.sub(h, left, right),
                .den = try bignum.mul(h, a.den, b.den),
            };
        },
    };
}

/// Fold `args` left with `op`, starting from `seed`.
fn fold(ev: *Evaluator, op: BinaryOp, seed: i128, args: []const Value) Error!Value {
    switch (try contagionOf(args)) {
        .rational => {},
        .single => return foldFloat(ev, op, f32, @floatFromInt(seed), args),
        .double => return foldFloat(ev, op, f64, @floatFromInt(seed), args),
    }
    if (allFixnums(args)) {
        var acc: i128 = seed;
        for (args) |a| acc = applyFix(op, acc, a.toFixnum());
        return bignum.fromI128(ev.heap, acc);
    }
    var acc = Rational{ .num = try bignum.fromI128(ev.heap, seed), .den = ONE };
    for (args) |a| acc = try combine(ev, op, acc, try Rational.of(a));
    return bignum.makeRatio(ev.heap, acc.num, acc.den);
}

fn applyFloat(comptime T: type, op: BinaryOp, a: T, b: T) T {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
    };
}

fn foldFloat(ev: *Evaluator, op: BinaryOp, comptime T: type, seed: T, args: []const Value) Error!Value {
    var acc: T = seed;
    for (args) |a| acc = applyFloat(T, op, acc, @floatCast(asF64(a)));
    return boxFloat(ev, T, acc);
}

fn addFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (anyComplex(args)) return foldComplex(ev, .add, args);
    return fold(ev, .add, 0, args);
}

fn mulFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (anyComplex(args)) return foldComplex(ev, .mul, args);
    return fold(ev, .mul, 1, args);
}

fn subFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    if (anyComplex(args)) return foldComplex(ev, .sub, args);
    if (args.len == 1) return fold(ev, .sub, 0, args);
    switch (try contagionOf(args)) {
        .rational => {},
        .single => return subFloat(ev, f32, args),
        .double => return subFloat(ev, f64, args),
    }
    if (allFixnums(args)) {
        var acc: i128 = args[0].toFixnum();
        for (args[1..]) |a| acc -= a.toFixnum();
        return bignum.fromI128(ev.heap, acc);
    }
    var acc = try Rational.of(args[0]);
    for (args[1..]) |a| {
        try expectRational(a);
        acc = try combine(ev, .sub, acc, try Rational.of(a));
    }
    return bignum.makeRatio(ev.heap, acc.num, acc.den);
}

fn subFloat(ev: *Evaluator, comptime T: type, args: []const Value) Error!Value {
    var acc: T = @floatCast(asF64(args[0]));
    for (args[1..]) |a| acc -= @as(T, @floatCast(asF64(a)));
    return boxFloat(ev, T, acc);
}

fn divideFloat(ev: *Evaluator, comptime T: type, args: []const Value) Error!Value {
    var acc: T = if (args.len == 1) 1 else @floatCast(asF64(args[0]));
    const divisors = if (args.len == 1) args else args[1..];
    for (divisors) |a| acc /= @as(T, @floatCast(asF64(a)));
    return boxFloat(ev, T, acc);
}

/// `(/ x)` is the reciprocal; `(/ x y ...)` divides left to right.
fn divideExactFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    if (anyComplex(args)) return foldComplex(ev, .quotient, args);
    switch (try contagionOf(args)) {
        .rational => {},
        .single => return divideFloat(ev, f32, args),
        .double => return divideFloat(ev, f64, args),
    }

    var acc = if (args.len == 1)
        Rational{ .num = ONE, .den = ONE }
    else
        try Rational.of(args[0]);
    const divisors = if (args.len == 1) args else args[1..];
    for (divisors) |a| {
        const divisor = try Rational.of(a);
        if (bignum.isZero(divisor.num)) return Error.DivisionByZero;
        acc = .{
            .num = try bignum.mul(ev.heap, acc.num, divisor.den),
            .den = try bignum.mul(ev.heap, acc.den, divisor.num),
        };
    }
    return bignum.makeRatio(ev.heap, acc.num, acc.den);
}

fn onePlusFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 1) return Error.WrongArgCount;
    return fold(evaluator(p), .add, 1, args);
}

fn oneMinusFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    switch (try contagionOf(args)) {
        .rational => {},
        .single => return boxFloat(ev, f32, @as(f32, @floatCast(asF64(args[0]))) - 1),
        .double => return boxFloat(ev, f64, asF64(args[0]) - 1),
    }
    const a = try Rational.of(args[0]);
    return bignum.makeRatio(ev.heap, try bignum.sub(ev.heap, a.num, a.den), a.den);
}

fn absFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (heap.isComplex(args[0])) {
        const z = try Parts.of(ev, args[0]);
        return boxReal(ev, try resultFormat(args), std.math.hypot(asF64(z.re), asF64(z.im)));
    }
    switch (try contagionOf(args)) {
        .rational => {},
        .single => return boxFloat(ev, f32, @abs(@as(f32, @floatCast(asF64(args[0]))))),
        .double => return boxFloat(ev, f64, @abs(asF64(args[0]))),
    }
    const a = try Rational.of(args[0]);
    return bignum.makeRatio(ev.heap, try bignum.absOf(ev.heap, a.num), a.den);
}

// --- ordering ---

/// Ordering is exact. Two floats compare directly, and a float against a
/// rational compares as the rational the float exactly denotes, so no
/// precision is lost against a bignum. Cross-multiplying the two fractions
/// needs somewhere to put the products, hence the evaluator's heap.
fn compareIn(ev: *Evaluator, a_in: Value, b_in: Value) Error!std.math.Order {
    try expectReal(a_in);
    try expectReal(b_in);
    if (isFloat(a_in) and isFloat(b_in)) {
        return std.math.order(asF64(a_in), asF64(b_in));
    }
    const a = if (isFloat(a_in)) try bignum.fromFloat(ev.heap, asF64(a_in)) else a_in;
    const b = if (isFloat(b_in)) try bignum.fromFloat(ev.heap, asF64(b_in)) else b_in;
    if (bignum.isInteger(a) and bignum.isInteger(b)) return bignum.compare(a, b);
    const lhs = try Rational.of(a);
    const rhs = try Rational.of(b);
    const left = try bignum.mul(ev.heap, lhs.num, rhs.den);
    const right = try bignum.mul(ev.heap, rhs.num, lhs.den);
    return bignum.compare(left, right);
}

fn minFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    var best = args[0];
    try expectReal(best);
    for (args[1..]) |a| {
        if ((try compareIn(ev, a, best)) == .lt) best = a;
    }
    return best;
}

fn maxFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    var best = args[0];
    try expectReal(best);
    for (args[1..]) |a| {
        if ((try compareIn(ev, a, best)) == .gt) best = a;
    }
    return best;
}

const CmpOp = enum { eq, ne, lt, gt, le, ge };

fn cmpFn(comptime op: CmpOp) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len == 0) return Error.WrongArgCount;
            // Only equality is defined on complex numbers; ordering is not.
            const equality_test = op == .eq or op == .ne;
            for (args) |a| {
                if (equality_test and heap.isComplex(a)) continue;
                try expectReal(a);
            }
            if (op == .ne) {
                for (args, 0..) |a, i| {
                    for (args[i + 1 ..]) |b| {
                        if (try numbersEqual(ev, a, b)) return value.NIL;
                    }
                }
                return value.T;
            }
            if (op == .eq) {
                var k: usize = 1;
                while (k < args.len) : (k += 1) {
                    if (!try numbersEqual(ev, args[k - 1], args[k])) return value.NIL;
                }
                return value.T;
            }
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const order = try compareIn(ev, args[i - 1], args[i]);
                const ok = switch (op) {
                    .eq => unreachable,
                    .lt => order == .lt,
                    .gt => order == .gt,
                    .le => order != .gt,
                    .ge => order != .lt,
                    .ne => unreachable,
                };
                if (!ok) return value.NIL;
            }
            return value.T;
        }
    }.f;
}

fn signPred(comptime want: enum { zero, plus, minus }) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len != 1) return Error.WrongArgCount;
            if (want == .zero and heap.isComplex(args[0])) {
                const z = try Parts.of(ev, args[0]);
                return boolv(asF64(z.re) == 0 and asF64(z.im) == 0);
            }
            try expectReal(args[0]);
            if (isFloat(args[0])) {
                const x = asF64(args[0]);
                return boolv(switch (want) {
                    .zero => x == 0,
                    .plus => x > 0,
                    .minus => x < 0,
                });
            }
            // The denominator is positive, so the numerator carries the sign.
            const numerator = (try Rational.of(args[0])).num;
            return boolv(switch (want) {
                .zero => bignum.isZero(numerator),
                .plus => !bignum.isZero(numerator) and !bignum.isNegative(numerator),
                .minus => bignum.isNegative(numerator),
            });
        }
    }.f;
}

fn parityPred(comptime want_even: bool) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len != 1) return Error.WrongArgCount;
            try expectInteger(args[0]);
            var scratch = bignum.Scratch{};
            return boolv(scratch.view(args[0]).isEven() == want_even);
        }
    }.f;
}

fn integerpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(bignum.isInteger(args[0]));
}

fn rationalpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(bignum.isRational(args[0]));
}

fn numeratorFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    try expectRational(args[0]);
    return bignum.numeratorOf(args[0]);
}

fn denominatorFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    try expectRational(args[0]);
    return bignum.denominatorOf(args[0]);
}

// --- division with a quotient and a remainder ---

const DivideKind = enum { floor, ceiling, truncate, round };

/// Round `num/den` to an integer, with `den` positive.
fn roundQuotient(ev: *Evaluator, kind: DivideKind, num: Value, den: Value) Error!Value {
    const h = ev.heap;
    // Each step's result feeds the next one, and every step allocates.
    var held = h.protect();
    defer held.close();
    try held.push(num);
    try held.push(den);
    const truncated = try bignum.divTrunc(h, num, den);
    try held.push(truncated);
    const product = try bignum.mul(h, truncated, den);
    try held.push(product);
    const remainder = try bignum.sub(h, num, product);
    try held.push(remainder);
    if (bignum.isZero(remainder)) return truncated;

    const remainder_negative = bignum.isNegative(remainder);
    const step: i64 = switch (kind) {
        .truncate => 0,
        .floor => if (remainder_negative) -1 else 0,
        .ceiling => if (remainder_negative) 0 else 1,
        .round => blk: {
            // Compare twice the remainder's magnitude against the divisor,
            // breaking an exact tie toward an even quotient.
            const twice = try bignum.mul(h, try bignum.absOf(h, remainder), Value.fromFixnum(2));
            const order = bignum.compare(twice, den);
            var scratch = bignum.Scratch{};
            const ties_up = order == .eq and !scratch.view(truncated).isEven();
            if (order != .gt and !ties_up) break :blk 0;
            break :blk if (remainder_negative) -1 else 1;
        },
    };
    if (step == 0) return truncated;
    return bignum.add(h, truncated, Value.fromFixnum(step));
}

/// A real as the rational it exactly denotes, so a float can go through
/// the rational code paths without losing bits.
fn exactly(ev: *Evaluator, v: Value) Error!Value {
    if (!isFloat(v)) return v;
    const x = asF64(v);
    if (std.math.isNan(x) or std.math.isInf(x)) return Error.TypeError;
    return bignum.fromFloat(ev.heap, x);
}

fn divideFn(comptime kind: DivideKind) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
            const divisor_value = if (args.len == 2) args[1] else ONE;
            const contagion = try contagionOf(&.{ args[0], divisor_value });

            // The quotient is an integer whatever the operands are, so it
            // is computed on the exact rationals the floats denote.
            var held = ev.heap.protect();
            defer held.close();
            const dividend = try Rational.of(try exactly(ev, args[0]));
            try held.push(dividend.num);
            try held.push(dividend.den);
            const divisor = try Rational.of(try exactly(ev, divisor_value));
            try held.push(divisor.num);
            try held.push(divisor.den);
            if (bignum.isZero(divisor.num)) return Error.DivisionByZero;

            // x/y as a single fraction, with the sign on the numerator.
            var num = try bignum.mul(ev.heap, dividend.num, divisor.den);
            try held.push(num);
            var den = try bignum.mul(ev.heap, dividend.den, divisor.num);
            try held.push(den);
            if (bignum.isNegative(den)) {
                num = try bignum.negate(ev.heap, num);
                held.setItem(4, num);
                den = try bignum.negate(ev.heap, den);
                held.setItem(5, den);
            }
            const quotient = try roundQuotient(ev, kind, num, den);
            try held.push(quotient);

            // remainder = dividend - quotient * divisor
            const scaled = try combine(ev, .mul, .{ .num = quotient, .den = ONE }, divisor);
            try held.push(scaled.num);
            try held.push(scaled.den);
            const difference = try combine(ev, .sub, dividend, scaled);
            try held.push(difference.num);
            try held.push(difference.den);
            const exact_remainder = try bignum.makeRatio(ev.heap, difference.num, difference.den);
            try held.push(exact_remainder);
            const remainder = switch (contagion) {
                .rational => exact_remainder,
                .single => try boxFloat(ev, f32, @floatCast(asF64(exact_remainder))),
                .double => try boxFloat(ev, f64, asF64(exact_remainder)),
            };
            return ev.setValues(&.{ quotient, remainder });
        }
    }.f;
}

fn modFn(p: *anyopaque, args: []const Value) Error!Value {
    return remainderOf(evaluator(p), .floor, args);
}

fn remFn(p: *anyopaque, args: []const Value) Error!Value {
    return remainderOf(evaluator(p), .truncate, args);
}

/// `mod` and `rem` are the remainders of `floor` and `truncate`.
fn remainderOf(ev: *Evaluator, comptime kind: DivideKind, args: []const Value) Error!Value {
    if (args.len != 2) return Error.WrongArgCount;
    _ = try divideFn(kind)(ev.asOpaque(), args);
    const values = ev.values.items;
    if (values.len < 2) return Error.ProgramError;
    return ev.set1(values[1]);
}

// --- integer-only operations ---

fn gcdFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    var acc = ZERO;
    for (args) |a| {
        try expectInteger(a);
        acc = try bignum.gcd(ev.heap, acc, a);
    }
    return acc;
}

/// `(lcm a b)` is `|a*b| / gcd(a, b)`, and zero if either is zero.
fn lcmFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    var acc = ONE;
    for (args) |a| {
        try expectInteger(a);
        if (bignum.isZero(a) or bignum.isZero(acc)) {
            acc = ZERO;
            continue;
        }
        const divisor = try bignum.gcd(ev.heap, acc, a);
        const product = try bignum.mul(ev.heap, acc, a);
        acc = try bignum.absOf(ev.heap, try bignum.divTrunc(ev.heap, product, divisor));
    }
    return acc;
}

const BitwiseOp = enum { @"and", ior, xor };

fn applyBitwise(op: BitwiseOp, out: *Managed, a: *const Managed, b: *const Managed) Error!void {
    switch (op) {
        .@"and" => try out.bitAnd(a, b),
        .ior => try out.bitOr(a, b),
        .xor => try out.bitXor(a, b),
    }
}

fn identityFor(op: BitwiseOp) i64 {
    return switch (op) {
        .@"and" => -1,
        .ior, .xor => 0,
    };
}

fn bitwiseFn(comptime op: BitwiseOp) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            const allocator = ev.heap.allocator;
            var acc = try Managed.initSet(allocator, identityFor(op));
            for (args) |a| {
                try expectInteger(a);
                var scratch = bignum.Scratch{};
                var operand = try scratch.view(a).toManaged(allocator);
                var next = try Managed.init(allocator);
                try applyBitwise(op, &next, &acc, &operand);
                acc = next;
            }
            return bignum.normalize(ev.heap, acc.toConst());
        }
    }.f;
}

/// `(lognot n)` is `-n - 1`, which needs no bit-level work.
fn lognotFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    try expectInteger(args[0]);
    const negated = try bignum.negate(ev.heap, args[0]);
    return bignum.sub(ev.heap, negated, ONE);
}

/// `(ash n count)` shifts left for a positive count and arithmetically
/// right for a negative one.
fn ashFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    try expectInteger(args[0]);
    if (!args[1].isFixnum()) return Error.TypeError;
    const count = args[1].toFixnum();

    const allocator = ev.heap.allocator;
    var scratch = bignum.Scratch{};
    var operand = try scratch.view(args[0]).toManaged(allocator);
    var out = try Managed.init(allocator);
    if (count >= 0) {
        try out.shiftLeft(&operand, @intCast(count));
    } else {
        try out.shiftRight(&operand, @intCast(-count));
    }
    return bignum.normalize(ev.heap, out.toConst());
}

/// Bits needed for the magnitude, counting a negative integer as its
/// complement per CLHS.
fn integerLengthFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    try expectInteger(args[0]);
    const subject = if (bignum.isNegative(args[0]))
        try lognotFn(ev.asOpaque(), args)
    else
        args[0];
    return Value.fromFixnum(@intCast(bignum.bitCountAbs(subject)));
}

// --- float predicates and conversions ---

fn floatpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isFloat(args[0]));
}

fn realpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isReal(args[0]));
}

/// `(float x)` makes a single-float; `(float x prototype)` matches the
/// prototype's format instead.
fn floatFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    try expectReal(args[0]);
    const want_double = if (args.len == 2) blk: {
        if (!isFloat(args[1])) return Error.TypeError;
        break :blk heap.isDoubleFloat(args[1]);
    } else false;
    if (want_double) return boxFloat(ev, f64, asF64(args[0]));
    return boxFloat(ev, f32, @floatCast(asF64(args[0])));
}

/// `(rational x)` is the exact rational a float denotes.
fn rationalFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    try expectReal(args[0]);
    if (!isFloat(args[0])) return args[0];
    const x = asF64(args[0]);
    if (std.math.isNan(x) or std.math.isInf(x)) return Error.TypeError;
    return bignum.fromFloat(ev.heap, x);
}

// --- complex numbers ---

fn anyComplex(args: []const Value) bool {
    for (args) |a| {
        if (heap.isComplex(a)) return true;
    }
    return false;
}

/// A number split into its two real parts, so one set of formulas covers
/// reals and complexes together.
const Parts = struct {
    re: Value,
    im: Value,

    fn of(ev: *Evaluator, v: Value) Error!Parts {
        if (!complex.isNumber(v)) return Error.TypeError;
        return .{ .re = complex.realpartOf(v), .im = try complex.imagpartOf(ev.heap, v) };
    }
};

fn realAdd(ev: *Evaluator, a: Value, b: Value) Error!Value {
    return fold(ev, .add, 0, &.{ a, b });
}

fn realSub(ev: *Evaluator, a: Value, b: Value) Error!Value {
    return subFn(ev.asOpaque(), &.{ a, b });
}

fn realMul(ev: *Evaluator, a: Value, b: Value) Error!Value {
    return fold(ev, .mul, 1, &.{ a, b });
}

fn realDiv(ev: *Evaluator, a: Value, b: Value) Error!Value {
    return divideExactFn(ev.asOpaque(), &.{ a, b });
}

const ComplexOp = enum { add, sub, mul, quotient };

/// Both operands and every intermediate stay on the Lisp stack: each
/// arithmetic step allocates.
fn combineComplex(ev: *Evaluator, op: ComplexOp, a: Parts, b: Parts) Error!Parts {
    var held = ev.heap.protect();
    defer held.close();
    for ([_]Value{ a.re, a.im, b.re, b.im }) |part| try held.push(part);

    switch (op) {
        .add => {
            const re = try realAdd(ev, a.re, b.re);
            try held.push(re);
            return .{ .re = re, .im = try realAdd(ev, a.im, b.im) };
        },
        .sub => {
            const re = try realSub(ev, a.re, b.re);
            try held.push(re);
            return .{ .re = re, .im = try realSub(ev, a.im, b.im) };
        },
        .mul => {
            const re_product = try realMul(ev, a.re, b.re);
            try held.push(re_product);
            const im_product = try realMul(ev, a.im, b.im);
            try held.push(im_product);
            const re = try realSub(ev, re_product, im_product);
            try held.push(re);
            const cross_one = try realMul(ev, a.re, b.im);
            try held.push(cross_one);
            const cross_two = try realMul(ev, a.im, b.re);
            try held.push(cross_two);
            return .{ .re = re, .im = try realAdd(ev, cross_one, cross_two) };
        },
        .quotient => {
            // Multiply through by the conjugate of the divisor.
            const re_square = try realMul(ev, b.re, b.re);
            try held.push(re_square);
            const im_square = try realMul(ev, b.im, b.im);
            try held.push(im_square);
            const denominator = try realAdd(ev, re_square, im_square);
            try held.push(denominator);

            const re_one = try realMul(ev, a.re, b.re);
            try held.push(re_one);
            const re_two = try realMul(ev, a.im, b.im);
            try held.push(re_two);
            const re = try realAdd(ev, re_one, re_two);
            try held.push(re);

            const im_one = try realMul(ev, a.im, b.re);
            try held.push(im_one);
            const im_two = try realMul(ev, a.re, b.im);
            try held.push(im_two);
            const im = try realSub(ev, im_one, im_two);
            try held.push(im);

            const quotient_re = try realDiv(ev, re, denominator);
            try held.push(quotient_re);
            return .{ .re = quotient_re, .im = try realDiv(ev, im, denominator) };
        },
    }
}

fn foldComplex(ev: *Evaluator, op: ComplexOp, args: []const Value) Error!Value {
    if (args.len == 0) return Error.WrongArgCount;
    const identity: Parts = switch (op) {
        .add, .sub => .{ .re = ZERO, .im = ZERO },
        .mul, .quotient => .{ .re = ONE, .im = ZERO },
    };
    // A single argument negates or takes the reciprocal.
    // The running total is held: each step allocates both its parts.
    var held = ev.heap.protect();
    defer held.close();
    var acc = if (args.len == 1) identity else try Parts.of(ev, args[0]);
    try held.push(acc.re);
    try held.push(acc.im);
    const rest = if (args.len == 1) args else args[1..];
    for (rest) |a| {
        acc = try combineComplex(ev, op, acc, try Parts.of(ev, a));
        held.setItem(0, acc.re);
        held.setItem(1, acc.im);
    }
    return complex.make(ev.heap, acc.re, acc.im);
}

fn complexpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(heap.isComplex(args[0]));
}

fn complexFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const imagpart = if (args.len == 2) args[1] else ZERO;
    return complex.make(ev.heap, args[0], imagpart);
}

fn realpartFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (!complex.isNumber(args[0])) return Error.TypeError;
    return complex.realpartOf(args[0]);
}

fn imagpartFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!complex.isNumber(args[0])) return Error.TypeError;
    return complex.imagpartOf(ev.heap, args[0]);
}

fn conjugateFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!complex.isNumber(args[0])) return Error.TypeError;
    if (!heap.isComplex(args[0])) return args[0];
    const z = try Parts.of(ev, args[0]);
    return complex.make(ev.heap, z.re, try realSub(ev, ZERO, z.im));
}

// --- transcendental functions ---

const Cf64 = std.math.Complex(f64);

/// The float format a transcendental result takes. A rational argument
/// yields a single-float, which is `*read-default-float-format*`.
fn resultFormat(args: []const Value) Error!Contagion {
    var kind = Contagion.single;
    for (args) |a| {
        if (!complex.isNumber(a)) return Error.TypeError;
        const re = complex.realpartOf(a);
        if (heap.isDoubleFloat(re)) kind = .double;
        if (heap.isComplex(a) and heap.isDoubleFloat(heap.asComplex(a).imagpart)) kind = .double;
    }
    return kind;
}

fn asCf64(ev: *Evaluator, v: Value) Error!Cf64 {
    const parts = try Parts.of(ev, v);
    return Cf64.init(asF64(parts.re), asF64(parts.im));
}

fn boxReal(ev: *Evaluator, kind: Contagion, x: f64) Error!Value {
    if (kind == .double) return boxFloat(ev, f64, x);
    return boxFloat(ev, f32, @floatCast(x));
}

/// Box a complex result, narrowing to a real when the imaginary part
/// vanished and the argument was real to begin with.
fn boxComplex(ev: *Evaluator, kind: Contagion, z: Cf64) Error!Value {
    var held = ev.heap.protect();
    defer held.close();
    const real = try boxReal(ev, kind, z.re);
    try held.push(real);
    const imaginary = try boxReal(ev, kind, z.im);
    return complex.make(ev.heap, real, imaginary);
}

const UnaryKind = enum {
    exp,
    sqrt,
    sin,
    cos,
    tan,
    asin,
    acos,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
};

/// Whether the real-valued definition covers `x`, or the result leaves the
/// real line and the complex definition has to take over.
fn realDomainHolds(kind: UnaryKind, x: f64) bool {
    return switch (kind) {
        .exp, .sin, .cos, .tan, .sinh, .cosh, .tanh, .asinh => true,
        .sqrt => x >= 0,
        .asin, .acos => x >= -1 and x <= 1,
        .acosh => x >= 1,
        .atanh => x > -1 and x < 1,
    };
}

fn realUnary(kind: UnaryKind, x: f64) f64 {
    return switch (kind) {
        .exp => @exp(x),
        .sqrt => @sqrt(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .tan => @tan(x),
        .asin => std.math.asin(x),
        .acos => std.math.acos(x),
        .sinh => std.math.sinh(x),
        .cosh => std.math.cosh(x),
        .tanh => std.math.tanh(x),
        .asinh => std.math.asinh(x),
        .acosh => std.math.acosh(x),
        .atanh => std.math.atanh(x),
    };
}

fn cx(re: f64, im: f64) Cf64 {
    return Cf64.init(re, im);
}

fn scale(z: Cf64, k: f64) Cf64 {
    return cx(z.re * k, z.im * k);
}

fn timesI(z: Cf64) Cf64 {
    return cx(-z.im, z.re);
}

fn timesNegI(z: Cf64) Cf64 {
    return cx(z.im, -z.re);
}

/// The complex definitions. The inverse trigonometric and hyperbolic
/// functions are built from CLHS 12.1.5.3's own formulas rather than the
/// C99 versions, because the two disagree on which side of the cut the
/// boundary belongs to: C99's `casin(2)` sits in quadrant I where CLHS
/// puts it in quadrant IV. Everything here rests on `sqrt` and `log`,
/// whose cut is the negative real axis continuous with quadrant II.
fn complexUnary(kind: UnaryKind, z: Cf64) Cf64 {
    const one = cx(1, 0);
    const clog = std.math.complex.log;
    const csqrt = std.math.complex.sqrt;
    return switch (kind) {
        .exp => std.math.complex.exp(z),
        .sqrt => csqrt(z),
        .sin => std.math.complex.sin(z),
        .cos => std.math.complex.cos(z),
        .tan => std.math.complex.tan(z),
        .sinh => std.math.complex.sinh(z),
        .cosh => std.math.complex.cosh(z),
        .tanh => std.math.complex.tanh(z),
        // asin(z) = -i log(iz + sqrt(1 - z^2))
        .asin => timesNegI(clog(timesI(z).add(csqrt(one.sub(z.mul(z)))))),
        // acos(z) = -i log(z + i sqrt(1 - z^2))
        .acos => timesNegI(clog(z.add(timesI(csqrt(one.sub(z.mul(z))))))),
        // asinh(z) = log(z + sqrt(1 + z^2))
        .asinh => clog(z.add(csqrt(one.add(z.mul(z))))),
        // acosh(z) = 2 log(sqrt((z+1)/2) + sqrt((z-1)/2))
        .acosh => scale(clog(csqrt(scale(z.add(one), 0.5)).add(csqrt(scale(z.sub(one), 0.5)))), 2),
        // atanh(z) = (log(1+z) - log(1-z)) / 2
        .atanh => scale(clog(one.add(z)).sub(clog(one.sub(z))), 0.5),
    };
}

/// atan(z) = (log(1+iz) - log(1-iz)) / 2i, per CLHS 12.1.5.3.
fn complexAtan(z: Cf64) Cf64 {
    const one = cx(1, 0);
    const iz = timesI(z);
    const clog = std.math.complex.log;
    return timesNegI(scale(clog(one.add(iz)).sub(clog(one.sub(iz))), 0.5));
}

fn unaryFn(comptime kind: UnaryKind) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len != 1) return Error.WrongArgCount;
            const format = try resultFormat(args);
            if (!heap.isComplex(args[0])) {
                const x = asF64(args[0]);
                if (realDomainHolds(kind, x)) return boxReal(ev, format, realUnary(kind, x));
            }
            return boxComplex(ev, format, complexUnary(kind, try asCf64(ev, args[0])));
        }
    }.f;
}

/// `(log x)` is the natural logarithm; `(log x base)` divides by the log
/// of the base. A negative or complex argument goes round the branch cut
/// along the negative real axis.
fn logFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const format = try resultFormat(args);
    if (args.len == 2) {
        const numerator = try logOf(ev, format, args[0]);
        const denominator = try logOf(ev, format, args[1]);
        return divideExactFn(ev.asOpaque(), &.{ numerator, denominator });
    }
    return logOf(ev, format, args[0]);
}

fn logOf(ev: *Evaluator, format: Contagion, v: Value) Error!Value {
    if (!heap.isComplex(v)) {
        const x = asF64(v);
        if (x == 0) return Error.ArithmeticError;
        if (x > 0) return boxReal(ev, format, @log(x));
    }
    return boxComplex(ev, format, std.math.complex.log(try asCf64(ev, v)));
}

/// `(atan y)` is the one-argument arc tangent; `(atan y x)` picks the
/// quadrant from the signs of both arguments and takes reals only.
fn atanFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const format = try resultFormat(args);
    if (args.len == 2) {
        if (heap.isComplex(args[0]) or heap.isComplex(args[1])) return Error.TypeError;
        return boxReal(ev, format, std.math.atan2(asF64(args[0]), asF64(args[1])));
    }
    if (!heap.isComplex(args[0])) return boxReal(ev, format, std.math.atan(asF64(args[0])));
    return boxComplex(ev, format, complexAtan(try asCf64(ev, args[0])));
}

/// `(phase z)` is the angle of `z` in the complex plane.
fn phaseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const format = try resultFormat(args);
    const z = try Parts.of(ev, args[0]);
    return boxReal(ev, format, std.math.atan2(asF64(z.im), asF64(z.re)));
}

/// Integer square root: the largest integer whose square does not exceed
/// `n`. The float estimate is corrected, so it is exact at any magnitude.
fn isqrtFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    try expectInteger(args[0]);
    if (bignum.isNegative(args[0])) return Error.TypeError;
    if (bignum.isZero(args[0])) return ZERO;

    // Start from half the bit length, which brackets the root, then run
    // Newton's iteration until it stops decreasing.
    const bits = bignum.bitCountAbs(args[0]);
    var guess = try bignum.shiftLeft(ev.heap, ONE, bits / 2 + 1);
    while (true) {
        const quotient = try bignum.divTrunc(ev.heap, args[0], guess);
        const sum = try bignum.add(ev.heap, guess, quotient);
        const next = try bignum.divTrunc(ev.heap, sum, Value.fromFixnum(2));
        if (bignum.compare(next, guess) != .lt) return guess;
        guess = next;
    }
}

/// `(expt base power)`. An integer power is exact, by squaring; anything
/// else goes through `exp(power * log(base))`.
fn exptFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!complex.isNumber(args[0]) or !complex.isNumber(args[1])) return Error.TypeError;

    if (bignum.isInteger(args[1])) return exptInteger(ev, args[0], args[1]);

    const format = try resultFormat(args);
    // A non-negative real base keeps a real power on the real line.
    if (!heap.isComplex(args[0]) and !heap.isComplex(args[1])) {
        const b = asF64(args[0]);
        const e = asF64(args[1]);
        if (b > 0) return boxReal(ev, format, std.math.pow(f64, b, e));
        if (b == 0) {
            // Zero to a positive power is zero; to anything else undefined.
            if (e > 0) return boxReal(ev, format, 0);
            return Error.ArithmeticError;
        }
    }
    const base = try asCf64(ev, args[0]);
    const power = try asCf64(ev, args[1]);
    if (base.re == 0 and base.im == 0) {
        if (power.re > 0) return boxReal(ev, format, 0);
        return Error.ArithmeticError;
    }
    return boxComplex(ev, format, std.math.complex.pow(base, power));
}

/// Exponentiation by squaring, which keeps the result exact for rational
/// and complex-rational bases.
fn exptInteger(ev: *Evaluator, base: Value, power: Value) Error!Value {
    if (bignum.isZero(power)) return ONE;
    if (bignum.isNegative(power)) {
        const positive = try bignum.negate(ev.heap, power);
        const raised = try exptInteger(ev, base, positive);
        return divideExactFn(ev.asOpaque(), &.{ ONE, raised });
    }
    // Squaring works on results of the previous round, and each round
    // allocates.
    var held = ev.heap.protect();
    defer held.close();
    try held.push(ONE);
    try held.push(base);
    try held.push(power);
    var result = ONE;
    var factor = base;
    var remaining = power;
    while (!bignum.isZero(remaining)) {
        var scratch = bignum.Scratch{};
        if (!scratch.view(remaining).isEven()) {
            result = try mulFn(ev.asOpaque(), &.{ result, factor });
            held.setItem(0, result);
        }
        remaining = try bignum.divTrunc(ev.heap, remaining, Value.fromFixnum(2));
        held.setItem(2, remaining);
        if (bignum.isZero(remaining)) break;
        factor = try mulFn(ev.asOpaque(), &.{ factor, factor });
        held.setItem(1, factor);
    }
    return result;
}

/// `=` across the whole tower: two complex numbers agree when both parts
/// do, and a complex equals a real only when its imaginary part is zero.
fn numbersEqual(ev: *Evaluator, a: Value, b: Value) Error!bool {
    if (!heap.isComplex(a) and !heap.isComplex(b)) {
        return (try compareIn(ev, a, b)) == .eq;
    }
    const lhs = try Parts.of(ev, a);
    const rhs = try Parts.of(ev, b);
    return (try compareIn(ev, lhs.re, rhs.re)) == .eq and
        (try compareIn(ev, lhs.im, rhs.im)) == .eq;
}

// --- random ---

/// The generator zisp starts with. A fixed seed makes a run reproducible;
/// `(make-random-state t)` is how to get one seeded from the system.
const DEFAULT_RANDOM_SEED: u64 = 0x5DEE_CE66_D5DE_ECE6;

fn randomStateOf(ev: *Evaluator, given: ?Value) Error!*heap.HeapRandomState {
    const v = given orelse blk: {
        const sym = try ev.interner.intern("*RANDOM-STATE*");
        break :blk ev.env.lookupValue(sym) orelse
            return ev.unbound(sym, Error.UnboundVariable);
    };
    if (!heap.isRandomState(v)) return Error.TypeError;
    return heap.asRandomState(v);
}

/// Draw from a state, writing the advanced generator back into it.
fn drawFrom(state: *heap.HeapRandomState) std.Random {
    // The PRNG lives in the object, so the pointer cast hands the caller a
    // generator that updates the state in place.
    const prng: *std.Random.Xoshiro256 = @ptrCast(&state.state);
    return prng.random();
}

fn randomFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const state = try randomStateOf(ev, if (args.len == 2) args[1] else null);
    var random = drawFrom(state);

    const limit = args[0];
    if (isFloat(limit)) {
        const bound = asF64(limit);
        if (!(bound > 0)) return Error.TypeError;
        const draw = random.float(f64) * bound;
        return boxReal(ev, if (heap.isDoubleFloat(limit)) .double else .single, draw);
    }
    try expectInteger(limit);
    if (!bignum.isNegative(limit) and bignum.isZero(limit)) return Error.TypeError;
    if (bignum.isNegative(limit)) return Error.TypeError;
    if (limit.isFixnum()) {
        return Value.fromFixnum(@intCast(random.uintLessThan(u64, @intCast(limit.toFixnum()))));
    }
    return randomBignum(ev, &random, limit);
}

/// A uniform integer below a bignum limit: draw as many bits as the limit
/// has and retry until the draw lands under it.
fn randomBignum(ev: *Evaluator, random: *std.Random, limit: Value) Error!Value {
    const bits = bignum.bitCountAbs(limit);
    while (true) {
        var draw = ZERO;
        var produced: usize = 0;
        while (produced < bits) : (produced += 32) {
            const chunk = Value.fromFixnum(random.int(u32));
            draw = try bignum.add(ev.heap, try bignum.shiftLeft(ev.heap, draw, 32), chunk);
        }
        // The last chunk overshot the limit's width, so trim the excess.
        const excess = produced - bits;
        if (excess > 0) draw = try shiftRight(ev, draw, excess);
        if (bignum.compare(draw, limit) == .lt) return draw;
    }
}

fn shiftRight(ev: *Evaluator, n: Value, count: usize) Error!Value {
    const divisor = try bignum.shiftLeft(ev.heap, ONE, count);
    return bignum.divTrunc(ev.heap, n, divisor);
}

/// `(make-random-state)` copies the current state, `t` seeds a fresh one
/// from the system, and a state argument copies that one.
fn makeRandomStateFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    if (args.len == 1 and args[0].equalsRaw(value.T)) {
        // Seeded from the current state's next draw rather than the system,
        // so the runtime needs no entropy source. Successive calls differ
        // because the draw advances the state they came from.
        const current = try randomStateOf(ev, null);
        var random = drawFrom(current);
        const fresh = std.Random.Xoshiro256.init(random.int(u64));
        return ev.heap.allocRandomState(fresh.s);
    }
    const given: ?Value = if (args.len == 1 and !args[0].equalsRaw(value.NIL)) args[0] else null;
    const state = try randomStateOf(ev, given);
    return ev.heap.allocRandomState(state.state);
}

fn randomStatePFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(heap.isRandomState(args[0]));
}

/// The float limits CLHS names. `short-float` is this implementation's
/// single-float and `long-float` its double-float, so those names alias.
fn registerFloatConstants(ev: *Evaluator) !void {
    const singles = [_]struct { name: []const u8, v: f32 }{
        .{ .name = "MOST-POSITIVE-SINGLE-FLOAT", .v = std.math.floatMax(f32) },
        .{ .name = "MOST-NEGATIVE-SINGLE-FLOAT", .v = -std.math.floatMax(f32) },
        .{ .name = "LEAST-POSITIVE-SINGLE-FLOAT", .v = std.math.floatTrueMin(f32) },
        .{ .name = "LEAST-NEGATIVE-SINGLE-FLOAT", .v = -std.math.floatTrueMin(f32) },
        .{ .name = "LEAST-POSITIVE-NORMALIZED-SINGLE-FLOAT", .v = std.math.floatMin(f32) },
        .{ .name = "LEAST-NEGATIVE-NORMALIZED-SINGLE-FLOAT", .v = -std.math.floatMin(f32) },
        .{ .name = "SINGLE-FLOAT-EPSILON", .v = std.math.floatEps(f32) / 2 },
        .{ .name = "SINGLE-FLOAT-NEGATIVE-EPSILON", .v = std.math.floatEps(f32) / 4 },
    };
    const doubles = [_]struct { name: []const u8, v: f64 }{
        .{ .name = "MOST-POSITIVE-DOUBLE-FLOAT", .v = std.math.floatMax(f64) },
        .{ .name = "MOST-NEGATIVE-DOUBLE-FLOAT", .v = -std.math.floatMax(f64) },
        .{ .name = "LEAST-POSITIVE-DOUBLE-FLOAT", .v = std.math.floatTrueMin(f64) },
        .{ .name = "LEAST-NEGATIVE-DOUBLE-FLOAT", .v = -std.math.floatTrueMin(f64) },
        .{ .name = "LEAST-POSITIVE-NORMALIZED-DOUBLE-FLOAT", .v = std.math.floatMin(f64) },
        .{ .name = "LEAST-NEGATIVE-NORMALIZED-DOUBLE-FLOAT", .v = -std.math.floatMin(f64) },
        .{ .name = "DOUBLE-FLOAT-EPSILON", .v = std.math.floatEps(f64) / 2 },
        .{ .name = "DOUBLE-FLOAT-NEGATIVE-EPSILON", .v = std.math.floatEps(f64) / 4 },
    };
    for (singles) |c| {
        const sym = try ev.interner.intern(c.name);
        symbol_mod.symbol(sym).value_cell = try ev.heap.allocSingleFloat(c.v);
        const short = try ev.interner.intern(try shortName(ev, c.name, "SINGLE", "SHORT"));
        symbol_mod.symbol(short).value_cell = symbol_mod.symbol(sym).value_cell;
    }
    for (doubles) |c| {
        const sym = try ev.interner.intern(c.name);
        symbol_mod.symbol(sym).value_cell = try ev.heap.allocDoubleFloat(c.v);
        const long = try ev.interner.intern(try shortName(ev, c.name, "DOUBLE", "LONG"));
        symbol_mod.symbol(long).value_cell = symbol_mod.symbol(sym).value_cell;
    }
}

/// The aliased name, e.g. MOST-POSITIVE-SHORT-FLOAT for the single-float
/// constant. The buffer is scratch the interner copies out of.
var alias_buf: [64]u8 = undefined;
fn shortName(ev: *Evaluator, name: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    _ = ev;
    const at = std.mem.indexOf(u8, name, from).?;
    var written: usize = 0;
    @memcpy(alias_buf[written..][0..at], name[0..at]);
    written += at;
    @memcpy(alias_buf[written..][0..to.len], to);
    written += to.len;
    const rest = name[at + from.len ..];
    @memcpy(alias_buf[written..][0..rest.len], rest);
    written += rest.len;
    return alias_buf[0..written];
}
