//! Character builtins: codes and names, the two comparison families, case
//! conversion, and the classification predicates.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

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

    fn evalStr(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| {
            result = try self.ev.eval(form);
        }
        return result;
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectFix(self: *Fixture, src: []const u8, expected: i64) !void {
        try testing.expectEqual(expected, (try self.evalStr(src)).toFixnum());
    }

    fn expectChar(self: *Fixture, src: []const u8, expected: u21) !void {
        const v = try self.evalStr(src);
        try testing.expectEqual(@as(u8, @intFromEnum(value.Tag.char)), @intFromEnum(v.tag()));
        try testing.expectEqual(expected, v.toChar());
    }

    fn expectText(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.evalStr(src);
        try testing.expect(heap_mod.isString(v));
        const text = try heap_mod.stringUtf8Alloc(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    fn expectErr(self: *Fixture, err: Error, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- character objects ---

test "a character is not a number" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(characterp #\\a)");
    try fx.expectNil("(characterp 97)");
    try fx.expectNil("(eql #\\a 97)");
    try fx.expectNil("(equal #\\a 97)");
    try fx.expectNil("(numberp #\\a)");
    try fx.expectT("(typep #\\a 'character)");
    try fx.expectErr(Error.WrongArgCount, "(characterp)");
}

test "char-code and code-char are inverses" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(char-code #\\a)", 97);
    try fx.expectFix("(char-int #\\a)", 97);
    try fx.expectChar("(code-char 97)", 'a');
    try fx.expectChar("(code-char (char-code #\\U+1F600))", 0x1F600);
    try fx.expectFix("char-code-limit", 0x110000);
}

test "code-char rejects a code that names no character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(code-char 1114112)");
    try fx.expectNil("(code-char 55296)");
    try fx.expectNil("(code-char 57343)");
    try fx.expectErr(Error.TypeError, "(code-char -1)");
    try fx.expectErr(Error.TypeError, "(code-char #\\a)");
    try fx.expectErr(Error.WrongArgCount, "(code-char)");
    try fx.expectErr(Error.TypeError, "(char-code 97)");
    try fx.expectErr(Error.WrongArgCount, "(char-code)");
}

test "char-name and name-char cover the named characters" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(char-name #\\Space)", "Space");
    try fx.expectText("(char-name #\\Newline)", "Newline");
    try fx.expectText("(char-name #\\Null)", "Null");
    try fx.expectText("(char-name #\\Rubout)", "Rubout");
    try fx.expectNil("(char-name #\\a)");
    try fx.expectChar("(name-char \"Space\")", ' ');
    try fx.expectChar("(name-char \"newline\")", '\n');
    try fx.expectChar("(name-char \"Linefeed\")", '\n');
    try fx.expectNil("(name-char \"nonesuch\")");
}

test "char-name and name-char check their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(char-name)");
    try fx.expectErr(Error.TypeError, "(char-name 97)");
    try fx.expectErr(Error.WrongArgCount, "(name-char)");
    try fx.expectErr(Error.TypeError, "(name-char 97)");
}

// --- case ---

test "char-upcase and char-downcase cover ascii and latin-1" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectChar("(char-upcase #\\a)", 'A');
    try fx.expectChar("(char-downcase #\\A)", 'a');
    try fx.expectChar("(char-upcase #\\1)", '1');
    try fx.expectChar("(char-upcase #\\U+00E9)", 0xC9);
    try fx.expectChar("(char-downcase #\\U+00C9)", 0xE9);
    // The one Latin-1 letter whose uppercase lies outside the block.
    try fx.expectChar("(char-upcase #\\U+00FF)", 0x178);
    try fx.expectChar("(char-downcase #\\U+0178)", 0xFF);
    // The tables reach Greek and Cyrillic as well.
    try fx.expectChar("(char-upcase #\\U+03B1)", 0x391);
    try fx.expectChar("(char-downcase #\\U+0410)", 0x430);
    try fx.expectErr(Error.WrongArgCount, "(char-upcase)");
    try fx.expectErr(Error.TypeError, "(char-downcase 97)");
}

test "string case conversion follows char-upcase" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-upcase \"h\xc3\xa9llo\")", "H\xc3\x89LLO");
    try fx.expectText("(string-downcase \"H\xc3\x89LLO\")", "h\xc3\xa9llo");
    try fx.expectT("(string-equal \"\xc3\x89\" \"\xc3\xa9\")");
    // The one Latin-1 letter whose uppercase lies outside the block.
    try fx.expectText("(string-upcase \"\xc3\xbf\")", "\xc5\xb8");
}

// --- comparison ---

test "the exact comparisons chain over their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(char= #\\a #\\a #\\a)");
    try fx.expectNil("(char= #\\a #\\A)");
    try fx.expectT("(char< #\\a #\\b #\\c)");
    try fx.expectNil("(char< #\\a #\\c #\\b)");
    try fx.expectT("(char> #\\c #\\b)");
    try fx.expectT("(char<= #\\a #\\a #\\b)");
    try fx.expectT("(char>= #\\b #\\a #\\a)");
    try fx.expectT("(char= #\\a)");
}

test "char/= holds only when every pair differs" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(char/= #\\a #\\b #\\c)");
    try fx.expectNil("(char/= #\\a #\\b #\\a)");
    try fx.expectNil("(char/= #\\a #\\a)");
}

test "the folded comparisons ignore case" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(char-equal #\\a #\\A)");
    try fx.expectNil("(char-equal #\\a #\\b)");
    try fx.expectT("(char-lessp #\\a #\\B)");
    try fx.expectT("(char-greaterp #\\B #\\a)");
    try fx.expectT("(char-not-greaterp #\\a #\\A)");
    try fx.expectT("(char-not-lessp #\\A #\\a)");
    try fx.expectT("(char-not-equal #\\a #\\b)");
    try fx.expectNil("(char-not-equal #\\a #\\A)");
}

test "the comparisons check their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(char=)");
    try fx.expectErr(Error.WrongArgCount, "(char/=)");
    try fx.expectErr(Error.TypeError, "(char= #\\a 97)");
    try fx.expectErr(Error.TypeError, "(char-equal #\\a 97)");
    try fx.expectErr(Error.TypeError, "(char/= #\\a 97)");
}

// --- classification ---

test "the classification predicates read ascii and latin-1" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(alpha-char-p #\\a)");
    try fx.expectT("(alpha-char-p #\\U+00E9)");
    try fx.expectNil("(alpha-char-p #\\1)");
    try fx.expectNil("(alpha-char-p #\\U+00D7)");
    try fx.expectT("(alphanumericp #\\1)");
    try fx.expectT("(alphanumericp #\\a)");
    try fx.expectNil("(alphanumericp #\\-)");
    try fx.expectT("(upper-case-p #\\A)");
    try fx.expectNil("(upper-case-p #\\a)");
    try fx.expectNil("(upper-case-p #\\1)");
    try fx.expectT("(lower-case-p #\\a)");
    try fx.expectT("(both-case-p #\\a)");
    try fx.expectNil("(both-case-p #\\1)");
}

test "graphic and standard characters" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(graphic-char-p #\\Space)");
    try fx.expectT("(graphic-char-p #\\a)");
    try fx.expectNil("(graphic-char-p #\\Newline)");
    try fx.expectNil("(graphic-char-p #\\Rubout)");
    try fx.expectNil("(graphic-char-p #\\U+0085)");
    try fx.expectT("(standard-char-p #\\Newline)");
    try fx.expectT("(standard-char-p #\\a)");
    try fx.expectNil("(standard-char-p #\\Tab)");
    try fx.expectNil("(standard-char-p #\\U+00E9)");
}

test "the classification predicates take exactly one character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "(alpha-char-p)",    "(alphanumericp)", "(upper-case-p)",
        "(lower-case-p)",    "(both-case-p)",   "(graphic-char-p)",
        "(standard-char-p)",
    }) |src| {
        try fx.expectErr(Error.WrongArgCount, src);
    }
    try fx.expectErr(Error.TypeError, "(alpha-char-p 97)");
}

// --- digits ---

test "digit-char-p reads a digit in the given radix" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(digit-char-p #\\7)", 7);
    try fx.expectFix("(digit-char-p #\\f 16)", 15);
    try fx.expectFix("(digit-char-p #\\F 16)", 15);
    try fx.expectFix("(digit-char-p #\\z 36)", 35);
    try fx.expectNil("(digit-char-p #\\f)");
    try fx.expectNil("(digit-char-p #\\8 8)");
    try fx.expectNil("(digit-char-p #\\-)");
}

test "digit-char produces the character for a weight" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectChar("(digit-char 7)", '7');
    try fx.expectChar("(digit-char 10 16)", 'A');
    try fx.expectChar("(digit-char 35 36)", 'Z');
    try fx.expectNil("(digit-char 10)");
    try fx.expectNil("(digit-char 300 36)");
}

test "the digit functions check their radix and arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(digit-char-p)");
    try fx.expectErr(Error.WrongArgCount, "(digit-char-p #\\1 10 10)");
    try fx.expectErr(Error.TypeError, "(digit-char-p 1)");
    try fx.expectErr(Error.TypeError, "(digit-char-p #\\1 1)");
    try fx.expectErr(Error.TypeError, "(digit-char-p #\\1 37)");
    try fx.expectErr(Error.TypeError, "(digit-char-p #\\1 'x)");
    try fx.expectErr(Error.WrongArgCount, "(digit-char)");
    try fx.expectErr(Error.TypeError, "(digit-char -1)");
    try fx.expectErr(Error.TypeError, "(digit-char #\\1)");
}
