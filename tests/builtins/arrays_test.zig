//! Array builtins: construction options, subscript access, introspection,
//! the fill-pointer operations, and adjustment.

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

// --- construction ---

test "vector builds a simple vector of its arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (concatenate 'list (vector 1 2)) '(1 2))");
    try fx.expectFix("(length (vector))", 0);
    try fx.expectT("(simple-vector-p (vector 1))");
}

test "make-array takes a size or a dimension list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(array-total-size (make-array 3))", 3);
    try fx.expectFix("(array-total-size (make-array '(2 3)))", 6);
    try fx.expectFix("(array-rank (make-array '()))", 0);
    try fx.expectFix("(array-total-size (make-array '()))", 1);
}

test "make-array rejects a malformed dimension specifier" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(make-array)");
    try fx.expectErr(Error.TypeError, "(make-array -1)");
    try fx.expectErr(Error.TypeError, "(make-array '(2 . 3))");
    try fx.expectErr(Error.TypeError, "(make-array '(-1))");
    try fx.expectErr(Error.TypeError, "(make-array \"x\")");
}

test "make-array rejects a malformed option list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(make-array 1 :adjustable)");
    try fx.expectErr(Error.ProgramError, "(make-array 1 :frobnicate t)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :displaced-to (make-array 1) :displaced-index-offset -1)");
}

test "an unrecognized element type falls back to T" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(eq (array-element-type (make-array 1 :element-type 'fixnum)) t)");
    try fx.expectT("(eq (array-element-type (make-array 1 :element-type '(signed-byte 8))) t)");
    try fx.expectT("(eq (array-element-type (make-array 1 :element-type 7)) t)");
    try fx.expectT("(eq (array-element-type (make-array 1 :element-type t)) t)");
    try fx.expectT("(eq (array-element-type (make-array 1 :element-type '(unsigned-byte))) t)");
}

test "an unsigned-byte 1 element type is a bit array" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(bit-vector-p (make-array 1 :element-type '(unsigned-byte 1)))");
}

test "a multi-dimensional character array is not a string" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(stringp (make-array '(2 2) :element-type 'character))");
    try fx.expectT("(eq (array-element-type (make-array '(2 2) :element-type 'character)) 'character)");
    try fx.expectT("(typep (aref (make-array '(2 2) :element-type 'character) 0 0) 'character)");
}

test ":initial-element is checked against the element type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type 'bit :initial-element 2)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type 'bit :initial-element 'x)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type '(unsigned-byte 8) :initial-element 300)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type '(unsigned-byte 8) :initial-element 'x)");
    try fx.expectErr(Error.TypeError, "(make-array '(1 1) :element-type 'character :initial-element 7)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type 'character :initial-element 7)");
}

test ":initial-contents reads from any sequence kind" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(equal (concatenate 'list (make-array 2 :initial-contents '(1 2))) '(1 2))");
    try fx.expectT("(equal (concatenate 'list (make-array 2 :initial-contents #(1 2))) '(1 2))");
    try fx.expectT("(equal (concatenate 'list (make-array 2 :initial-contents \"ab\")) '(#\\a #\\b))");
    try fx.expectText("(make-array 2 :element-type 'character :initial-contents \"ab\")", "ab");
}

test ":initial-contents must match the dimensions" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(make-array 3 :initial-contents '(1 2))");
    try fx.expectErr(Error.TypeError, "(make-array '(2 2) :initial-contents '((1 2) (3)))");
    try fx.expectErr(Error.TypeError, "(make-array 2 :initial-contents '(1 . 2))");
    try fx.expectErr(Error.TypeError, "(make-array 2 :initial-contents 7)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type 'character :initial-contents '(7))");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type 'bit :initial-contents '(2))");
}

test "an initializer and displacement cannot be combined" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.ProgramError, "(make-array 1 :initial-element 0 :initial-contents '(1))");
    try fx.expectErr(Error.ProgramError, "(make-array 1 :displaced-to (make-array 1) :initial-element 0)");
    try fx.expectErr(Error.ProgramError, "(make-array 1 :displaced-to (make-array 1) :initial-contents '(1))");
}

test "displacement is bounds-checked against its target" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(make-array 3 :displaced-to (make-array 2))");
    try fx.expectErr(Error.TypeError, "(make-array 2 :displaced-to (make-array 4) :displaced-index-offset 3)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :displaced-to 7)");
    try fx.expectErr(Error.TypeError, "(make-array 1 :element-type 'character :displaced-to (make-array 1))");
}

test "displacement chains through to the array that owns the storage" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let* ((base (make-array 4 :initial-contents '(1 2 3 4)))
        \\       (mid (make-array 3 :displaced-to base :displaced-index-offset 1))
        \\       (top (make-array 2 :displaced-to mid :displaced-index-offset 1)))
        \\  (setf (aref top 0) 9)
        \\  (equal (concatenate 'list base) '(1 2 9 4)))
    );
}

test ":fill-pointer accepts t or an index in range" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(fill-pointer (make-array 3 :fill-pointer t))", 3);
    try fx.expectFix("(fill-pointer (make-array 3 :fill-pointer 2))", 2);
    try fx.expectErr(Error.TypeError, "(make-array 2 :fill-pointer 3)");
    try fx.expectErr(Error.TypeError, "(make-array 2 :fill-pointer -1)");
    try fx.expectErr(Error.TypeError, "(make-array 2 :fill-pointer \"x\")");
    try fx.expectErr(Error.TypeError, "(make-array '(2 2) :fill-pointer 1)");
}

// --- element access ---

test "aref indexes by subscript and row-major-aref by offset" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(aref (make-array '(2 3) :initial-contents '((1 2 3) (4 5 6))) 1 2)", 6);
    try fx.expectFix("(row-major-aref (make-array '(2 3) :initial-contents '((1 2 3) (4 5 6))) 4)", 5);
    try fx.expectT("(typep (aref \"abc\" 1) 'character)");
    try fx.expectT("(typep (row-major-aref \"abc\" 1) 'character)");
}

test "aref reaches past a fill pointer" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(aref (make-array 3 :fill-pointer 1 :initial-contents '(1 2 3)) 2)", 3);
    try fx.expectT(
        "(eq (aref (make-array 3 :element-type 'character :fill-pointer 1 " ++
            ":initial-contents \"abc\") 2) #\\c)",
    );
}

test "aref checks its subscripts" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(aref)");
    try fx.expectErr(Error.TypeError, "(aref 7 0)");
    try fx.expectErr(Error.ProgramError, "(aref (make-array '(2 2)) 0)");
    try fx.expectErr(Error.ProgramError, "(aref \"abc\" 0 0)");
    try fx.expectErr(Error.TypeError, "(aref (make-array 2) 2)");
    try fx.expectErr(Error.TypeError, "(aref (make-array 2) -1)");
    try fx.expectErr(Error.TypeError, "(aref (make-array 2) 'x)");
    try fx.expectErr(Error.TypeError, "(aref \"abc\" 3)");
    try fx.expectErr(Error.TypeError, "(aref \"abc\" 'x)");
}

test "setf aref stores through subscripts and checks the element" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix(
        "(let ((a (make-array '(2 2) :initial-element 0))) (setf (aref a 1 1) 7) (aref a 1 1))",
        7,
    );
    try fx.expectText("(let ((s (make-string 2))) (setf (aref s 0) #\\z) s)", "z ");
    try fx.expectErr(Error.WrongArgCount, "(%set-aref (make-array 1))");
    try fx.expectErr(Error.TypeError, "(%set-aref 7 0 1)");
    try fx.expectErr(Error.TypeError, "(%set-aref (make-string 1) 0 7)");
    try fx.expectErr(Error.TypeError, "(%set-aref (make-array 1 :element-type 'bit) 0 5)");
}

test "row-major access is bounds-checked and type-checked" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(row-major-aref (make-array 1))");
    try fx.expectErr(Error.WrongArgCount, "(%set-row-major-aref (make-array 1) 0)");
    try fx.expectErr(Error.TypeError, "(row-major-aref (make-array 1) 1)");
    try fx.expectErr(Error.TypeError, "(row-major-aref (make-array 1) 'x)");
    try fx.expectErr(Error.TypeError, "(row-major-aref 7 0)");
    try fx.expectErr(Error.TypeError, "(%set-row-major-aref 7 0 1)");
    try fx.expectErr(Error.TypeError, "(%set-row-major-aref (make-string 1) 0 7)");
    try fx.expectErr(Error.TypeError, "(%set-row-major-aref (make-array 1 :element-type 'bit) 0 5)");
    try fx.expectErr(Error.TypeError, "(%set-row-major-aref (make-array 1) 1 0)");
    try fx.expectText("(let ((s (make-string 1))) (%set-row-major-aref s 0 #\\q) s)", "q");
}

// --- introspection ---

test "the array predicates cover strings, vectors and higher ranks" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(arrayp \"ab\")");
    try fx.expectT("(arrayp (make-array '(2 2)))");
    try fx.expectNil("(arrayp 7)");
    try fx.expectT("(vectorp \"ab\")");
    try fx.expectNil("(vectorp (make-array '(2 2)))");
    try fx.expectNil("(vectorp 7)");
    try fx.expectNil("(simple-vector-p \"ab\")");
    try fx.expectNil("(simple-vector-p (make-array 1 :adjustable t))");
    try fx.expectNil("(simple-vector-p (make-array 1 :fill-pointer 0))");
    try fx.expectNil("(simple-vector-p (make-array 1 :displaced-to (make-array 1)))");
    try fx.expectNil("(bit-vector-p \"ab\")");
    try fx.expectNil("(bit-vector-p (make-array '(2 2) :element-type 'bit))");
}

test "the array predicates take exactly one argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "(arrayp)",                   "(vectorp)",
        "(simple-vector-p)",          "(bit-vector-p)",
        "(array-rank)",               "(array-dimensions)",
        "(array-total-size)",         "(array-element-type)",
        "(array-displacement)",       "(adjustable-array-p)",
        "(array-has-fill-pointer-p)", "(fill-pointer)",
        "(vector-pop)",
    }) |src| {
        try fx.expectErr(Error.WrongArgCount, src);
    }
}

test "rank, dimensions and total size read a string as a vector" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(array-rank \"abc\")", 1);
    try fx.expectT("(equal (array-dimensions \"abc\") '(3))");
    try fx.expectFix("(array-total-size \"abc\")", 3);
    try fx.expectFix("(array-dimension \"abc\" 0)", 3);
    try fx.expectT("(eq (array-element-type \"abc\") 'character)");
    try fx.expectNil("(array-displacement \"abc\")");
}

test "array-dimension checks its axis" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(array-dimension (make-array '(2 3)) 1)", 3);
    try fx.expectErr(Error.WrongArgCount, "(array-dimension (make-array 1))");
    try fx.expectErr(Error.TypeError, "(array-dimension (make-array '(2 3)) 2)");
    try fx.expectErr(Error.TypeError, "(array-dimension (make-array 1) -1)");
    try fx.expectErr(Error.TypeError, "(array-dimension (make-array 1) 'x)");
    try fx.expectErr(Error.TypeError, "(array-dimension \"abc\" 1)");
    try fx.expectErr(Error.TypeError, "(array-dimension 7 0)");
}

test "the adjustable and fill-pointer predicates read strings too" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(adjustable-array-p \"ab\")");
    try fx.expectT("(adjustable-array-p (make-array 1 :element-type 'character :adjustable t))");
    try fx.expectNil("(array-has-fill-pointer-p \"ab\")");
    try fx.expectT("(array-has-fill-pointer-p (make-array 1 :element-type 'character :fill-pointer 0))");
    try fx.expectErr(Error.TypeError, "(adjustable-array-p 7)");
    try fx.expectErr(Error.TypeError, "(array-has-fill-pointer-p 7)");
}

test "fill-pointer needs a vector that has one" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(fill-pointer (make-array 2))");
    try fx.expectErr(Error.TypeError, "(fill-pointer \"ab\")");
    try fx.expectErr(Error.TypeError, "(%set-fill-pointer (make-array 2) 1)");
    try fx.expectErr(Error.TypeError, "(%set-fill-pointer \"ab\" 1)");
    try fx.expectErr(Error.WrongArgCount, "(%set-fill-pointer (make-array 2))");
    try fx.expectErr(Error.TypeError, "(%set-fill-pointer (make-array 2 :fill-pointer 0) 3)");
    try fx.expectFix(
        "(let ((s (make-array 3 :element-type 'character :fill-pointer 0))) " ++
            "(setf (fill-pointer s) 2) (length s))",
        2,
    );
}

// --- fill-pointer operations ---

test "vector-push and vector-pop move the fill pointer" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(let ((a (make-array 2 :fill-pointer 0))) (vector-push 'x a) (fill-pointer a))", 1);
    try fx.expectNil("(let ((a (make-array 1 :fill-pointer 1))) (vector-push 'x a))");
    try fx.expectT("(let ((a (make-array 1 :fill-pointer 0))) (vector-push 'x a) (eq (vector-pop a) 'x))");
    try fx.expectT(
        "(let ((s (make-array 2 :element-type 'character :fill-pointer 0))) " ++
            "(vector-push #\\a s) (eq (vector-pop s) #\\a))",
    );
}

test "the fill-pointer operations need a fill pointer" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(vector-push 'x (make-array 2))");
    try fx.expectErr(Error.TypeError, "(vector-push 'x \"ab\")");
    try fx.expectErr(Error.TypeError, "(vector-push 'x (make-array '(2 2)))");
    try fx.expectErr(Error.TypeError, "(vector-push 'x 7)");
    try fx.expectErr(Error.WrongArgCount, "(vector-push 'x)");
    try fx.expectErr(Error.ProgramError, "(vector-pop (make-array 1 :fill-pointer 0))");
    try fx.expectErr(Error.TypeError, "(vector-push 5 (make-array 1 :element-type 'bit :fill-pointer 0))");
}

test "vector-push-extend grows the vector when it is full" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((a (make-array 1 :fill-pointer 0)))
        \\  (vector-push-extend 'x a)
        \\  (vector-push-extend 'y a)
        \\  (equal (concatenate 'list a) '(x y)))
    );
    try fx.expectT(
        \\(let ((s (make-array 1 :element-type 'character :fill-pointer 0)))
        \\  (vector-push-extend #\a s)
        \\  (vector-push-extend #\b s)
        \\  (string= s "ab"))
    );
    try fx.expectFix(
        "(let ((a (make-array 1 :fill-pointer 1))) (vector-push-extend 'y a 10) (array-total-size a))",
        11,
    );
}

test "vector-push-extend checks its extension argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(vector-push-extend 'x)");
    try fx.expectErr(Error.WrongArgCount, "(vector-push-extend 'x (make-array 1 :fill-pointer 0) 1 2)");
    try fx.expectErr(Error.TypeError, "(vector-push-extend 'x (make-array 1 :fill-pointer 1) 0)");
    try fx.expectErr(Error.TypeError, "(vector-push-extend 'x (make-array 1 :fill-pointer 1) 'y)");
}

// --- adjust-array ---

test "adjust-array grows and shrinks an adjustable array in place" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((a (make-array 2 :adjustable t :initial-contents '(1 2))))
        \\  (and (eq (adjust-array a 3) a)
        \\       (equal (concatenate 'list a) '(1 2 nil))))
    );
    try fx.expectT(
        \\(let ((a (make-array 3 :adjustable t :initial-contents '(1 2 3))))
        \\  (adjust-array a 2)
        \\  (equal (concatenate 'list a) '(1 2)))
    );
}

test "adjust-array accepts the make-array initializers" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((a (make-array 2 :adjustable t)))
        \\  (adjust-array a 3 :initial-element 7)
        \\  (equal (concatenate 'list a) '(nil nil 7)))
    );
    try fx.expectT(
        \\(let ((a (make-array 2 :adjustable t)))
        \\  (adjust-array a 3 :initial-contents '(1 2 3))
        \\  (equal (concatenate 'list a) '(1 2 3)))
    );
    try fx.expectT(
        \\(let* ((target (make-array 3 :initial-contents '(1 2 3)))
        \\       (a (make-array 2 :adjustable t)))
        \\  (adjust-array a 2 :displaced-to target :displaced-index-offset 1)
        \\  (equal (concatenate 'list a) '(2 3)))
    );
    try fx.expectFix(
        "(let ((a (make-array 2 :adjustable t :fill-pointer 2))) (adjust-array a 4 :fill-pointer 3) (fill-pointer a))",
        3,
    );
}

test "adjust-array clamps a fill pointer that no longer fits" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix(
        "(let ((a (make-array 4 :adjustable t :fill-pointer 4))) (adjust-array a 2) (fill-pointer a))",
        2,
    );
}

test "adjust-array on a non-adjustable array returns a fresh one" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let* ((a (make-array 2 :initial-contents '(1 2)))
        \\       (b (adjust-array a 3 :initial-contents '(7 8 9))))
        \\  (and (not (eq a b))
        \\       (equal (concatenate 'list b) '(7 8 9))
        \\       (equal (concatenate 'list a) '(1 2))))
    );
    try fx.expectT(
        \\(let* ((target (make-array 2 :initial-contents '(5 6)))
        \\       (a (make-array 2 :initial-contents '(1 2)))
        \\       (b (adjust-array a 2 :displaced-to target)))
        \\  (equal (concatenate 'list b) '(5 6)))
    );
}

test "adjust-array on a string honors adjustability" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText(
        "(let ((s (make-array 2 :element-type 'character :adjustable t :initial-element #\\x))) " ++
            "(adjust-array s 4 :initial-element #\\y) s)",
        "xxyy",
    );
    try fx.expectText(
        "(let ((s (make-array 4 :element-type 'character :adjustable t :initial-element #\\x))) " ++
            "(adjust-array s 2) s)",
        "xx",
    );
    try fx.expectText("(adjust-array (make-string 2) 3)", "   ");
    try fx.expectFix(
        "(fill-pointer (let ((s (make-array 2 :element-type 'character :adjustable t " ++
            ":fill-pointer 2))) (adjust-array s 4 :fill-pointer 1) s))",
        1,
    );
}

test "adjust-array checks its arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(adjust-array (make-array 1))");
    try fx.expectErr(Error.TypeError, "(adjust-array (make-array '(2 2)) 3)");
    try fx.expectErr(Error.TypeError, "(adjust-array \"ab\" '(2 2))");
    try fx.expectErr(Error.TypeError, "(adjust-array 7 3)");
    try fx.expectErr(Error.TypeError, "(adjust-array (make-array 1 :element-type 'bit :adjustable t) 2 :initial-element 5)");
    try fx.expectErr(Error.TypeError, "(adjust-array (make-array 1 :element-type 'bit :adjustable t) 2 :initial-contents '(0 5))");
    try fx.expectErr(Error.TypeError, "(adjust-array (make-array 2 :element-type 'character :adjustable t) 3 :initial-element 7)");
}
