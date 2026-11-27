//! What each piece of text reads as: comments, numbers, strings,
//! characters, symbols and the standard macro characters, each checked
//! by printing what was read.

const std = @import("std");
const zisp = @import("zisp");

const heap = zisp.heap;
const symbol = zisp.symbol;
const printer = zisp.printer;
const Value = zisp.value.Value;
const Source = zisp.reader.Source;
const Reader = zisp.reader.Reader;
const ReaderError = zisp.reader.ReaderError;

const Setup = struct {
    arena: std.heap.ArenaAllocator,
    h: heap.Heap,
    interner: symbol.Interner,

    fn create() !*Setup {
        const s = try std.testing.allocator.create(Setup);
        s.* = .{
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .h = undefined,
            .interner = try symbol.Interner.init(std.testing.allocator),
        };
        s.h = heap.Heap.init(s.arena.allocator());
        try symbol.initStandardSymbols(&s.interner);
        return s;
    }

    fn destroy(self: *Setup) void {
        self.interner.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }
};

/// Every form `text` holds, printed one after another with a space
/// between them.
fn expectReads(text: []const u8, printed: []const u8) !void {
    const s = try Setup.create();
    defer s.destroy();
    var source = Source.init(text);
    var rd = Reader.init(&source, &s.h, &s.interner);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (try rd.read()) |v| {
        if (out.items.len > 0) try out.append(std.testing.allocator, ' ');
        const one = try printer.printToOwnedSlice(std.testing.allocator, v);
        defer std.testing.allocator.free(one);
        try out.appendSlice(std.testing.allocator, one);
    }
    try std.testing.expectEqualStrings(printed, out.items);
}

fn expectError(text: []const u8, want: ReaderError) !void {
    const s = try Setup.create();
    defer s.destroy();
    var source = Source.init(text);
    var rd = Reader.init(&source, &s.h, &s.interner);
    while (true) {
        const got = rd.read() catch |err| return std.testing.expectEqual(want, err);
        if (got == null) return error.TestExpectedError;
    }
}

// --- whitespace and comments ----------------------------------------

test "empty input reads nothing" {
    try expectReads("", "");
}

test "whitespace alone reads nothing" {
    try expectReads("   \t\n\r\x0c\x0b   ", "");
}

test "the source counts lines and columns" {
    var source = Source.init("a\n  b");
    _ = source.next();
    _ = source.next();
    try std.testing.expectEqual(@as(u32, 2), source.pos().line);
    try std.testing.expectEqual(@as(u32, 1), source.pos().column);
    _ = source.next();
    _ = source.next();
    try std.testing.expectEqual(@as(u32, 3), source.pos().column);
    try std.testing.expectEqual(@as(u32, 4), source.pos().byte_offset);
}

test "a line comment is skipped" {
    try expectReads("; ignore me\n42", "42");
}

test "a line comment at the end without a newline reads nothing" {
    try expectReads("; trailing", "");
}

test "a block comment is skipped" {
    try expectReads("#| ignored |# 7", "7");
}

test "block comments nest" {
    try expectReads("#| outer #| inner |# still-outer |# 9", "9");
    try expectReads("#|a#|b#|c|#b|#a|#1", "1");
}

test "an unterminated block comment ends the input inside an object" {
    try expectError("#| no end", ReaderError.EndOfInput);
    try expectError("#| outer #| inner |# missing-outer", ReaderError.EndOfInput);
}

test "comments and forms interleave" {
    try expectReads(";; top\n(a #| inline |# b)\n;; trailing", "(A B)");
}

// --- numbers ----------------------------------------------------------

test "integers read with their sign" {
    try expectReads("42 -42 +7", "42 -42 7");
}

test "a trailing point reads an integer in decimal" {
    try expectReads("123.", "123");
}

test "the radix macros read integers" {
    try expectReads("#b1010 #B1111 #o755 #xDEADBEEF #x-FF", "10 15 493 3735928559 -255");
    try expectReads("#16rFF #36rZZ #10R12", "255 1295 12");
}

test "a radix macro without digits is a bad token" {
    try expectError("(#b)", ReaderError.BadToken);
    try expectError("(#10R)", ReaderError.BadToken);
}

test "a radix macro at the end of the input ends it inside an object" {
    try expectError("#b", ReaderError.EndOfInput);
    try expectError("#10R", ReaderError.EndOfInput);
}

test "a radix outside 2 to 36 is a bad token" {
    try expectError("#1R0", ReaderError.BadToken);
    try expectError("#37R0", ReaderError.BadToken);
}

test "ratios read in lowest terms" {
    try expectReads("1/2 -3/4 4/2", "1/2 -3/4 2");
}

test "text that is not number syntax reads as a symbol" {
    try expectReads("1.5/2 1e2/3 1- 1+ 1/ 123abc 1eX", "|1.5/2| |1E2/3| 1- 1+ |1/| |123ABC| |1EX|");
}

test "an escape keeps number-shaped text a symbol" {
    try expectReads("1\\2", "|12|");
}

test "floats read with each exponent marker" {
    try expectReads("1.5 .5 1e10 1.5d0 1f0", "1.5 0.5 1.0e10 1.5d0 1.0");
}

// --- strings and characters -------------------------------------------

test "strings read with their escapes" {
    try expectReads("\"hello\" \"a\\\"b\" \"a\\\\b\" \"\"", "\"hello\" \"a\\\"b\" \"a\\\\b\" \"\"");
}

test "an unterminated string ends the input inside an object" {
    try expectError("\"oops", ReaderError.EndOfInput);
    try expectError("\"oops\\", ReaderError.EndOfInput);
}

test "characters read by themselves and by name" {
    try expectReads("#\\A #\\Space #\\Newline #\\U+03BB", "#\\A #\\Space #\\Newline #\\λ");
    try expectReads("#\\( #\\\\ #\\  #\\3", "#\\( #\\\\ #\\Space #\\3");
}

test "a character at the end of the input ends it inside an object" {
    try expectError("#\\", ReaderError.EndOfInput);
}

// --- symbols ----------------------------------------------------------

test "keywords read with their escapes" {
    try expectReads(":foo :|Mixed Case| :foo\\(bar :|a\\|b| :|a\\\\b|", ":FOO :|Mixed Case| :|FOO(BAR| :|a\\|b| :|a\\\\b|");
}

test "an unterminated multiple escape ends the input inside an object" {
    try expectError(":|oops", ReaderError.EndOfInput);
    try expectError(":|oops\\", ReaderError.EndOfInput);
    try expectError("|oops", ReaderError.EndOfInput);
    try expectError("|oops\\", ReaderError.EndOfInput);
}

test "symbols read upcased with their escapes kept" {
    try expectReads("hello foo-bar? + - -- .foo", "HELLO FOO-BAR? + - -- .FOO");
    try expectReads("|Mixed Case| |a\\|b| |a\\\\b| foo\\;bar", "|Mixed Case| |a\\|b| |a\\\\b| |FOO;BAR|");
}

test "a single escape at the end of the input ends it inside an object" {
    try expectError("foo\\", ReaderError.EndOfInput);
}

// --- macro characters -------------------------------------------------

test "the standard macro characters read their forms" {
    try expectReads("() 'x `x #'x #(1 2)", "NIL (QUOTE X) (QUASIQUOTE X) (FUNCTION X) #(1 2)");
    try expectReads("`(,x ,@y)", "(QUASIQUOTE ((UNQUOTE X) (UNQUOTE-SPLICING Y)))");
}

test "a feature expression decides whether the next form is read" {
    try expectReads("#+sbcl x #-windows y", "Y");
}

test "a dot reads as a cons's tail" {
    try expectReads("(a . b)", "(A . B)");
}

test "a dot alone is a bad token" {
    try expectError(".", ReaderError.BadToken);
}

test "a dispatching macro with no sub-character ends the input inside an object" {
    try expectError("#", ReaderError.EndOfInput);
}

test "a sub-character with no function is a bad token" {
    try expectError("#$", ReaderError.BadToken);
}

test "a small program reads as one form" {
    try expectReads("(defun fact (n) (if (zerop n) 1 (* n (fact (1- n)))))", "(DEFUN FACT (N) (IF (ZEROP N) 1 (* N (FACT (1- N)))))");
}
