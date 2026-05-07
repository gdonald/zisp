//! ROADMAP Phase 1.5.1.
//!
//! Golden-file tests pin reader+printer round-trip output. Each case is
//! a (`input`, `expected_print_output`) pair: read every form in `input`
//! and prin1 them back joined with one space; diff against expected.
//!
//! These cases lock in the prin1 surface — symbol case folding, list
//! dotted notation, escape behavior — so a regression in either reader
//! or printer surfaces here as a string-diff failure.

const std = @import("std");
const zisp = @import("zisp");

const value = zisp.value;
const heap = zisp.heap;
const symbol = zisp.symbol;
const printer = zisp.printer;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;

const Case = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

const cases = [_]Case{
    .{ .name = "atom integer", .input = "42", .expected = "42" },
    .{ .name = "atom negative", .input = "-7", .expected = "-7" },
    .{ .name = "atom symbol upcased", .input = "foo", .expected = "FOO" },
    .{ .name = "list of three", .input = "(1 2 3)", .expected = "(1 2 3)" },
    .{ .name = "dotted pair", .input = "(1 . 2)", .expected = "(1 . 2)" },
    .{ .name = "nested list", .input = "(a (b c) d)", .expected = "(A (B C) D)" },
    .{ .name = "quote shortcut", .input = "'foo", .expected = "(QUOTE FOO)" },
    .{ .name = "backquote shortcut", .input = "`x", .expected = "(QUASIQUOTE X)" },
    .{ .name = "unquote shortcut", .input = ",x", .expected = "(UNQUOTE X)" },
    .{ .name = "unquote-splicing shortcut", .input = ",@x", .expected = "(UNQUOTE-SPLICING X)" },
    .{ .name = "function shortcut", .input = "#'car", .expected = "(FUNCTION CAR)" },
    .{ .name = "vector literal", .input = "#(1 2 3)", .expected = "#(1 2 3)" },
    .{ .name = "string with escapes", .input = "\"a\\\"b\"", .expected = "\"a\\\"b\"" },
    .{ .name = "character literal A", .input = "#\\A", .expected = "#\\A" },
    .{ .name = "character literal Space", .input = "#\\Space", .expected = "#\\Space" },
    .{ .name = "ratio", .input = "3/4", .expected = "3/4" },
    .{ .name = "binary integer", .input = "#b1010", .expected = "10" },
    .{ .name = "hex integer", .input = "#xFF", .expected = "255" },
    .{ .name = "pipe-quoted symbol round-trips with escape", .input = "|HiThere|", .expected = "|HiThere|" },
    .{ .name = "two forms", .input = "1 2", .expected = "1 2" },
    .{ .name = "multi-line input", .input = "(a\n  b\n  c)", .expected = "(A B C)" },
    .{ .name = "line comments are stripped", .input = "; trailing comment\n42 ; tail\n", .expected = "42" },
    .{ .name = "nested block comments", .input = "#| outer #| inner |# still |# 7", .expected = "7" },
    .{ .name = "empty input prints nothing", .input = "", .expected = "" },
    .{ .name = "empty list prints NIL", .input = "()", .expected = "NIL" },
};

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

fn readPrintAll(allocator: std.mem.Allocator, setup: *Setup, input: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var tk = Tokenizer.init(input);
    var rd = Reader.init(&tk, &setup.h, &setup.interner);
    var first = true;
    while (try rd.read()) |v| {
        if (!first) try aw.writer.writeByte(' ');
        try printer.prin1(allocator, &aw.writer, v);
        first = false;
    }
    return aw.toOwnedSlice();
}

test "1.5.1 golden corpus" {
    for (cases) |c| {
        const s = try newSetup(std.testing.allocator);
        defer s.deinit();
        const got = try readPrintAll(std.testing.allocator, s, c.input);
        defer std.testing.allocator.free(got);
        std.testing.expectEqualStrings(c.expected, got) catch |e| {
            std.debug.print("case `{s}`: input={s}\n", .{ c.name, c.input });
            return e;
        };
    }
}
