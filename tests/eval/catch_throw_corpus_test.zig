//! catch / throw acceptance corpus.
//!
//! Reads `tests/lisp/catch-throw-corpus.lisp`, evaluates each form, and
//! checks the result against the value SBCL produces for the same form
//! (recorded as the first token on each line). Non-local control transfer
//! is exact, so a single mismatch fails the suite.

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;

const corpus_text = @embedFile("../lisp/catch-throw-corpus.lisp");

const Expected = union(enum) { nil, fixnum: i64 };

const Entry = struct {
    expected: Expected,
    form_src: []const u8,
    line_no: u32,
};

const ParseError = error{MalformedCorpusLine};

fn parseEntry(line: []const u8, line_no: u32) !?Entry {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == line.len) return null; // blank
    if (line[i] == ';') return null; // comment

    const rest = line[i..];
    const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return ParseError.MalformedCorpusLine;
    const expected_tok = rest[0..sep];
    const form_src = std.mem.trim(u8, rest[sep..], " \t");
    if (form_src.len == 0) return ParseError.MalformedCorpusLine;

    const expected: Expected = if (std.mem.eql(u8, expected_tok, "NIL"))
        .nil
    else
        .{ .fixnum = std.fmt.parseInt(i64, expected_tok, 10) catch return ParseError.MalformedCorpusLine };

    return .{ .expected = expected, .form_src = form_src, .line_no = line_no };
}

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

test "catch/throw corpus evaluates to SBCL values" {
    var iter = std.mem.splitScalar(u8, corpus_text, '\n');
    var line_no: u32 = 0;
    var checked: u32 = 0;
    while (iter.next()) |line| {
        line_no += 1;
        const entry = (parseEntry(line, line_no) catch |e| {
            std.debug.print("corpus line {d} malformed: {s}\n  >> {s}\n", .{ line_no, @errorName(e), line });
            return e;
        }) orelse continue;

        const fx = try Fixture.init(std.testing.allocator);
        defer fx.deinit(std.testing.allocator);

        var tk = Tokenizer.init(entry.form_src);
        var rd = Reader.init(&tk, &fx.heap, &fx.interner);
        const form = (try rd.read()) orelse {
            std.debug.print("corpus line {d}: empty form\n", .{line_no});
            return error.MalformedCorpusLine;
        };

        const got = fx.ev.eval(form) catch |e| {
            std.debug.print("corpus line {d}: eval error {s}\n  >> {s}\n", .{ line_no, @errorName(e), entry.form_src });
            return e;
        };

        switch (entry.expected) {
            .nil => if (!got.equalsRaw(value.NIL)) {
                std.debug.print("corpus line {d}: expected NIL\n  >> {s}\n", .{ line_no, entry.form_src });
                return error.TestUnexpectedResult;
            },
            .fixnum => |want| {
                if (got.tag() != .fixnum or got.toFixnum() != want) {
                    std.debug.print("corpus line {d}: expected {d}\n  >> {s}\n", .{ line_no, want, entry.form_src });
                    return error.TestUnexpectedResult;
                }
            },
        }
        checked += 1;
    }
    try std.testing.expectEqual(@as(u32, 6), checked);
}
