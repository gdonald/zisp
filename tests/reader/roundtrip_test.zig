//! Reader/printer round-trip property tests.
//!
//! Property test: `read(prin1(x)) == x` for randomly generated values.
//! `==` uses structural equality via the printer — print both, compare
//! the output strings — so any reader/printer divergence (a missing
//! escape, a fold-case bug, a numeric-formatting mismatch) shows up as
//! a string mismatch.
//!
//! The generator covers fixnums, ratios, characters, strings, symbols,
//! and proper lists of those values up to a bounded depth. Single-floats
//! are skipped here because Zig's `{e}` formatting and the reader's
//! float lexer disagree on rounding at full f64 precision; that's a
//! known follow-up tracked by the float corpus instead.

const std = @import("std");
const zisp = @import("zisp");

const value = zisp.value;
const heap = zisp.heap;
const symbol = zisp.symbol;
const printer = zisp.printer;
const Value = value.Value;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;

const Setup = struct {
    arena: std.heap.ArenaAllocator,
    h: heap.Heap,
    interner: symbol.Interner,
    allocator: std.mem.Allocator,

    fn deinit(self: *Setup) void {
        self.interner.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

fn newSetup(test_allocator: std.mem.Allocator) !*Setup {
    const s = try test_allocator.create(Setup);
    s.* = .{
        .arena = std.heap.ArenaAllocator.init(test_allocator),
        .h = undefined,
        .interner = symbol.Interner.init(test_allocator),
        .allocator = test_allocator,
    };
    s.h = heap.Heap.init(s.arena.allocator());
    try symbol.initStandardSymbols(&s.interner);
    return s;
}

const Generator = struct {
    rand: std.Random,
    setup: *Setup,
    name_buf: [16]u8 = undefined,
    string_buf: [32]u8 = undefined,

    fn fixnum(self: *Generator) Value {
        // Bias toward small numbers but include the extremes.
        const r = self.rand.uintLessThan(u32, 100);
        if (r < 5) return Value.fromFixnum(value.FIXNUM_MIN);
        if (r < 10) return Value.fromFixnum(value.FIXNUM_MAX);
        const n = self.rand.intRangeAtMost(i64, -1_000_000, 1_000_000);
        return Value.fromFixnum(n);
    }

    fn character(self: *Generator) Value {
        // Spread across ASCII printable, the named characters, and a
        // multi-byte codepoint. Stay under the Unicode max so encoding
        // doesn't bail.
        const choice = self.rand.uintLessThan(u32, 100);
        if (choice < 60) return Value.fromChar(self.rand.intRangeAtMost(u21, 0x21, 0x7E));
        if (choice < 70) return Value.fromChar(' ');
        if (choice < 80) return Value.fromChar('\n');
        if (choice < 90) return Value.fromChar('\t');
        return Value.fromChar(self.rand.intRangeAtMost(u21, 0x80, 0xFFFD));
    }

    fn ratio(self: *Generator) !Value {
        var num = self.rand.intRangeAtMost(i64, -1000, 1000);
        var den = self.rand.intRangeAtMost(i64, 1, 1000);
        if (num == 0) num = 1;
        // Reduce so prin1's output matches a fresh ratio after read.
        const g = std.math.gcd(@as(u64, @intCast(@abs(num))), @as(u64, @intCast(den)));
        if (g > 1) {
            num = @divTrunc(num, @as(i64, @intCast(g)));
            den = @divTrunc(den, @as(i64, @intCast(g)));
        }
        if (den == 1) return Value.fromFixnum(num);
        return self.setup.h.allocRatio(num, den);
    }

    fn string(self: *Generator) !Value {
        const len = self.rand.uintLessThan(u32, self.string_buf.len);
        for (self.string_buf[0..len]) |*b| {
            // ASCII printable so we don't have to think about reader-side
            // codepoint reconstitution. The printer handles `\` and `"`.
            b.* = self.rand.intRangeAtMost(u8, 0x20, 0x7E);
        }
        return self.setup.h.allocString(self.string_buf[0..len]);
    }

    fn symbolValue(self: *Generator) !Value {
        // Generate names that the reader will round-trip under prin1's
        // pipe-escape rules. Ascii printable is fine; the printer chooses
        // when to wrap in pipes.
        const len = self.rand.intRangeAtMost(u32, 1, self.name_buf.len);
        for (self.name_buf[0..len]) |*b| {
            b.* = self.rand.intRangeAtMost(u8, 0x21, 0x7E);
        }
        return self.setup.interner.intern(self.name_buf[0..len]);
    }

    fn atom(self: *Generator) !Value {
        return switch (self.rand.uintLessThan(u32, 5)) {
            0 => self.fixnum(),
            1 => self.character(),
            2 => self.ratio(),
            3 => self.string(),
            else => self.symbolValue(),
        };
    }

    fn list(self: *Generator, depth: u32) GenError!Value {
        const len = self.rand.uintLessThan(u32, 5);
        var head: Value = value.NIL;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const elem = try self.anyValue(depth - 1);
            head = try self.setup.h.allocCons(elem, head);
        }
        return head;
    }

    fn anyValue(self: *Generator, depth: u32) GenError!Value {
        if (depth == 0) return self.atom();
        if (self.rand.boolean()) return self.atom();
        return self.list(depth);
    }
};

const GenError = std.mem.Allocator.Error;

/// Print, then read, then print again — equality of the two prints is
/// the round-trip test. We can't compare structurally because two reads
/// of the same source produce different cons addresses, but two prin1
/// outputs of structurally equivalent values must be byte-identical.
fn roundTripOnce(allocator: std.mem.Allocator, setup: *Setup, v: Value) !void {
    const printed = try printer.printToOwnedSlice(allocator, v);
    defer allocator.free(printed);

    var tk = Tokenizer.init(printed);
    var rd = Reader.init(&tk, &setup.h, &setup.interner);
    const re_read = (try rd.read()) orelse return error.EmptyReadback;

    const printed_again = try printer.printToOwnedSlice(allocator, re_read);
    defer allocator.free(printed_again);

    std.testing.expectEqualStrings(printed, printed_again) catch |e| {
        std.debug.print("round-trip mismatch:\n  first:  {s}\n  second: {s}\n", .{ printed, printed_again });
        return e;
    };
}

test "read(print(x)) round-trip on random values" {
    const a = std.testing.allocator;

    const seeds = [_]u64{ 1, 2, 7, 11, 23, 0xdeadbeef, 0xfeedface, 0xcafebabe };
    var iters: u32 = 0;

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const s = try newSetup(a);
        defer s.deinit();
        var gen: Generator = .{ .rand = prng.random(), .setup = s };

        var i: u32 = 0;
        while (i < 30) : (i += 1) {
            const v = try gen.anyValue(3);
            try roundTripOnce(a, s, v);
            iters += 1;
        }
    }

    // Acceptance: at least 200 round-trips. Each seed contributes 30, with
    // 8 seeds that yields 240. Guards against a future refactor that
    // shrinks the loop without anyone noticing.
    if (iters < 200) {
        std.debug.print("only ran {d} round-trips; expected >=200\n", .{iters});
        return error.TestFailed;
    }
}

test "round-trip on hand-picked tricky atoms" {
    const a = std.testing.allocator;
    const s = try newSetup(a);
    defer s.deinit();

    // Symbols with characters that exercise the pipe-escape rules.
    const tricky = [_][]const u8{
        "FOO",
        "foo",
        "Foo Bar",
        "1ABC",
        "a|b",
        "a\\b",
        "+",
        "+1",
        ".5A",
        "with()parens",
    };
    for (tricky) |name| {
        const sym = try s.interner.intern(name);
        try roundTripOnce(a, s, sym);
    }

    // Strings with the two characters CL strings escape.
    const string_cases = [_][]const u8{
        "",
        "a\"b",
        "a\\b",
        "\\\"",
    };
    for (string_cases) |raw| {
        const v = try s.h.allocString(raw);
        try roundTripOnce(a, s, v);
    }

    // Characters that trigger named-form printing.
    const char_cases = [_]u21{ ' ', '\n', '\t', '\r', 0, 'A', '!', 0x03BB };
    for (char_cases) |c| {
        try roundTripOnce(a, s, Value.fromChar(c));
    }

    // Integers at the fixnum boundaries.
    try roundTripOnce(a, s, Value.fromFixnum(value.FIXNUM_MIN));
    try roundTripOnce(a, s, Value.fromFixnum(value.FIXNUM_MAX));
    try roundTripOnce(a, s, Value.fromFixnum(0));
}
