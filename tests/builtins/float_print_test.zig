//! Float printing.
//!
//! The corpus drives the Lisp-level check that a printed float reads back
//! as the same bits. The generated sweep does the same over a thousand
//! bit patterns, including the values that historically break shortest
//! round-trip printers.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const printer = zisp.printer;
const Evaluator = zisp.eval.Evaluator;
const Value = value.Value;

const corpus_text = @embedFile("../lisp/float-print-corpus.lisp");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Print `v`, read the text back, and return what came out.
    fn roundTrip(self: *Fixture, v: Value) !Value {
        const text = try printer.printToOwnedSlice(testing.allocator, v);
        defer testing.allocator.free(text);
        var tk = zisp.reader.Tokenizer.init(text);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        return (try rd.read()) orelse error.NoForm;
    }

    fn expectDoubleRoundTrip(self: *Fixture, bits: u64) !void {
        const x: f64 = @bitCast(bits);
        const v = try self.heap.allocDoubleFloat(x);
        const back = try self.roundTrip(v);
        if (!heap_mod.isDoubleFloat(back)) {
            std.debug.print("float 0x{X} did not read back as a double\n", .{bits});
            return error.TestUnexpectedResult;
        }
        const got: u64 = @bitCast(heap_mod.asDoubleFloat(back).value);
        if (got != bits) {
            const text = try printer.printToOwnedSlice(testing.allocator, v);
            defer testing.allocator.free(text);
            std.debug.print("float 0x{X} printed as {s} and read back as 0x{X}\n", .{ bits, text, got });
            return error.TestUnexpectedResult;
        }
    }

    fn expectSingleRoundTrip(self: *Fixture, bits: u32) !void {
        const x: f32 = @bitCast(bits);
        const v = try self.heap.allocSingleFloat(x);
        const back = try self.roundTrip(v);
        if (!heap_mod.isSingleFloat(back)) {
            std.debug.print("float 0x{X} did not read back as a single\n", .{bits});
            return error.TestUnexpectedResult;
        }
        const got: u32 = @bitCast(heap_mod.asSingleFloat(back).value);
        if (got != bits) {
            const text = try printer.printToOwnedSlice(testing.allocator, v);
            defer testing.allocator.free(text);
            std.debug.print("float 0x{X} printed as {s} and read back as 0x{X}\n", .{ bits, text, got });
            return error.TestUnexpectedResult;
        }
    }
};

test "every form in the float printing corpus evaluates to T" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var tk = zisp.reader.Tokenizer.init(corpus_text);
    var rd = zisp.reader.Reader.init(&tk, &fx.heap, &fx.interner);
    var checked: u32 = 0;
    while (try rd.read()) |form| {
        checked += 1;
        const got = fx.ev.eval(form) catch |e| {
            std.debug.print("float corpus form {d}: eval error {s}\n", .{ checked, @errorName(e) });
            return e;
        };
        if (!got.equalsRaw(value.T)) {
            std.debug.print("float corpus form {d}: expected T\n", .{checked});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(u32, 9), checked);
}

/// Values that have broken shortest round-trip printers before, plus the
/// representable extremes and both zeroes.
const HARD_DOUBLES = [_]f64{
    0.0,
    -0.0,
    5e-324, // smallest subnormal
    1e-323,
    2.2250738585072011e-308, // largest subnormal
    2.2250738585072014e-308, // smallest normal
    -2.2250738585072014e-308,
    1.7976931348623157e308, // largest finite
    -1.7976931348623157e308,
    1e23, // the classic shortest-digit disagreement
    -1e23,
    9007199254740993.0, // 2^53 + 1
    9007199254740992.0, // 2^53
    1.0,
    -1.0,
    0.1,
    0.2,
    0.3,
    1e-3,
    1e7,
    123456789012345678000.0,
    4.9406564584124654e-324,
    3.1415926535897932384626433,
    2.2204460492503131e-16, // machine epsilon
};

test "the hard-case doubles round-trip bitwise" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    for (HARD_DOUBLES) |x| {
        try fx.expectDoubleRoundTrip(@bitCast(x));
    }
}

test "a thousand double bit patterns round-trip bitwise" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    // A fixed seed keeps the sweep reproducible; a failure names the bits.
    var prng = std.Random.DefaultPrng.init(0x2A15_C0FFEE);
    const random = prng.random();
    var checked: u32 = 0;
    while (checked < 1000) {
        const bits = random.int(u64);
        const x: f64 = @bitCast(bits);
        // Infinities and NaNs have no readable printed form.
        if (std.math.isNan(x) or std.math.isInf(x)) continue;
        try fx.expectDoubleRoundTrip(bits);
        checked += 1;
    }
}

test "a thousand single bit patterns round-trip bitwise" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const random = prng.random();
    var checked: u32 = 0;
    while (checked < 1000) {
        const bits = random.int(u32);
        const x: f32 = @bitCast(bits);
        if (std.math.isNan(x) or std.math.isInf(x)) continue;
        try fx.expectSingleRoundTrip(bits);
        checked += 1;
    }
}

test "subnormals at both ends of the range round-trip" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    var bits: u64 = 1;
    while (bits < 1 << 12) : (bits += 1) {
        try fx.expectDoubleRoundTrip(bits);
        try fx.expectDoubleRoundTrip(bits | (1 << 63));
    }
    var single_bits: u32 = 1;
    while (single_bits < 1 << 12) : (single_bits += 1) {
        try fx.expectSingleRoundTrip(single_bits);
    }
}

test "an infinity or a not-a-number prints as an unreadable object" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    for ([_]struct { x: f64, text: []const u8 }{
        .{ .x = std.math.inf(f64), .text = "#<infinity>" },
        .{ .x = -std.math.inf(f64), .text = "#<negative-infinity>" },
        .{ .x = std.math.nan(f64), .text = "#<not-a-number>" },
    }) |entry| {
        const v = try fx.heap.allocDoubleFloat(entry.x);
        const text = try printer.printToOwnedSlice(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(entry.text, text);
    }
}
