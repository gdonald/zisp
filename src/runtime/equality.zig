//! The four standard equality predicates and the hashing that has to agree
//! with them. A hash table's test picks one pair: keys that compare equal
//! under the test must hash the same.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const bignum = @import("bignum.zig");
const character = @import("character.zig");

const Value = value.Value;
pub const Test = heap.HashTest;

pub fn eq(a: Value, b: Value) bool {
    return a.equalsRaw(b);
}

/// Identity, plus numeric equality for the boxed number types.
pub fn eql(a: Value, b: Value) bool {
    if (a.equalsRaw(b)) return true;
    if (a.tag() != .heap or b.tag() != .heap) return false;
    const ta = heap.heapType(a);
    if (ta != heap.heapType(b)) return false;
    // Floats compare by bit pattern, so 0.0 and -0.0 are not eql even
    // though `=` says they are equal.
    return switch (ta) {
        .single_float => @as(u32, @bitCast(heap.asSingleFloat(a).value)) ==
            @as(u32, @bitCast(heap.asSingleFloat(b).value)),
        .double_float => @as(u64, @bitCast(heap.asDoubleFloat(a).value)) ==
            @as(u64, @bitCast(heap.asDoubleFloat(b).value)),
        .ratio => eql(heap.asRatio(a).numerator, heap.asRatio(b).numerator) and
            eql(heap.asRatio(a).denominator, heap.asRatio(b).denominator),
        .bignum => heap.asBignum(a).toConst().eql(heap.asBignum(b).toConst()),
        .complex => eql(heap.asComplex(a).realpart, heap.asComplex(b).realpart) and
            eql(heap.asComplex(a).imagpart, heap.asComplex(b).imagpart),
        else => false,
    };
}

pub fn isNumber(v: Value) bool {
    if (v.isFixnum()) return true;
    if (v.tag() != .heap) return false;
    return switch (heap.heapType(v)) {
        .single_float, .double_float, .ratio, .bignum, .complex => true,
        else => false,
    };
}

pub fn toF64(v: Value) f64 {
    if (v.isFixnum()) return @floatFromInt(v.toFixnum());
    const t = heap.heapType(v);
    if (t == .single_float) return heap.asSingleFloat(v).value;
    if (t == .double_float) return heap.asDoubleFloat(v).value;
    if (t == .bignum) return heap.asBignum(v).toConst().toFloat(f64, .nearest_even)[0];
    const r = heap.asRatio(v);
    return bignum.ratioToF64(r.numerator, r.denominator);
}

pub fn numEqual(a: Value, b: Value) bool {
    // Two integers compare exactly; going through f64 would lose the low
    // bits of anything past 2^53.
    if (bignum.isInteger(a) and bignum.isInteger(b)) {
        var lhs = bignum.Scratch{};
        var rhs = bignum.Scratch{};
        return lhs.view(a).eql(rhs.view(b));
    }
    return toF64(a) == toF64(b);
}

/// `eql`, plus structural comparison of conses and strings.
pub fn equal(a: Value, b: Value) bool {
    if (eql(a, b)) return true;
    if (a.isCons() and b.isCons()) {
        return equal(heap.car(a), heap.car(b)) and equal(heap.cdr(a), heap.cdr(b));
    }
    if (heap.isString(a) and heap.isString(b)) {
        return std.mem.eql(u32, heap.asString(a).constSlice(), heap.asString(b).constSlice());
    }
    if (heap.isPathname(a) and heap.isPathname(b)) return pathnamesEqual(a, b);
    return false;
}

pub fn charLower(c: u21) u21 {
    return character.downcase(c);
}

pub fn stringEqualFold(a: []const u32, b: []const u32) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (charLower(@intCast(ca)) != charLower(@intCast(cb))) return false;
    }
    return true;
}

/// `equal`, ignoring character case, comparing numbers across types, and
/// descending into arrays.
pub fn equalp(a: Value, b: Value) bool {
    if (isNumber(a) and isNumber(b)) return numEqual(a, b);
    if (a.isChar() and b.isChar()) return charLower(a.toChar()) == charLower(b.toChar());
    if (a.isCons() and b.isCons()) {
        return equalp(heap.car(a), heap.car(b)) and equalp(heap.cdr(a), heap.cdr(b));
    }
    if (heap.isString(a) and heap.isString(b)) {
        return stringEqualFold(heap.asString(a).constSlice(), heap.asString(b).constSlice());
    }
    if (heap.isPathname(a) and heap.isPathname(b)) return pathnamesEqual(a, b);
    if (heap.isArray(a) and heap.isArray(b)) {
        const va = heap.arrayActive(a);
        const vb = heap.arrayActive(b);
        if (va.len != vb.len) return false;
        for (va, vb) |ea, eb| {
            if (!equalp(ea, eb)) return false;
        }
        return true;
    }
    return a.equalsRaw(b);
}

/// Two pathnames are equal when every component is.
fn pathnamesEqual(a: Value, b: Value) bool {
    const x = heap.asPathname(a);
    const y = heap.asPathname(b);
    return equal(x.host, y.host) and equal(x.device, y.device) and
        equal(x.directory, y.directory) and equal(x.name, y.name) and
        equal(x.type_, y.type_) and equal(x.version, y.version);
}

pub fn matches(kind: Test, a: Value, b: Value) bool {
    return switch (kind) {
        .eq => eq(a, b),
        .eql => eql(a, b),
        .equal => equal(a, b),
        .equalp => equalp(a, b),
    };
}

// --- hashing ---

/// Structural hashing stops here. A cycle would otherwise recurse forever,
/// and the shallow prefix is enough to spread keys across buckets.
const MAX_HASH_DEPTH: u32 = 8;

pub fn hash(kind: Test, v: Value) u64 {
    return hashAt(kind, v, 0);
}

fn hashAt(kind: Test, v: Value, depth: u32) u64 {
    return switch (kind) {
        .eq => v.raw,
        .eql => eqlHash(v),
        .equal => equalHash(v, depth),
        .equalp => equalpHash(v, depth),
    };
}

fn mix(a: u64, b: u64) u64 {
    return (a *% 0x9E3779B97F4A7C15) ^ (b +% 0x165667B19E3779F9);
}

fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn hashChars(codes: []const u32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(codes));
}

fn numberHash(v: Value) u64 {
    return @bitCast(toF64(v));
}

fn eqlHash(v: Value) u64 {
    if (v.tag() != .heap) return v.raw;
    return switch (heap.heapType(v)) {
        .single_float, .double_float => mix(1, numberHash(v)),
        .ratio => mix(9, mix(eqlHash(heap.asRatio(v).numerator), eqlHash(heap.asRatio(v).denominator))),
        .bignum => mix(8, bignumHash(v)),
        .complex => mix(10, mix(eqlHash(heap.asComplex(v).realpart), eqlHash(heap.asComplex(v).imagpart))),
        else => v.raw,
    };
}

fn bignumHash(v: Value) u64 {
    const n = heap.asBignum(v).toConst();
    var hasher = std.hash.Wyhash.init(@intFromBool(n.positive));
    for (n.limbs) |limb| hasher.update(std.mem.asBytes(&limb));
    return hasher.final();
}

fn equalHash(v: Value, depth: u32) u64 {
    if (heap.isString(v)) return mix(2, hashChars(heap.asString(v).constSlice()));
    if (heap.isPathname(v)) {
        const path = heap.asPathname(v);
        return mix(3, mix(
            mix(equalHash(path.directory, depth + 1), equalHash(path.name, depth + 1)),
            mix(equalHash(path.type_, depth + 1), equalHash(path.version, depth + 1)),
        ));
    }
    if (v.isCons()) {
        if (depth >= MAX_HASH_DEPTH) return 4;
        return mix(equalHash(heap.car(v), depth + 1), equalHash(heap.cdr(v), depth + 1));
    }
    return eqlHash(v);
}

fn equalpHash(v: Value, depth: u32) u64 {
    // Numbers compare across types under equalp, so they all hash as f64.
    if (isNumber(v)) return mix(5, numberHash(v));
    if (v.isChar()) return mix(6, charLower(v.toChar()));
    if (heap.isString(v)) {
        var folded = std.hash.Wyhash.init(0);
        for (heap.asString(v).constSlice()) |c| {
            const lowered: u32 = charLower(@intCast(c));
            folded.update(std.mem.asBytes(&lowered));
        }
        return mix(2, folded.final());
    }
    if (v.isCons()) {
        if (depth >= MAX_HASH_DEPTH) return 4;
        return mix(equalpHash(heap.car(v), depth + 1), equalpHash(heap.cdr(v), depth + 1));
    }
    if (heap.isArray(v)) {
        if (depth >= MAX_HASH_DEPTH) return 7;
        var acc: u64 = 7;
        for (heap.arrayActive(v)) |element| acc = mix(acc, equalpHash(element, depth + 1));
        return acc;
    }
    return v.raw;
}
