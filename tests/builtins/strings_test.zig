//! String builtins: designator coercion, make-string, element access, and
//! the three comparison predicates with their bounding-index arguments.

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

    fn expectText(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.evalStr(src);
        try testing.expect(heap_mod.isString(v));
        const text = try heap_mod.stringUtf8Alloc(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    fn expectChar(self: *Fixture, src: []const u8, expected: u21) !void {
        const v = try self.evalStr(src);
        try testing.expectEqual(expected, v.toChar());
    }

    fn expectFix(self: *Fixture, src: []const u8, expected: i64) !void {
        try testing.expectEqual(expected, (try self.evalStr(src)).toFixnum());
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectErr(self: *Fixture, err: Error, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- string designators ---

test "string coerces a string, a symbol and a character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string \"foo\")", "foo");
    try fx.expectText("(string 'foo)", "FOO");
    try fx.expectText("(string #\\a)", "a");
}

test "string rejects a non-designator and takes one argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(string 7)");
    try fx.expectErr(Error.WrongArgCount, "(string)");
}

test "simple-string-p holds for every string" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(simple-string-p \"a\")");
    try fx.expectNil("(simple-string-p 'a)");
    try fx.expectErr(Error.WrongArgCount, "(simple-string-p)");
}

test "typep recognizes the string and base-char type names" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(typep \"a\" 'string)");
    try fx.expectT("(typep \"a\" 'simple-string)");
    // A string element holds any codepoint, so a string is not a
    // base-string, whose elements are base characters.
    try fx.expectNil("(typep \"a\" 'base-string)");
    try fx.expectNil("(typep 'a 'simple-string)");
    try fx.expectT("(typep #\\a 'base-char)");
    try fx.expectNil("(typep #\\U+1F600 'base-char)");
}

// --- make-string ---

test "make-string fills with spaces unless given an initial element" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(make-string 3)", "   ");
    try fx.expectText("(make-string 3 :initial-element #\\x)", "xxx");
    try fx.expectText("(make-string 0)", "");
}

test "make-string accepts a character element type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{ "character", "base-char", "standard-char" }) |name| {
        const src = try std.fmt.allocPrint(
            testing.allocator,
            "(make-string 1 :element-type '{s})",
            .{name},
        );
        defer testing.allocator.free(src);
        try fx.expectText(src, " ");
    }
    try fx.expectErr(Error.TypeError, "(make-string 1 :element-type 'fixnum)");
    try fx.expectErr(Error.TypeError, "(make-string 1 :element-type 7)");
}

test "make-string rejects a bad size, a bad fill, and a bad option list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(make-string)");
    try fx.expectErr(Error.WrongArgCount, "(make-string 1 :initial-element)");
    try fx.expectErr(Error.TypeError, "(make-string -1)");
    try fx.expectErr(Error.TypeError, "(make-string \"3\")");
    try fx.expectErr(Error.TypeError, "(make-string 1 :initial-element 7)");
    try fx.expectErr(Error.ProgramError, "(make-string 1 :frob 2)");
}

// --- element access ---

test "char and schar read a character out of a string" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectChar("(char \"abc\" 1)", 'b');
    try fx.expectChar("(schar \"abc\" 2)", 'c');
}

test "char rejects a non-string, a bad index and the wrong argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(char 'abc 0)");
    try fx.expectErr(Error.TypeError, "(char \"abc\" 3)");
    try fx.expectErr(Error.TypeError, "(char \"abc\" -1)");
    try fx.expectErr(Error.TypeError, "(char \"abc\" #\\a)");
    try fx.expectErr(Error.WrongArgCount, "(char \"abc\")");
}

test "setf char replaces a character in place" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(let ((s (make-string 3 :initial-element #\\x))) (setf (char s 1) #\\y) s)", "xyx");
    try fx.expectText("(let ((s (make-string 2 :initial-element #\\x))) (setf (schar s 0) #\\z) s)", "zx");
}

test "setf char rejects a wide character, a bad index and the wrong argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(%set-char (make-string 1) 5 #\\a)");
    try fx.expectErr(Error.WrongArgCount, "(%set-char (make-string 1) 0)");
}

test "aref and elt read and write string elements" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectChar("(aref \"abc\" 0)", 'a');
    try fx.expectChar("(elt \"abc\" 2)", 'c');
    try fx.expectText("(let ((s (make-string 2 :initial-element #\\x))) (setf (aref s 0) #\\p) s)", "px");
    try fx.expectText("(let ((s (make-string 2 :initial-element #\\x))) (setf (elt s 1) #\\q) s)", "xq");
}

test "string element access is bounds- and type-checked through aref and elt" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(aref \"abc\" 3)");
    try fx.expectErr(Error.TypeError, "(elt \"abc\" 3)");
    try fx.expectErr(Error.TypeError, "(%set-aref \"abc\" 3 #\\a)");
    try fx.expectErr(Error.TypeError, "(%set-aref \"abc\" 0 7)");
    try fx.expectErr(Error.TypeError, "(%set-elt \"abc\" 3 #\\a)");
}

test "length counts a string's characters" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(length \"abc\")", 3);
    try fx.expectFix("(length (make-string 7))", 7);
}

// --- comparison ---

test "string= compares character by character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(string= \"ab\" \"ab\")");
    try fx.expectNil("(string= \"ab\" \"aB\")");
    try fx.expectNil("(string= \"ab\" \"abc\")");
    try fx.expectT("(string= 'foo \"FOO\")");
    try fx.expectT("(string= #\\a \"a\")");
}

test "string= honors every bounding index" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(string= \"ab\" \"xabz\" :start2 1 :end2 3)");
    try fx.expectT("(string= \"xab\" \"ab\" :start1 1)");
    try fx.expectT("(string= \"abz\" \"ab\" :end1 2)");
    try fx.expectT("(string= \"ab\" \"abz\" :end2 2)");
    try fx.expectT("(string= \"ab\" \"ab\" :start1 nil :end1 nil :start2 nil :end2 nil)");
}

test "string= rejects a bad bounding index and a bad option list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(string= \"a\")");
    try fx.expectErr(Error.WrongArgCount, "(string= \"a\" \"a\" :start1)");
    try fx.expectErr(Error.ProgramError, "(string= \"a\" \"a\" :frob 0)");
    try fx.expectErr(Error.TypeError, "(string= \"a\" \"a\" :start1 5)");
    try fx.expectErr(Error.TypeError, "(string= \"a\" \"a\" :start1 -1)");
    try fx.expectErr(Error.TypeError, "(string= \"a\" \"a\" :end2 \"x\")");
    try fx.expectErr(Error.TypeError, "(string= \"ab\" \"ab\" :start1 2 :end1 1)");
    try fx.expectErr(Error.TypeError, "(string= \"ab\" \"ab\" :start2 2 :end2 1)");
}

test "string-equal ignores case" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(string-equal \"AbC\" \"aBc\")");
    try fx.expectNil("(string-equal \"abc\" \"abd\")");
    try fx.expectNil("(string-equal \"abc\" \"ab\")");
    try fx.expectT("(string-equal \"xabc\" \"ABC\" :start1 1)");
}

test "string< returns the index of the first mismatch, or nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(string< \"abc\" \"abd\")", 2);
    try fx.expectFix("(string< \"ab\" \"abc\")", 2);
    try fx.expectNil("(string< \"abc\" \"abc\")");
    try fx.expectNil("(string< \"abd\" \"abc\")");
    try fx.expectNil("(string< \"abc\" \"ab\")");
}

test "string< reports the mismatch as an index into the whole first string" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(string< \"xxabc\" \"abd\" :start1 2)", 4);
}

// --- case conversion ---

test "string-upcase and string-downcase return a fresh string" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-upcase \"aBc\")", "ABC");
    try fx.expectText("(string-downcase \"AbC\")", "abc");
    try fx.expectText("(string-upcase 'foo)", "FOO");
    try fx.expectText("(string-downcase #\\A)", "a");
}

test "string-capitalize uppercases the first character of each word" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-capitalize \"hello wide world\")", "Hello Wide World");
    try fx.expectText("(string-capitalize \"DON'T\")", "Don'T");
    try fx.expectText("(string-capitalize \"a1b c\")", "A1b C");
}

test "the case functions honor :start and :end" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-upcase \"abcd\" :start 1 :end 3)", "aBCd");
    try fx.expectText("(string-downcase \"ABCD\" :start 2)", "ABcd");
    try fx.expectText("(string-capitalize \"ab cd\" :end 2)", "Ab cd");
    try fx.expectText("(string-upcase \"ab\" :start nil :end nil)", "AB");
}

test "the case functions reject a bad region and a bad option list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(string-upcase)");
    try fx.expectErr(Error.WrongArgCount, "(string-upcase \"ab\" :start)");
    try fx.expectErr(Error.ProgramError, "(string-upcase \"ab\" :frob 1)");
    try fx.expectErr(Error.TypeError, "(string-upcase \"ab\" :start 2 :end 1)");
    try fx.expectErr(Error.TypeError, "(string-upcase \"ab\" :start 5)");
}

test "the n-variants rewrite their argument in place" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(let ((s (make-string 2 :initial-element #\\a))) (nstring-upcase s) s)", "AA");
    try fx.expectText("(let ((s (string-upcase \"ab\"))) (nstring-downcase s) s)", "ab");
    try fx.expectText("(let ((s (string \"ab cd\"))) (nstring-capitalize s) s)", "Ab Cd");
    try fx.expectErr(Error.TypeError, "(nstring-upcase 'foo)");
}

// --- trimming ---

test "string-trim removes bag characters from both ends" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-trim \" ab\" \"  abcba  \")", "c");
    try fx.expectText("(string-trim \"\" \"abc\")", "abc");
    try fx.expectText("(string-trim \"abc\" \"abc\")", "");
}

test "string-left-trim and string-right-trim work on one end each" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-left-trim \"x\" \"xxyx\")", "yx");
    try fx.expectText("(string-right-trim \"x\" \"xyxx\")", "xy");
}

test "the trim bag may be a list of character designators" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(string-trim (list #\\x #\\y) \"xyabyx\")", "ab");
    try fx.expectText("(string-trim '(\"x\") \"xax\")", "a");
    try fx.expectText("(string-trim nil \"xax\")", "xax");
}

test "trimming rejects a bad bag, a bad string and the wrong argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(string-trim \"x\")");
    try fx.expectErr(Error.TypeError, "(string-trim 7 \"abc\")");
    try fx.expectErr(Error.TypeError, "(string-trim '(#\\x . 7) \"xabc\")");
    try fx.expectErr(Error.TypeError, "(string-trim \"x\" 7)");
}

// --- concatenate ---

test "concatenate 'string joins strings and character sequences" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(concatenate 'string \"ab\" \"cd\")", "abcd");
    try fx.expectText("(concatenate 'string '(#\\a #\\b) \"c\")", "abc");
    try fx.expectText("(concatenate 'string)", "");
    try fx.expectText("(concatenate 'simple-string \"a\" nil)", "a");
}

test "concatenate builds lists and vectors too" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (concatenate 'list \"ab\" '(1)) '(#\\a #\\b 1))");
    try fx.expectFix("(length (concatenate 'vector \"a\" '(1 2)))", 3);
    try fx.expectNil("(concatenate 'list)");
    try fx.expectT("(equal (concatenate 'list (concatenate 'vector '(1 2))) '(1 2))");
}

test "concatenate rejects a bad result type, a bad sequence and a bad element" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(concatenate)");
    try fx.expectErr(Error.TypeError, "(concatenate 'fixnum \"a\")");
    try fx.expectErr(Error.TypeError, "(concatenate 7 \"a\")");
    try fx.expectErr(Error.TypeError, "(concatenate 'list 7)");
    try fx.expectErr(Error.TypeError, "(concatenate 'list '(1 . 2))");
    try fx.expectErr(Error.TypeError, "(concatenate 'string '(1))");
}
