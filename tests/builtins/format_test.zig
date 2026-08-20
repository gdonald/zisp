//! Format directives: parameter parsing, the `:` and `@` modifiers, and
//! each directive's padding and column behavior.

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
    aw: std.Io.Writer.Allocating,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
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

    /// Run a `format nil` call and compare the string it returns.
    fn expectFormat(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.evalStr(src);
        try testing.expect(heap_mod.isString(v));
        const text = try heap_mod.stringUtf8Alloc(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    fn expectErr(self: *Fixture, err: Error, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }

    fn console(self: *Fixture) []const u8 {
        return self.aw.written();
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- ~A and ~S ---

test "tilde A pads on the right and tilde at-A pads on the left" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~10A|\" \"ab\")", "ab        |");
    try fx.expectFormat("(format nil \"~10@A|\" \"ab\")", "        ab|");
    try fx.expectFormat("(format nil \"~2A\" \"abcd\")", "abcd");
}

test "tilde A honors colinc, minpad and a pad character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~6,4A|\" \"ab\")", "ab    |");
    try fx.expectFormat("(format nil \"~0,1,3A|\" \"ab\")", "ab   |");
    try fx.expectFormat("(format nil \"~6,1,0,'.A|\" \"ab\")", "ab....|");
    try fx.expectFormat("(format nil \"~6,0A|\" \"ab\")", "ab    |");
}

test "tilde S prints readably where tilde A does not" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~S\" \"ab\")", "\"ab\"");
    try fx.expectFormat("(format nil \"~A\" \"ab\")", "ab");
}

// --- ~D ---

test "tilde D right-aligns in mincol with a chosen pad character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~5D|\" 42)", "   42|");
    try fx.expectFormat("(format nil \"~5,'0D\" 42)", "00042");
    try fx.expectFormat("(format nil \"~2D\" 12345)", "12345");
}

test "tilde D prints a sign for negatives and on request" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~D\" -42)", "-42");
    try fx.expectFormat("(format nil \"~@D\" 42)", "+42");
    try fx.expectFormat("(format nil \"~@D\" -42)", "-42");
}

test "tilde colon D groups digits" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~:D\" 1234567)", "1,234,567");
    try fx.expectFormat("(format nil \"~,,'_,4:D\" 12345678)", "1234_5678");
    try fx.expectFormat("(format nil \"~,,',,0:D\" 123)", "1,2,3");
}

test "tilde D on a non-integer falls back to the printer" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~D\" 'ab)", "AB");
    try fx.expectFormat("(format nil \"~5,'.D\" 'ab)", "...AB");
}

// --- newline directives ---

test "tilde percent writes newlines and tilde tilde writes tildes" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~3%\")", "\n\n\n");
    try fx.expectFormat("(format nil \"~2~\")", "~~");
    try fx.expectFormat("(format nil \"~0%\")", "");
}

test "tilde ampersand only breaks a line that has content on it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"ab~&cd\")", "ab\ncd");
    try fx.expectFormat("(format nil \"~&cd\")", "cd");
    try fx.expectFormat("(format nil \"ab~2&cd\")", "ab\n\ncd");
    try fx.expectFormat("(format nil \"ab~0&cd\")", "abcd");
}

test "the console column carries across separate format calls" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"ab\")");
    _ = try fx.evalStr("(format t \"~&cd\")");
    _ = try fx.evalStr("(format t \"~&ef\")");
    try testing.expectEqualStrings("ab\ncd\nef", fx.console());
}

// --- argument movement ---

test "tilde star skips, backs up, and jumps to an absolute argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~*~A\" 1 2)", "2");
    try fx.expectFormat("(format nil \"~2*~A\" 1 2 3)", "3");
    try fx.expectFormat("(format nil \"~A~:*~A\" 7)", "77");
    try fx.expectFormat("(format nil \"~A~A~@*~A\" 1 2)", "121");
    try fx.expectFormat("(format nil \"~A~1@*~A\" 1 2)", "12");
}

test "moving past either end of the argument list is an error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.ProgramError, "(format nil \"~2*\" 1)");
    try fx.expectErr(Error.ProgramError, "(format nil \"~:*\")");
    try fx.expectErr(Error.ProgramError, "(format nil \"~5@*\" 1)");
    try fx.expectErr(Error.ProgramError, "(format nil \"~A\")");
}

// --- ~T ---

test "tilde T pads out to a column" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"ab~10Tc\")", "ab        c");
    try fx.expectFormat("(format nil \"~Tx\")", " x");
}

test "tilde T past its column steps forward by colinc" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"abcde~2,4Tx\")", "abcde x");
    try fx.expectFormat("(format nil \"abc~2,0Tx\")", "abc x");
}

// --- parameters ---

test "a v parameter takes its value from the argument list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~vD\" 5 42)", "   42");
    try fx.expectFormat("(format nil \"~v,vD\" 6 #\\. 42)", "....42");
    try fx.expectFormat("(format nil \"~vD\" nil 42)", "42");
    try fx.expectErr(Error.TypeError, "(format nil \"~vD\" \"x\" 42)");
}

test "a quoted character parameter and a hash parameter" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~5,'*D\" 42)", "***42");
    try fx.expectFormat("(format nil \"~#D\" 7)", "7");
    try fx.expectFormat("(format nil \"~#%\" 1 2)", "\n\n");
}

test "a signed parameter is accepted" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~+5D|\" 42)", "   42|");
    try fx.expectErr(Error.ProgramError, "(format nil \"~-1%\")");
}

test "a malformed directive is a program error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.ProgramError, "(format nil \"ab~\")");
    try fx.expectErr(Error.ProgramError, "(format nil \"~1,2,3,4,5D\" 1)");
    try fx.expectErr(Error.ProgramError, "(format nil \"~Q\")");
    try fx.expectErr(Error.ProgramError, "(format nil \"~'\")");
    try fx.expectErr(Error.ProgramError, "(format nil \"~+D\" 1)");
}

// --- ~[ conditional ---

test "tilde bracket selects a clause by index" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~[zero~;one~;two~]\" 1)", "one");
    try fx.expectFormat("(format nil \"~[zero~;one~]\" 0)", "zero");
    try fx.expectFormat("(format nil \"~3[a~;b~]\")", "");
    try fx.expectFormat("(format nil \"~v[a~;b~]\" 1)", "b");
    try fx.expectFormat("(format nil \"~#[none~;one~:;many~]\" 1 2)", "many");
}

test "a tilde colon semicolon clause is the fallback" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~[zero~;one~:;many~]\" 7)", "many");
    try fx.expectFormat("(format nil \"~[zero~;one~:;many~]\" 0)", "zero");
}

test "tilde colon bracket chooses between a false and a true clause" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~:[no~;yes~]\" nil)", "no");
    try fx.expectFormat("(format nil \"~:[no~;yes~]\" t)", "yes");
}

test "tilde at bracket runs its clause only for a true argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~@[x=~A ~]done\" 5)", "x=5 done");
    try fx.expectFormat("(format nil \"~@[x=~A ~]done\" nil)", "done");
}

test "a malformed conditional is a program error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.ProgramError, "(format nil \"~:[a~]\" nil)");
    try fx.expectErr(Error.ProgramError, "(format nil \"~@[a~;b~]\" 1)");
    try fx.expectErr(Error.ProgramError, "(format nil \"~@[a~]\")");
    try fx.expectErr(Error.ProgramError, "(format nil \"~[a~;b\" 0)");
    try fx.expectErr(Error.TypeError, "(format nil \"~[a~;b~]\" 'x)");
}

// --- ~{ iteration ---

test "tilde brace repeats its body over a list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~{~A,~}\" '(1 2 3))", "1,2,3,");
    try fx.expectFormat("(format nil \"~{~A~}\" nil)", "");
    try fx.expectFormat("(format nil \"~2{~A~}\" '(1 2 3))", "12");
    try fx.expectFormat("(format nil \"~0{~A~}\" '(1))", "");
}

test "tilde at brace iterates over the remaining format arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~@{~A~^,~}\" 1 2 3)", "1,2,3");
    try fx.expectFormat("(format nil \"~A:~@{~A~}\" 1 2 3)", "1:23");
}

test "tilde colon brace gives each sublist to one pass" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~:{~A-~A ~}\" '((1 2) (3 4)))", "1-2 3-4 ");
    try fx.expectFormat("(format nil \"~:{~A~^-~A~}\" '((1 2) (3)))", "1-23");
}

test "an empty iteration body takes its control string from an argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~{~}\" \"~A.\" '(1 2))", "1.2.");
    try fx.expectErr(Error.TypeError, "(format nil \"~{~}\" 7 '(1))");
}

test "an unterminated or improper iteration is an error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.ProgramError, "(format nil \"~{~A\" '(1))");
    try fx.expectErr(Error.TypeError, "(format nil \"~{~A~}\" '(1 . 2))");
}

// --- ~^ ---

test "tilde circumflex leaves the clause when the arguments run out" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~{~A~^,~}\" '(1 2 3))", "1,2,3");
    try fx.expectFormat("(format nil \"~2{~A~^,~}\" '(1 2 3))", "1,2,");
}

test "tilde circumflex compares its parameters instead when given any" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~0^gone\")", "");
    try fx.expectFormat("(format nil \"~1^kept\")", "kept");
    try fx.expectFormat("(format nil \"~2,2^gone\")", "");
    try fx.expectFormat("(format nil \"~2,3^kept\")", "kept");
    try fx.expectFormat("(format nil \"~1,2,3^gone\")", "");
    try fx.expectFormat("(format nil \"~3,2,1^kept\")", "kept");
}

test "tilde colon circumflex ends the whole iteration" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~:{~A~:^ ~}\" '((1) (2)))", "1");
}

// --- ~? and ~/ ---

test "tilde question mark runs a control string from the arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFormat("(format nil \"~? and ~A\" \"~A+~A\" '(1 2) 9)", "1+2 and 9");
    try fx.expectFormat("(format nil \"~@?+~A\" \"~A\" 1 2)", "1+2");
    try fx.expectErr(Error.TypeError, "(format nil \"~?\" 7 '(1))");
    try fx.expectErr(Error.TypeError, "(format nil \"~?\" \"~A\" '(1 . 2))");
}

test "tilde slash calls a named function with the stream and modifiers" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(
        \\(defun shout (stream arg colonp atp)
        \\  (format stream "<~A~A~A>" arg (if colonp ":" "") (if atp "@" "")))
    );
    try fx.expectFormat("(format nil \"a~/shout/b\" 7)", "a<7>b");
    try fx.expectFormat("(format nil \"~:@/shout/\" 1)", "<1:@>");
    try fx.expectFormat("(format nil \"~/cl-user:shout/\" 2)", "<2>");
}

test "tilde slash passes its parameters after the modifiers" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(
        \\(defun widths (stream arg colonp atp &rest params)
        \\  (format stream "~A~A" arg params))
    );
    try fx.expectFormat("(format nil \"~5,6/widths/\" 1)", "1(5 6)");
}

test "tilde slash on an unknown or unbound name is an error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.UnboundFunction, "(format nil \"~/never-heard-of-it/\" 1)");
    _ = try fx.evalStr("(defvar not-a-function 1)");
    try fx.expectErr(Error.UnboundFunction, "(format nil \"~/not-a-function/\" 1)");
    try fx.expectErr(Error.ProgramError, "(format nil \"~/unterminated\" 1)");
}
