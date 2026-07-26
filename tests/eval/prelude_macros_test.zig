//! Prelude macros: when/unless/cond/and/or as real macros, prog1/prog2,
//! the case and typecase families, and the error / typep builtins that
//! back them.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
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

    fn expectFix(self: *Fixture, src: []const u8, expected: i64) !void {
        const v = try self.evalStr(src);
        try testing.expectEqual(expected, v.toFixnum());
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectSym(self: *Fixture, src: []const u8, name: []const u8) !void {
        const v = try self.evalStr(src);
        try testing.expect(v.equalsRaw(try self.interner.internCurrent(name)));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

test "when unless cond and or are macros, not special forms" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    // macroexpand-1 leaves special forms alone, so a T second value proves
    // each of these is a macro definition.
    for ([_][]const u8{
        "(macroexpand-1 '(when a b))",
        "(macroexpand-1 '(unless a b))",
        "(macroexpand-1 '(cond (a b)))",
        "(macroexpand-1 '(and a b))",
        "(macroexpand-1 '(or a b))",
    }) |src| {
        _ = try fx.evalStr(src);
        try testing.expectEqual(@as(usize, 2), fx.ev.values.items.len);
        try testing.expect(fx.ev.values.items[1].equalsRaw(value.T));
    }
}

test "when and unless expand into if" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(equal (macroexpand-1 '(when c a b)) '(if c (progn a b) nil))");
    try fx.expectT("(equal (macroexpand-1 '(unless c a b)) '(if c nil (progn a b)))");
}

test "or returns the first non-nil value exactly once" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    // The value is bound to a temporary, so the producing form runs once.
    try fx.expectFix(
        \\(progn (setq counter 0)
        \\       (or (progn (setq counter (+ counter 1)) 7) 9)
        \\       counter)
    , 1);
}

test "and and or preserve multiple values of the last form" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(equal (multiple-value-list (and 1 (values 2 3))) '(2 3))");
    try fx.expectT("(equal (multiple-value-list (or nil (values 4 5))) '(4 5))");
}

test "cond clause with no body returns the test value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(cond (nil 1) (5))", 5);
}

test "prog1 returns the first form's value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(prog1 1 2 3)", 1);
    try fx.expectFix(
        \\(progn (setq side 0)
        \\       (prog1 (setq side (+ side 10)) (setq side (+ side 1)))
        \\       side)
    , 11);
}

test "prog2 returns the second form's value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(prog2 1 2 3)", 2);
}

test "case matches single keys, key lists, and otherwise" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectSym("(case 2 (1 'one) (2 'two) (otherwise 'many))", "TWO");
    try fx.expectSym("(case 5 (1 'one) (2 'two) (otherwise 'many))", "MANY");
    try fx.expectSym("(case 3 ((1 2) 'low) ((3 4) 'mid) (t 'high))", "MID");
    try fx.expectSym("(case 'b ((a b c) 'letter) (otherwise 'other))", "LETTER");
}

test "case with no matching clause returns nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectNil("(case 9 (1 'one) (2 'two))");
}

test "case evaluates the keyform once and does not evaluate keys" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix(
        \\(progn (setq n 0)
        \\       (case (progn (setq n (+ n 1)) 2) (1 10) (2 20) (3 30))
        \\       n)
    , 1);
    // Keys are literal objects: the symbol n, not its value.
    try fx.expectSym("(case 'n (n 'matched) (otherwise 'no))", "MATCHED");
}

test "case nil key list never matches" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectNil("(case nil (nil 'no) (otherwise nil))");
}

test "ecase returns the match and errors on fall-through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectSym("(ecase 2 (1 'one) (2 'two))", "TWO");
    try testing.expectError(Error.ProgramError, fx.evalStr("(ecase 9 (1 'one) (2 'two))"));
}

test "ccase returns the match and errors on fall-through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectSym("(ccase 1 (1 'one) (2 'two))", "ONE");
    try testing.expectError(Error.ProgramError, fx.evalStr("(ccase 9 (1 'one))"));
}

test "typecase dispatches on runtime type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectSym("(typecase 5 (symbol 'sym) (integer 'int) (t 'other))", "INT");
    try fx.expectSym("(typecase 'a (symbol 'sym) (integer 'int) (t 'other))", "SYM");
    try fx.expectSym("(typecase \"s\" (string 'str) (otherwise 'other))", "STR");
    try fx.expectSym("(typecase '(1) (null 'empty) (cons 'pair))", "PAIR");
    try fx.expectNil("(typecase 5 (symbol 'sym))");
}

test "etypecase and ctypecase error on fall-through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectSym("(etypecase 5 (integer 'int))", "INT");
    try testing.expectError(Error.ProgramError, fx.evalStr("(etypecase 'a (integer 'int))"));
    try fx.expectSym("(ctypecase 'a (symbol 'sym))", "SYM");
    try testing.expectError(Error.ProgramError, fx.evalStr("(ctypecase 5 (symbol 'sym))"));
}

test "typep covers the runtime's atomic types" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(typep 5 'integer)");
    try fx.expectT("(typep 5 'number)");
    try fx.expectT("(typep 5 'atom)");
    try fx.expectNil("(typep 5 'symbol)");
    try fx.expectT("(typep 'a 'symbol)");
    try fx.expectT("(typep :k 'keyword)");
    try fx.expectNil("(typep 'a 'keyword)");
    try fx.expectT("(typep nil 'null)");
    try fx.expectT("(typep nil 'list)");
    try fx.expectT("(typep nil 'boolean)");
    try fx.expectT("(typep t 'boolean)");
    try fx.expectNil("(typep 5 'boolean)");
    try fx.expectT("(typep '(1) 'cons)");
    try fx.expectT("(typep '(1) 'list)");
    try fx.expectNil("(typep '(1) 'atom)");
    try fx.expectT("(typep \"s\" 'string)");
    try fx.expectT("(typep #\\a 'character)");
    try fx.expectT("(typep (function car) 'function)");
    try fx.expectT("(typep 5 't)");
    try fx.expectNil("(typep 5 'nil)");
}

test "typep rejects unknown and compound type specifiers" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.ProgramError, fx.evalStr("(typep 5 'flonk)"));
    try testing.expectError(Error.ProgramError, fx.evalStr("(typep 5 '(integer 0 10))"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(typep 5)"));
}

test "error signals from lisp code" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.ProgramError, fx.evalStr("(error \"boom\")"));
    try testing.expectError(Error.ProgramError, fx.evalStr("(error \"~s is bad\" 5)"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(error)"));
}
