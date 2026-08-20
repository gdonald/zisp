//! Complex numbers. Both parts are reals of the same kind: either both
//! rational, or both floats of the same format.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const bignum = @import("bignum.zig");
const equality = @import("equality.zig");

const Value = value.Value;
const Heap = heap.Heap;

pub const Error = bignum.Error || error{TypeError};

pub fn isFloat(v: Value) bool {
    return heap.isSingleFloat(v) or heap.isDoubleFloat(v);
}

pub fn isReal(v: Value) bool {
    return bignum.isRational(v) or isFloat(v);
}

pub fn isNumber(v: Value) bool {
    return isReal(v) or heap.isComplex(v);
}

pub fn realpartOf(v: Value) Value {
    if (heap.isComplex(v)) return heap.asComplex(v).realpart;
    return v;
}

pub fn imagpartOf(h: *Heap, v: Value) Error!Value {
    if (heap.isComplex(v)) return heap.asComplex(v).imagpart;
    // The imaginary part of a real matches its own kind, so a float real
    // yields a float zero.
    if (heap.isSingleFloat(v)) return h.allocSingleFloat(0);
    if (heap.isDoubleFloat(v)) return h.allocDoubleFloat(0);
    return Value.fromFixnum(0);
}

/// Build a complex from two reals, applying the two canonicalizations
/// CLHS requires: a rational zero imaginary part collapses to the real,
/// and a float in either part makes both parts floats of that format.
pub fn make(h: *Heap, realpart: Value, imagpart: Value) Error!Value {
    if (!isReal(realpart) or !isReal(imagpart)) return Error.TypeError;
    // Both parts, and each boxed result, are held while the other part
    // is boxed.
    var held = h.protect();
    defer held.close();
    try held.push(realpart);
    try held.push(imagpart);
    if (heap.isDoubleFloat(realpart) or heap.isDoubleFloat(imagpart)) {
        const boxed_real = try h.allocDoubleFloat(equality.toF64(realpart));
        try held.push(boxed_real);
        const boxed_imag = try h.allocDoubleFloat(equality.toF64(imagpart));
        return h.allocComplex(boxed_real, boxed_imag);
    }
    if (heap.isSingleFloat(realpart) or heap.isSingleFloat(imagpart)) {
        const boxed_real = try h.allocSingleFloat(@floatCast(equality.toF64(realpart)));
        try held.push(boxed_real);
        const boxed_imag = try h.allocSingleFloat(@floatCast(equality.toF64(imagpart)));
        return h.allocComplex(boxed_real, boxed_imag);
    }
    if (bignum.isZero(bignum.numeratorOf(imagpart))) return realpart;
    return h.allocComplex(realpart, imagpart);
}
