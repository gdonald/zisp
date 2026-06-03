//! Multiple-values acceptance corpus.
//!
//! Reads `tests/lisp/multiple-values-corpus.lisp`, evaluates each form, and
//! checks the form's complete value list (the evaluator's values channel)
//! against the list SBCL produces, recorded as the first token on the line.

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;

const corpus_text = @embedFile("../lisp/multiple-values-corpus.lisp");

const ExpectedValue = union(enum) { nil, fixnum: i64 };

const ParseError = error{MalformedCorpusLine};

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
};

fn parseExpected(allocator: std.mem.Allocator, spec: []const u8) ![]ExpectedValue {
    if (std.mem.eql(u8, spec, "<none>")) return allocator.alloc(ExpectedValue, 0);
    var list: std.ArrayList(ExpectedValue) = .empty;
    errdefer list.deinit(allocator);
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "NIL")) {
            try list.append(allocator, .nil);
        } else {
            const n = std.fmt.parseInt(i64, part, 10) catch return ParseError.MalformedCorpusLine;
            try list.append(allocator, .{ .fixnum = n });
        }
    }
    return list.toOwnedSlice(allocator);
}

test "multiple-values corpus matches SBCL value lists" {
    const gpa = std.testing.allocator;
    var iter = std.mem.splitScalar(u8, corpus_text, '\n');
    var line_no: u32 = 0;
    var checked: u32 = 0;
    while (iter.next()) |raw| {
        line_no += 1;
        var i: usize = 0;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        if (i == raw.len) continue; // blank
        if (raw[i] == ';') continue; // comment

        const rest = raw[i..];
        const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return ParseError.MalformedCorpusLine;
        const spec = rest[0..sep];
        const form_src = std.mem.trim(u8, rest[sep..], " \t");
        if (form_src.len == 0) return ParseError.MalformedCorpusLine;

        const expected = try parseExpected(gpa, spec);
        defer gpa.free(expected);

        const fx = try Fixture.init(gpa);
        defer fx.deinit(gpa);

        var tk = Tokenizer.init(form_src);
        var rd = Reader.init(&tk, &fx.heap, &fx.interner);
        const form = (try rd.read()) orelse return ParseError.MalformedCorpusLine;

        const primary = fx.ev.eval(form) catch |e| {
            std.debug.print("corpus line {d}: eval error {s}\n  >> {s}\n", .{ line_no, @errorName(e), form_src });
            return e;
        };
        const got = fx.ev.values.items;

        if (got.len != expected.len) {
            std.debug.print("corpus line {d}: expected {d} values, got {d}\n  >> {s}\n", .{ line_no, expected.len, got.len, form_src });
            return error.TestUnexpectedResult;
        }
        for (expected, got) |want, have| {
            switch (want) {
                .nil => if (!have.equalsRaw(value.NIL)) {
                    std.debug.print("corpus line {d}: expected NIL value\n  >> {s}\n", .{ line_no, form_src });
                    return error.TestUnexpectedResult;
                },
                .fixnum => |n| if (have.tag() != .fixnum or have.toFixnum() != n) {
                    std.debug.print("corpus line {d}: expected {d}\n  >> {s}\n", .{ line_no, n, form_src });
                    return error.TestUnexpectedResult;
                },
            }
        }
        // The primary value mirrors the first value (or NIL for zero values).
        if (expected.len == 0) {
            try std.testing.expect(primary.equalsRaw(value.NIL));
        } else switch (expected[0]) {
            .nil => try std.testing.expect(primary.equalsRaw(value.NIL)),
            .fixnum => |n| try std.testing.expectEqual(n, primary.toFixnum()),
        }
        checked += 1;
    }
    try std.testing.expectEqual(@as(u32, 8), checked);
}
