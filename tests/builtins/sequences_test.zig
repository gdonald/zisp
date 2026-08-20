//! Sequence builtins across lists, vectors and strings: slicing, mapping,
//! reducing, searching, removal, substitution and sorting.

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

// --- copy-seq, subseq, reverse ---

test "copy-seq returns a sequence of the same kind" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (copy-seq '(1 2)) '(1 2))");
    try fx.expectText("(copy-seq \"abc\")", "abc");
    try fx.expectT("(equal (concatenate 'list (copy-seq #(1 2))) '(1 2))");
    try fx.expectNil("(copy-seq nil)");
    try fx.expectErr(Error.WrongArgCount, "(copy-seq)");
    try fx.expectErr(Error.TypeError, "(copy-seq 7)");
    try fx.expectErr(Error.TypeError, "(copy-seq '(1 . 2))");
}

test "subseq slices with an optional end" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(subseq \"abcdef\" 1 3)", "bc");
    try fx.expectT("(equal (subseq '(1 2 3 4) 2) '(3 4))");
    try fx.expectText("(subseq \"abc\" 1 nil)", "bc");
    try fx.expectText("(subseq \"abc\" 3)", "");
}

test "subseq rejects an out-of-range or inverted region" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(subseq \"abc\")");
    try fx.expectErr(Error.WrongArgCount, "(subseq \"abc\" 0 1 2)");
    try fx.expectErr(Error.TypeError, "(subseq \"abc\" 2 1)");
    try fx.expectErr(Error.TypeError, "(subseq \"abc\" 4)");
    try fx.expectErr(Error.TypeError, "(subseq \"abc\" -1)");
    try fx.expectErr(Error.TypeError, "(subseq \"abc\" 'x)");
}

test "reverse and nreverse work on every sequence kind" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (reverse '(1 2 3)) '(3 2 1))");
    try fx.expectText("(reverse \"abc\")", "cba");
    try fx.expectT("(equal (concatenate 'list (reverse #(1 2))) '(2 1))");
    try fx.expectT("(equal (nreverse (list 1 2)) '(2 1))");
    try fx.expectErr(Error.WrongArgCount, "(reverse)");
}

test "concatenate builds a string, a list or a vector" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(concatenate 'base-string \"ab\" \"c\")", "abc");
    try fx.expectT("(equal (concatenate 'null) nil)");
    try fx.expectT("(equal (concatenate 'list #(1) '(2)) '(1 2))");
    try fx.expectFix("(length (concatenate 'simple-array #(1) '(2)))", 2);
}

// --- map ---

test "map builds a result of the requested type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (map 'list #'1+ '(1 2 3)) '(2 3 4))");
    try fx.expectText("(map 'string #'identity \"abc\")", "abc");
    try fx.expectFix("(length (map 'vector #'1+ '(1 2)))", 2);
}

test "map with a nil result type returns nil but still calls the function" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(defvar *seen* nil)");
    try fx.expectNil("(map nil (lambda (x) (push x *seen*)) '(1 2))");
    try fx.expectT("(equal *seen* '(2 1))");
}

test "map stops at the shortest sequence" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (map 'list #'+ '(1 2 3) '(10 20)) '(11 22))");
    try fx.expectT("(equal (map 'list #'+ \"\" '(1)) nil)");
}

test "map needs a result type, a function and at least one sequence" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(map 'list)");
    try fx.expectErr(Error.WrongArgCount, "(map 'list #'1+)");
    try fx.expectErr(Error.TypeError, "(map 'fixnum #'1+ '(1))");
    try fx.expectErr(Error.TypeError, "(map 'list 7 '(1))");
}

test "map-into writes into an existing sequence and returns it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (map-into (list 0 0 0) #'1+ '(1 2)) '(2 3 0))");
    try fx.expectText("(map-into (make-string 3 :initial-element #\\z) #'identity \"ab\")", "abz");
    try fx.expectFix("(elt (map-into (concatenate 'vector '(0 0)) #'1+ '(5)) 0)", 6);
    try fx.expectT("(equal (map-into (list 1) #'1+ '(1 2 3)) '(2))");
}

test "map-into rejects a bad target and a bad argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(map-into (list 1))");
    try fx.expectErr(Error.TypeError, "(map-into 7 #'1+ '(1))");
    try fx.expectErr(Error.TypeError, "(map-into (make-string 1) #'1+ '(1))");
}

// --- reduce ---

test "reduce folds left by default and right with :from-end" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(reduce #'+ '(1 2 3 4))", 10);
    try fx.expectT("(equal (reduce #'cons '(1 2 3) :from-end t) '(1 2 . 3))");
    try fx.expectT("(equal (reduce #'list '(1 2 3)) '((1 2) 3))");
}

test "reduce honors :initial-value, :key and the bounding indices" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(reduce #'+ '(1 2 3) :initial-value 10)", 16);
    try fx.expectFix("(reduce #'+ '((1) (2)) :key #'car)", 3);
    try fx.expectFix("(reduce #'+ '(1 2 3 4) :start 1 :end 3)", 5);
    try fx.expectFix("(reduce #'+ nil :initial-value 7)", 7);
}

test "reduce over nothing calls the function with no arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(reduce #'+ nil)", 0);
    try fx.expectFix("(reduce #'+ '(5))", 5);
}

test "reduce checks its argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(reduce #'+)");
    try fx.expectErr(Error.WrongArgCount, "(reduce #'+ '(1) :key)");
}

// --- searching and counting ---

test "find and position locate an element" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(find 2 '(1 2 3))", 2);
    try fx.expectNil("(find 9 '(1 2 3))");
    try fx.expectFix("(position 3 '(1 2 3))", 2);
    try fx.expectFix("(position #\\c \"abc\")", 2);
    try fx.expectNil("(position 9 #(1 2))");
}

test "the -if and -if-not forms take a predicate" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(find-if #'evenp '(1 2 3))", 2);
    try fx.expectFix("(find-if-not #'evenp '(2 3))", 3);
    try fx.expectFix("(position-if #'evenp '(1 2))", 1);
    try fx.expectFix("(position-if-not #'evenp '(2 3))", 1);
}

test ":from-end searches backwards" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(position 1 '(1 2 1) :from-end t)", 2);
    try fx.expectFix("(position-if #'evenp '(2 4) :from-end t)", 1);
    try fx.expectFix("(find-if #'evenp '(2 4) :from-end t)", 4);
}

test "searching honors :key, :test and :test-not" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (find 1 '((1 a) (2 b)) :key #'car) '(1 a))");
    try fx.expectText("(find \"b\" '(\"a\" \"b\") :test #'equal)", "b");
    try fx.expectFix("(position 1 '(1 2) :test-not #'eql)", 1);
    try fx.expectT("(equal (find 1 '((1 a)) :key nil) nil)");
}

test "count tallies matches, with and without a predicate" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(count 1 '(1 2 1))", 2);
    try fx.expectFix("(count-if #'oddp '(1 2 3))", 2);
    try fx.expectFix("(count-if-not #'oddp '(1 2 3))", 1);
    try fx.expectFix("(count #\\a \"banana\")", 3);
    try fx.expectFix("(count 1 '(1 1 1) :start 1)", 2);
    try fx.expectFix("(count 1 '(1 1 1) :end 1)", 1);
}

test "eql is the default test, so numbers of the same value match" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(count 1.5 '(1.5 2.5))", 1);
    try fx.expectFix("(count 1/2 '(1/2 1/3))", 1);
    try fx.expectFix("(count 1.5 '(\"a\"))", 0);
    try fx.expectFix("(count 1.5d0 '(1.5d0))", 1);
}

test "the sequence keyword arguments are checked" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(count 1)");
    try fx.expectErr(Error.WrongArgCount, "(count 1 '(1) :key)");
    try fx.expectErr(Error.ProgramError, "(count 1 '(1) :frob 2)");
    try fx.expectErr(Error.ProgramError, "(count 1 '(1) :test #'eql :test-not #'eql)");
    try fx.expectErr(Error.ProgramError, "(count-if #'oddp '(1) :test #'eql)");
    try fx.expectErr(Error.TypeError, "(count 1 '(1) :start 5)");
    try fx.expectErr(Error.TypeError, "(count 1 '(1) :end 5)");
    try fx.expectErr(Error.TypeError, "(count 1 '(1 2) :start 2 :end 1)");
    try fx.expectErr(Error.TypeError, "(count 1 '(1) :key 7)");
    try fx.expectErr(Error.UnboundFunction, "(count 1 '(1) :key 'no-such-key)");
}

// --- removal and substitution ---

test "remove drops matching elements from any sequence kind" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (remove 1 '(1 2 1 3)) '(2 3))");
    try fx.expectText("(remove #\\a \"banana\")", "bnn");
    try fx.expectFix("(length (remove 1 #(1 2 1)))", 1);
}

test ":count limits how many are removed, from either end" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (remove 1 '(1 2 1 3) :count 1) '(2 1 3))");
    try fx.expectT("(equal (remove 1 '(1 2 1 3) :count 1 :from-end t) '(1 2 3))");
    try fx.expectT("(equal (remove 1 '(1 1) :count 0) '(1 1))");
    try fx.expectT("(equal (remove 1 '(1 1) :count nil) nil)");
}

test "remove-if and remove-if-not take a predicate" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (remove-if #'oddp '(1 2 3 4)) '(2 4))");
    try fx.expectT("(equal (remove-if-not #'oddp '(1 2 3 4)) '(1 3))");
}

test "delete is the destructive spelling of remove" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (delete 1 (list 1 2)) '(2))");
    try fx.expectT("(equal (delete-if #'oddp (list 1 2)) '(2))");
    try fx.expectT("(equal (delete-if-not #'oddp (list 1 2)) '(1))");
}

test "removal checks its argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(remove 1)");
    try fx.expectErr(Error.WrongArgCount, "(remove-if #'oddp)");
    try fx.expectErr(Error.TypeError, "(remove 1 '(1) :count 'x)");
}

test "substitute replaces matching elements" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (substitute 0 1 '(1 2 1)) '(0 2 0))");
    try fx.expectText("(nsubstitute #\\x #\\a \"banana\")", "bxnxnx");
    try fx.expectT("(equal (substitute 0 1 '(1 1) :count 1) '(0 1))");
    try fx.expectT("(equal (substitute 0 1 '((1) (2)) :key #'car) '(0 (2)))");
    try fx.expectErr(Error.WrongArgCount, "(substitute 0 1)");
}

// --- sorting ---

test "sort orders a sequence and keeps its kind" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (sort (list 3 1 2) #'<) '(1 2 3))");
    try fx.expectFix("(elt (sort (concatenate 'vector '(2 1)) #'<) 0)", 1);
    try fx.expectNil("(sort nil #'<)");
    try fx.expectT("(equal (sort (list 1) #'<) '(1))");
}

test "sort and merge honor :key" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (sort (list '(2 b) '(1 a)) #'< :key #'car) '((1 a) (2 b)))");
    try fx.expectT("(equal (merge 'list (list '(1 a)) (list '(2 b)) #'< :key #'car) '((1 a) (2 b)))");
}

test "merge interleaves two ordered sequences" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (merge 'list (list 1 3) (list 2 4) #'<) '(1 2 3 4))");
    try fx.expectT("(equal (merge 'list nil nil #'<) nil)");
    try fx.expectFix("(length (merge 'vector #(1) #(2) #'<))", 2);
}

test "sort and merge check their argument counts" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(sort (list 1))");
    try fx.expectErr(Error.WrongArgCount, "(merge 'list (list 1) (list 2))");
    try fx.expectErr(Error.ProgramError, "(sort (list 1) #'< :test #'<)");
}
