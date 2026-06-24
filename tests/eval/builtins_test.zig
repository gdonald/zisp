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
            .interner = symbol_mod.Interner.init(allocator),
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
        const form = (try rd.read()) orelse return error.NoForm;
        return self.ev.eval(form);
    }

    fn fix(self: *Fixture, src: []const u8) !i64 {
        const v = try self.evalStr(src);
        try testing.expect(v.isFixnum());
        return v.toFixnum();
    }

    fn expectFix(self: *Fixture, src: []const u8, expected: i64) !void {
        try testing.expectEqual(expected, try self.fix(src));
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectErr(self: *Fixture, err: anyerror, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

test "cons builds a pair" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(car (cons 1 2))", 1);
    try fx.expectFix("(cdr (cons 1 2))", 2);
    try fx.expectErr(Error.WrongArgCount, "(cons 1)");
}

test "car and cdr on nil and lists" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(car nil)");
    try fx.expectNil("(cdr nil)");
    try fx.expectFix("(car '(7 8))", 7);
    try fx.expectFix("(car (cdr '(7 8)))", 8);
    try fx.expectErr(Error.TypeError, "(car 5)");
    try fx.expectErr(Error.TypeError, "(cdr 5)");
    try fx.expectErr(Error.WrongArgCount, "(car)");
    try fx.expectErr(Error.WrongArgCount, "(cdr)");
}

test "compound cxr accessors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(cadr '(1 2 3))", 2);
    try fx.expectFix("(caddr '(1 2 3))", 3);
    try fx.expectT("(equal (cddddr '(1 2 3 4 5)) '(5))");
    try fx.expectFix("(caar '((9 8) 7))", 9);
    try fx.expectErr(Error.TypeError, "(caar '(1 2))");
    try fx.expectErr(Error.WrongArgCount, "(caar)");
}

test "ordinal accessors and nth" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(first '(10 20 30))", 10);
    try fx.expectFix("(third '(10 20 30))", 30);
    try fx.expectFix("(tenth '(1 2 3 4 5 6 7 8 9 10))", 10);
    try fx.expectNil("(first '())");
    try fx.expectNil("(third '(1))");
    try fx.expectErr(Error.TypeError, "(second '(1 . 2))");
    try fx.expectFix("(nth 1 '(10 20 30))", 20);
    try fx.expectNil("(nth 9 '(10 20))");
    try fx.expectErr(Error.TypeError, "(nth 1 5)");
    try fx.expectErr(Error.TypeError, "(nth 'a '(1))");
    try fx.expectErr(Error.TypeError, "(nth -1 '(1))");
    try fx.expectErr(Error.WrongArgCount, "(first)");
}

test "nthcdr walks the list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(car (nthcdr 2 '(1 2 3 4)))", 3);
    try fx.expectNil("(nthcdr 9 '(1 2))");
    try fx.expectErr(Error.TypeError, "(nthcdr 2 '(1 . 2))");
    try fx.expectErr(Error.TypeError, "(nthcdr 'a '(1))");
    try fx.expectErr(Error.TypeError, "(nthcdr -1 '(1))");
    try fx.expectErr(Error.WrongArgCount, "(nthcdr 1)");
}

test "list and list*" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (list 1 2 3) '(1 2 3))");
    try fx.expectNil("(list)");
    try fx.expectT("(equal (list* 1 2 '(3 4)) '(1 2 3 4))");
    try fx.expectFix("(list* 5)", 5);
    try fx.expectErr(Error.WrongArgCount, "(list*)");
}

test "append, reverse, nreverse, length" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(append)");
    try fx.expectFix("(append 5)", 5);
    try fx.expectT("(equal (append '(1 2) '(3 4) '(5)) '(1 2 3 4 5))");
    try fx.expectErr(Error.TypeError, "(append '(1 . 2) '(3))");
    try fx.expectT("(equal (reverse '(1 2 3)) '(3 2 1))");
    try fx.expectErr(Error.TypeError, "(reverse '(1 . 2))");
    try fx.expectErr(Error.WrongArgCount, "(reverse)");
    try fx.expectT("(equal (nreverse (list 1 2 3)) '(3 2 1))");
    try fx.expectErr(Error.TypeError, "(nreverse '(1 . 2))");
    try fx.expectErr(Error.WrongArgCount, "(nreverse)");
    try fx.expectFix("(length '(1 2 3))", 3);
    try fx.expectFix("(length \"hello\")", 5);
    try fx.expectFix("(length #(1 2 3 4))", 4);
    try fx.expectErr(Error.TypeError, "(length '(1 . 2))");
    try fx.expectErr(Error.TypeError, "(length 1.5)");
    try fx.expectErr(Error.TypeError, "(length 5)");
    try fx.expectErr(Error.WrongArgCount, "(length)");
}

test "eq" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(eq 'a 'a)");
    try fx.expectNil("(eq 'a 'b)");
    try fx.expectT("(eq 3 3)");
    try fx.expectErr(Error.WrongArgCount, "(eq 1)");
}

test "eql" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(eql 'a 'a)");
    try fx.expectT("(eql 3 3)");
    try fx.expectNil("(eql 1 2)");
    try fx.expectT("(eql 1.5 1.5)");
    try fx.expectT("(eql 1.0d0 1.0d0)");
    try fx.expectT("(eql 1/2 1/2)");
    try fx.expectNil("(eql 1.5 1/2)");
    try fx.expectNil("(eql \"a\" \"a\")");
    try fx.expectErr(Error.WrongArgCount, "(eql 1)");
}

test "equal" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal '(1 (2 3)) '(1 (2 3)))");
    try fx.expectT("(equal \"ab\" \"ab\")");
    try fx.expectNil("(equal \"ab\" \"ac\")");
    try fx.expectNil("(equal 'a 1)");
    try fx.expectErr(Error.WrongArgCount, "(equal 1)");
}

test "equalp" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equalp 2 2)");
    try fx.expectT("(equalp 2 2.0)");
    try fx.expectT("(equalp 1/2 0.5)");
    try fx.expectT("(equalp 2 2.0d0)");
    try fx.expectNil("(equalp 2 3.0)");
    try fx.expectT("(equalp #\\a #\\A)");
    try fx.expectT("(equalp #\\U+00FF #\\U+00FF)");
    try fx.expectNil("(equalp \"abc\" \"abx\")");
    try fx.expectT("(equalp '(1 2) '(1 2))");
    try fx.expectT("(equalp \"AbC\" \"abc\")");
    try fx.expectNil("(equalp \"ab\" \"abc\")");
    try fx.expectT("(equalp #(1 2 3) #(1 2 3))");
    try fx.expectNil("(equalp #(1 2) #(1 3))");
    try fx.expectNil("(equalp #(1) #(1 2))");
    try fx.expectNil("(equalp \"a\" #(1))");
    try fx.expectT("(equalp 'a 'a)");
    try fx.expectNil("(equalp 'a 'b)");
    try fx.expectErr(Error.WrongArgCount, "(equalp 1)");
}

test "type predicates" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(atom 'a)");
    try fx.expectT("(atom nil)");
    try fx.expectNil("(atom '(1))");
    try fx.expectT("(consp '(1))");
    try fx.expectNil("(consp nil)");
    try fx.expectT("(listp nil)");
    try fx.expectT("(listp '(1))");
    try fx.expectNil("(listp 5)");
    try fx.expectT("(null nil)");
    try fx.expectNil("(null 5)");
    try fx.expectT("(endp nil)");
    try fx.expectNil("(endp '(1))");
    try fx.expectErr(Error.TypeError, "(endp 5)");
    try fx.expectT("(symbolp 'a)");
    try fx.expectNil("(symbolp 5)");
    try fx.expectT("(numberp 5)");
    try fx.expectT("(numberp 1.5)");
    try fx.expectNil("(numberp \"a\")");
    try fx.expectNil("(numberp 'a)");
    try fx.expectT("(integerp 5)");
    try fx.expectNil("(integerp 1.5)");
    try fx.expectT("(stringp \"a\")");
    try fx.expectNil("(stringp 5)");
    try fx.expectErr(Error.WrongArgCount, "(atom)");
    try fx.expectErr(Error.WrongArgCount, "(consp)");
    try fx.expectErr(Error.WrongArgCount, "(listp)");
    try fx.expectErr(Error.WrongArgCount, "(null)");
    try fx.expectErr(Error.WrongArgCount, "(endp)");
    try fx.expectErr(Error.WrongArgCount, "(symbolp)");
    try fx.expectErr(Error.WrongArgCount, "(numberp)");
    try fx.expectErr(Error.WrongArgCount, "(integerp)");
    try fx.expectErr(Error.WrongArgCount, "(stringp)");
}

test "addition and subtraction" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(+)", 0);
    try fx.expectFix("(+ 1 2 3)", 6);
    try fx.expectErr(Error.TypeError, "(+ 1 'a)");
    try fx.expectFix("(- 5)", -5);
    try fx.expectFix("(- 10 3 2)", 5);
    try fx.expectErr(Error.WrongArgCount, "(-)");
}

test "multiplication and division" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(*)", 1);
    try fx.expectFix("(* 2 3 4)", 24);
    try fx.expectFix("(/ 6 3)", 2);
    try fx.expectFix("(/ 0 5)", 0);
    try fx.expectT("(equal (/ 1 2) 1/2)");
    try fx.expectT("(equal (/ 1 -2) -1/2)");
    try fx.expectT("(equal (/ 5) 1/5)");
    try fx.expectErr(Error.DivisionByZero, "(/ 5 0)");
    try fx.expectErr(Error.DivisionByZero, "(/ 0)");
    try fx.expectErr(Error.WrongArgCount, "(/)");
}

test "mod and rem" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(mod 13 4)", 1);
    try fx.expectFix("(mod -13 4)", 3);
    try fx.expectFix("(rem -13 4)", -1);
    try fx.expectErr(Error.DivisionByZero, "(mod 1 0)");
    try fx.expectErr(Error.DivisionByZero, "(rem 1 0)");
    try fx.expectErr(Error.WrongArgCount, "(mod 1)");
    try fx.expectErr(Error.WrongArgCount, "(rem 1)");
}

test "1+ 1- abs min max" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(1+ 4)", 5);
    try fx.expectFix("(1- 4)", 3);
    try fx.expectFix("(abs -7)", 7);
    try fx.expectFix("(abs 7)", 7);
    try fx.expectFix("(min 3 1 2)", 1);
    try fx.expectFix("(max 3 1 2)", 3);
    try fx.expectErr(Error.WrongArgCount, "(1+)");
    try fx.expectErr(Error.WrongArgCount, "(1-)");
    try fx.expectErr(Error.WrongArgCount, "(abs)");
    try fx.expectErr(Error.WrongArgCount, "(min)");
    try fx.expectErr(Error.WrongArgCount, "(max)");
}

test "numeric comparisons" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(= 1 1 1)");
    try fx.expectNil("(= 1 2)");
    try fx.expectT("(/= 1 2 3)");
    try fx.expectNil("(/= 1 2 1)");
    try fx.expectT("(< 1 2 3)");
    try fx.expectNil("(< 1 3 2)");
    try fx.expectT("(> 3 2 1)");
    try fx.expectT("(<= 1 1 2)");
    try fx.expectT("(>= 3 3 1)");
    try fx.expectErr(Error.TypeError, "(< 1 'a)");
    try fx.expectErr(Error.WrongArgCount, "(<)");
    try fx.expectErr(Error.WrongArgCount, "(/=)");
}

test "sign predicates" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(zerop 0)");
    try fx.expectNil("(zerop 1)");
    try fx.expectT("(plusp 1)");
    try fx.expectNil("(plusp 0)");
    try fx.expectT("(minusp -1)");
    try fx.expectNil("(minusp 0)");
    try fx.expectT("(oddp 3)");
    try fx.expectNil("(oddp 4)");
    try fx.expectT("(evenp 4)");
    try fx.expectNil("(evenp 3)");
    try fx.expectErr(Error.WrongArgCount, "(zerop)");
    try fx.expectErr(Error.WrongArgCount, "(oddp)");
    try fx.expectErr(Error.WrongArgCount, "(evenp)");
    try fx.expectErr(Error.TypeError, "(zerop 'a)");
}

test "not" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(not nil)");
    try fx.expectNil("(not 5)");
    try fx.expectErr(Error.WrongArgCount, "(not)");
}

test "funcall" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(funcall #'+ 1 2 3)", 6);
    try fx.expectFix("(funcall '+ 1 2)", 3);
    try fx.expectFix("(funcall (lambda (x y) (+ x y)) 4 5)", 9);
    try fx.expectErr(Error.TypeError, "(funcall 5)");
    try fx.expectErr(Error.UnboundFunction, "(funcall 'no-such-fn 1)");
    try fx.expectErr(Error.WrongArgCount, "(funcall)");
}

test "apply" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(apply #'+ '(1 2 3))", 6);
    try fx.expectFix("(apply #'+ 1 2 '(3 4))", 10);
    try fx.expectErr(Error.TypeError, "(apply #'+ 5)");
    try fx.expectErr(Error.WrongArgCount, "(apply #'+)");
}

test "mapcar mapc mapcan" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (mapcar #'1+ '(1 2 3)) '(2 3 4))");
    try fx.expectT("(equal (mapcar #'+ '(1 2 3) '(10 20 30)) '(11 22 33))");
    try fx.expectT("(equal (mapcar #'+ '(1 2) '(10 20 30)) '(11 22))");
    try fx.expectT("(equal (mapc #'1+ '(1 2 3)) '(1 2 3))");
    try fx.expectT("(equal (mapcan (lambda (x) (list x x)) '(1 2)) '(1 1 2 2))");
    try fx.expectT("(equal (mapcan (lambda (x) (if (oddp x) (list x) nil)) '(1 2 3)) '(1 3))");
    try fx.expectErr(Error.WrongArgCount, "(mapcar #'1+)");
}

test "and special form" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(and)");
    try fx.expectFix("(and 1 2 3)", 3);
    try fx.expectNil("(and 1 nil 3)");
    try fx.expectErr(Error.BadArgList, "(and 1 . 2)");
}

test "or special form" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(or)");
    try fx.expectFix("(or nil 2 3)", 2);
    try fx.expectNil("(or nil nil)");
    try fx.expectErr(Error.BadArgList, "(or nil . 2)");
}

test "when and unless" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(when t 1 2)", 2);
    try fx.expectNil("(when nil 1)");
    try fx.expectFix("(unless nil 1 2)", 2);
    try fx.expectNil("(unless t 1)");
    try fx.expectErr(Error.BadArgList, "(when)");
    try fx.expectErr(Error.BadArgList, "(unless)");
}

test "cond" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(cond (nil 1) (t 2))", 2);
    try fx.expectFix("(cond (5))", 5);
    try fx.expectNil("(cond (nil 1))");
    try fx.expectFix("(cond ((= 1 1) 10 20))", 20);
    try fx.expectErr(Error.TypeError, "(cond 5)");
    try fx.expectErr(Error.BadArgList, "(cond (nil 1) . 5)");
}
