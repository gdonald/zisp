//! Integer arithmetic and the conversions between the two integer
//! representations. A value that fits the fixnum range is always a fixnum,
//! so a bignum only ever holds a number too large for one.
//!
//! Rational construction lives here too, since reducing a ratio to lowest
//! terms is integer work.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");

const Value = value.Value;
const Heap = heap.Heap;
const Limb = std.math.big.Limb;
const Const = std.math.big.int.Const;
const Managed = std.math.big.int.Managed;

pub fn isInteger(v: Value) bool {
    return v.isFixnum() or heap.isBignum(v);
}

/// Limbs for a fixnum, borrowed for the duration of one operation.
pub const Scratch = struct {
    limbs: [4]Limb = undefined,

    /// A `Const` view of any integer. Fixnum limbs live in this scratch,
    /// so it must outlive the returned view.
    pub fn view(self: *Scratch, v: Value) Const {
        if (heap.isBignum(v)) return heap.asBignum(v).toConst();
        var mutable = std.math.big.int.Mutable.init(&self.limbs, v.toFixnum());
        return mutable.toConst();
    }
};

/// The fixnum for `n` if it fits, otherwise a bignum holding it.
pub fn fromI128(h: *Heap, n: i128) !Value {
    if (n >= value.FIXNUM_MIN and n <= value.FIXNUM_MAX) {
        return Value.fromFixnum(@intCast(n));
    }
    var managed = try Managed.initSet(h.allocator, n);
    return h.allocBignum(managed.toConst());
}

/// Store a computed big integer, narrowing to a fixnum when it fits.
pub fn normalize(h: *Heap, n: Const) !Value {
    if (n.toInt(i64)) |narrow| {
        if (narrow >= value.FIXNUM_MIN and narrow <= value.FIXNUM_MAX) {
            return Value.fromFixnum(narrow);
        }
    } else |_| {}
    return h.allocBignum(n);
}

/// A `Managed` to compute into, backed by the heap so its limbs can be
/// handed straight to `normalize`.
pub fn scratchManaged(h: *Heap) !Managed {
    return Managed.init(h.allocator);
}

/// Parse an integer lexeme of any size. Returns null when the digits do
/// not form a valid number in that radix.
pub fn parse(h: *Heap, digits: []const u8, radix: u8, negative: bool) !?Value {
    const text = try h.allocator.alloc(u8, digits.len + @intFromBool(negative));
    defer h.allocator.free(text);
    if (negative) text[0] = '-';
    for (digits, text[@intFromBool(negative)..]) |c, *out| out.* = std.ascii.toLower(c);

    var managed = try Managed.init(h.allocator);
    managed.setString(radix, text) catch return null;
    return try normalize(h, managed.toConst());
}

/// Decimal digits, allocated by the caller's allocator.
pub fn toStringAlloc(allocator: std.mem.Allocator, v: Value, base: u8) ![]u8 {
    var scratch = Scratch{};
    return scratch.view(v).toStringAlloc(allocator, base, .lower);
}

/// Number of bits in the magnitude, which is CL's `integer-length` for a
/// non-negative integer.
pub fn bitCountAbs(v: Value) usize {
    var scratch = Scratch{};
    return scratch.view(v).bitCountAbs();
}

// --- integer arithmetic ---

pub const Error = error{DivisionByZero} || std.mem.Allocator.Error;

const Op = enum { add, sub, mul };

fn applyFix(op: Op, a: i128, b: i128) i128 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
    };
}

/// One arithmetic step on two integers of either size. Two fixnums take
/// the `i128` path, which cannot overflow for a single operation on values
/// bounded by the fixnum range.
fn binary(h: *Heap, op: Op, a: Value, b: Value) Error!Value {
    if (a.isFixnum() and b.isFixnum()) {
        return fromI128(h, applyFix(op, a.toFixnum(), b.toFixnum()));
    }
    var lhs_scratch = Scratch{};
    var rhs_scratch = Scratch{};
    var lhs = try lhs_scratch.view(a).toManaged(h.allocator);
    var rhs = try rhs_scratch.view(b).toManaged(h.allocator);
    var out = try Managed.init(h.allocator);
    switch (op) {
        .add => try out.add(&lhs, &rhs),
        .sub => try out.sub(&lhs, &rhs),
        .mul => try out.mul(&lhs, &rhs),
    }
    return normalize(h, out.toConst());
}

pub fn add(h: *Heap, a: Value, b: Value) Error!Value {
    return binary(h, .add, a, b);
}

pub fn sub(h: *Heap, a: Value, b: Value) Error!Value {
    return binary(h, .sub, a, b);
}

pub fn mul(h: *Heap, a: Value, b: Value) Error!Value {
    return binary(h, .mul, a, b);
}

pub fn negate(h: *Heap, a: Value) Error!Value {
    if (a.isFixnum()) return fromI128(h, -@as(i128, a.toFixnum()));
    var scratch = Scratch{};
    return normalize(h, scratch.view(a).negate());
}

pub fn isZero(a: Value) bool {
    if (a.isFixnum()) return a.toFixnum() == 0;
    return heap.asBignum(a).toConst().eqlZero();
}

pub fn isNegative(a: Value) bool {
    if (a.isFixnum()) return a.toFixnum() < 0;
    const n = heap.asBignum(a).toConst();
    return !n.positive and !n.eqlZero();
}

pub fn compare(a: Value, b: Value) std.math.Order {
    if (a.isFixnum() and b.isFixnum()) return std.math.order(a.toFixnum(), b.toFixnum());
    var lhs = Scratch{};
    var rhs = Scratch{};
    return lhs.view(a).order(rhs.view(b));
}

/// Truncating quotient. The caller has already ruled out a zero divisor.
pub fn divTrunc(h: *Heap, a: Value, b: Value) Error!Value {
    if (a.isFixnum() and b.isFixnum()) {
        return fromI128(h, @divTrunc(@as(i128, a.toFixnum()), @as(i128, b.toFixnum())));
    }
    var lhs_scratch = Scratch{};
    var rhs_scratch = Scratch{};
    var lhs = try lhs_scratch.view(a).toManaged(h.allocator);
    var rhs = try rhs_scratch.view(b).toManaged(h.allocator);
    var quotient = try Managed.init(h.allocator);
    var remainder = try Managed.init(h.allocator);
    try quotient.divTrunc(&remainder, &lhs, &rhs);
    return normalize(h, quotient.toConst());
}

/// Greatest common divisor of the two magnitudes; zero only when both are.
pub fn gcd(h: *Heap, a: Value, b: Value) Error!Value {
    if (a.isFixnum() and b.isFixnum()) {
        var x: i128 = a.toFixnum();
        var y: i128 = b.toFixnum();
        if (x < 0) x = -x;
        if (y < 0) y = -y;
        while (y != 0) {
            const t = @rem(x, y);
            x = y;
            y = t;
        }
        return fromI128(h, x);
    }
    if (isZero(a)) return absOf(h, b);
    if (isZero(b)) return absOf(h, a);
    var lhs_scratch = Scratch{};
    var rhs_scratch = Scratch{};
    var lhs = try lhs_scratch.view(a).abs().toManaged(h.allocator);
    var rhs = try rhs_scratch.view(b).abs().toManaged(h.allocator);
    var out = try Managed.init(h.allocator);
    try out.gcd(&lhs, &rhs);
    return normalize(h, out.toConst());
}

pub fn absOf(h: *Heap, a: Value) Error!Value {
    if (!isNegative(a)) return a;
    return negate(h, a);
}

// --- rationals ---

/// `num/den` reduced to lowest terms, with the sign on the numerator. A
/// denominator of one yields the integer instead of a ratio.
pub fn makeRatio(h: *Heap, num_in: Value, den_in: Value) Error!Value {
    if (isZero(den_in)) return Error.DivisionByZero;
    if (isZero(num_in)) return Value.fromFixnum(0);

    var num = num_in;
    var den = den_in;
    if (isNegative(den)) {
        num = try negate(h, num);
        den = try negate(h, den);
    }
    const divisor = try gcd(h, num, den);
    num = try divTrunc(h, num, divisor);
    den = try divTrunc(h, den, divisor);
    if (compare(den, Value.fromFixnum(1)) == .eq) return num;
    return h.allocRatio(num, den);
}

/// Numerator and denominator of any rational; an integer reads as itself
/// over one.
pub fn numeratorOf(v: Value) Value {
    if (heap.isRatio(v)) return heap.asRatio(v).numerator;
    return v;
}

pub fn denominatorOf(v: Value) Value {
    if (heap.isRatio(v)) return heap.asRatio(v).denominator;
    return Value.fromFixnum(1);
}

pub fn isRational(v: Value) bool {
    return isInteger(v) or heap.isRatio(v);
}

// --- floats as exact rationals ---

/// The exact rational a finite float denotes. Every float is a dyadic
/// rational, so this is exact rather than an approximation, which is what
/// CLHS 12.1.4.1 needs when comparing a float against a rational.
pub fn fromFloat(h: *Heap, x: f64) Error!Value {
    if (x == 0) return Value.fromFixnum(0);
    const bits: u64 = @bitCast(x);
    const negative = bits >> 63 == 1;
    const raw_exponent: i32 = @intCast((bits >> 52) & 0x7FF);
    const raw_mantissa = bits & 0xF_FFFF_FFFF_FFFF;

    // A subnormal has no implicit leading one and a fixed exponent.
    var mantissa: u64 = raw_mantissa;
    var exponent: i32 = raw_exponent - 1075;
    if (raw_exponent == 0) {
        exponent = -1074;
    } else {
        mantissa |= 1 << 52;
    }

    var num = try fromI128(h, if (negative) -@as(i128, mantissa) else @as(i128, mantissa));
    if (exponent >= 0) {
        return shiftLeft(h, num, @intCast(exponent));
    }
    const den = try shiftLeft(h, Value.fromFixnum(1), @intCast(-exponent));
    num = try makeRatio(h, num, den);
    return num;
}

/// `n * 2^count`.
pub fn shiftLeft(h: *Heap, n: Value, count: usize) Error!Value {
    var scratch = Scratch{};
    var operand = try scratch.view(n).toManaged(h.allocator);
    var out = try Managed.init(h.allocator);
    try out.shiftLeft(&operand, count);
    return normalize(h, out.toConst());
}

// --- approximating a rational as a float ---

const LIMB_BITS = @bitSizeOf(Limb);

/// The magnitude of `n` as a float plus a power-of-two scale, so that
/// `value * 2^exponent` is `|n|`. Only the top two limbs are read, which
/// is more than the 53 bits an `f64` keeps, and no allocation is needed.
fn magnitudeApprox(n: Const) struct { value: f64, exponent: i32 } {
    const limbs = n.limbs;
    const keep = @min(limbs.len, 2);
    const dropped = limbs.len - keep;
    const top: Const = .{ .limbs = limbs[dropped..], .positive = true };
    return .{
        .value = top.toFloat(f64, .nearest_even)[0],
        .exponent = @intCast(dropped * LIMB_BITS),
    };
}

/// `num/den` as a float. Dividing the two magnitudes separately would
/// overflow or underflow for a ratio like `1/2^1074`, so each side is
/// scaled first and the scales are reapplied to the quotient.
pub fn ratioToF64(num: Value, den: Value) f64 {
    var num_scratch = Scratch{};
    var den_scratch = Scratch{};
    const n = magnitudeApprox(num_scratch.view(num));
    const d = magnitudeApprox(den_scratch.view(den));
    const quotient = std.math.ldexp(n.value / d.value, n.exponent - d.exponent);
    return if (isNegative(num)) -quotient else quotient;
}
