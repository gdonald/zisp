//! Hash tables: the four tests, the construction options, update and
//! removal, traversal, and introspection.

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

    fn expectSym(self: *Fixture, src: []const u8, name: []const u8) !void {
        const v = try self.evalStr(src);
        try testing.expectEqualStrings(name, symbol_mod.name(v));
    }

    fn expectErr(self: *Fixture, err: Error, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- construction ---

test "make-hash-table defaults to an eql table" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectSym("(hash-table-test (make-hash-table))", "EQL");
    try fx.expectT("(hash-table-p (make-hash-table))");
    try fx.expectNil("(hash-table-p 7)");
    try fx.expectErr(Error.WrongArgCount, "(hash-table-p)");
}

test ":test accepts a symbol or the function it names" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectSym("(hash-table-test (make-hash-table :test 'eq))", "EQ");
    try fx.expectSym("(hash-table-test (make-hash-table :test 'equal))", "EQUAL");
    try fx.expectSym("(hash-table-test (make-hash-table :test #'equalp))", "EQUALP");
}

test "make-hash-table records size and the rehash parameters" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(hash-table-size (make-hash-table :size 99))", 99);
    try fx.expectFix("(hash-table-rehash-size (make-hash-table :rehash-size 2))", 2);
    try fx.expectNil("(hash-table-rehash-size (make-hash-table))");
    try fx.expectNil("(hash-table-rehash-threshold (make-hash-table))");
    try fx.expectT("(equalp (hash-table-rehash-threshold (make-hash-table :rehash-threshold 0.75)) 0.75)");
}

test "the size grows once the table holds more than it was asked for" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix(
        \\(let ((h (make-hash-table :size 1)))
        \\  (setf (gethash 'a h) 1)
        \\  (setf (gethash 'b h) 2)
        \\  (hash-table-size h))
    , 2);
}

test "make-hash-table rejects a bad option" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(make-hash-table :test)");
    try fx.expectErr(Error.ProgramError, "(make-hash-table :frob 1)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :test 'string=)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :test 7)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :test #'car)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :test (lambda (a b) a))");
    try fx.expectErr(Error.TypeError, "(make-hash-table :size -1)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :size 'x)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :rehash-size 'x)");
    try fx.expectErr(Error.TypeError, "(make-hash-table :rehash-threshold 'x)");
}

// --- the four tests ---

test "an eq table keys on identity" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'eq)))
        \\  (setf (gethash 'a h) 1)
        \\  (and (eql (gethash 'a h) 1)
        \\       (null (gethash (list 1) h))))
    );
}

test "an eql table matches numbers of the same type and value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'eql)))
        \\  (setf (gethash 1.5 h) 'float)
        \\  (setf (gethash 3/4 h) 'ratio)
        \\  (and (eq (gethash 1.5 h) 'float)
        \\       (eq (gethash 3/4 h) 'ratio)
        \\       (null (gethash 1 h))))
    );
}

test "an equal table matches lists and strings by structure" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'equal)))
        \\  (setf (gethash (list 1 (list 2)) h) 'nested)
        \\  (setf (gethash (copy-seq "key") h) 'text)
        \\  (and (eq (gethash (list 1 (list 2)) h) 'nested)
        \\       (eq (gethash (copy-seq "key") h) 'text)
        \\       (null (gethash (copy-seq "KEY") h))))
    );
}

test "an equalp table ignores case and compares numbers across types" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'equalp)))
        \\  (setf (gethash "AB" h) 'text)
        \\  (setf (gethash 1 h) 'number)
        \\  (setf (gethash #\A h) 'letter)
        \\  (and (eq (gethash (copy-seq "ab") h) 'text)
        \\       (eq (gethash 1.0 h) 'number)
        \\       (eq (gethash #\a h) 'letter)))
    );
}

test "an equalp table descends into vectors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'equalp)))
        \\  (setf (gethash (vector 1 2) h) 'found)
        \\  (and (eq (gethash (vector 1 2) h) 'found)
        \\       (null (gethash (vector 1 3) h))))
    );
}

test "an equal table keys on a pathname's namestring" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'equal)))
        \\  (setf (gethash (pathname "/a/b.lsp") h) 'found)
        \\  (eq (gethash (pathname "/a/b.lsp") h) 'found))
    );
}

test "structural hashing survives a deeply nested key" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(progn
        \\  (defun nest (n) (if (zerop n) nil (list (nest (1- n)))))
        \\  (let ((h (make-hash-table :test 'equal)))
        \\    (setf (gethash (nest 30) h) 'deep)
        \\    (eq (gethash (nest 30) h) 'deep)))
    );
    try fx.expectT(
        \\(progn
        \\  (defun nest2 (n) (if (zerop n) nil (list (nest2 (1- n)))))
        \\  (let ((h (make-hash-table :test 'equalp)))
        \\    (setf (gethash (nest2 30) h) 'deep)
        \\    (eq (gethash (nest2 30) h) 'deep)))
    );
}

// --- update and removal ---

test "gethash returns a present flag as its second value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(nth-value 1 (let ((h (make-hash-table))) (setf (gethash 'a h) nil) (gethash 'a h)))");
    try fx.expectNil("(nth-value 1 (gethash 'a (make-hash-table)))");
    try fx.expectFix("(gethash 'a (make-hash-table) 7)", 7);
}

test "setting an existing key replaces its value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table)))
        \\  (setf (gethash 'a h) 1)
        \\  (setf (gethash 'a h) 2)
        \\  (and (eql (gethash 'a h) 2) (= (hash-table-count h) 1)))
    );
}

test "remhash reports whether it removed anything" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table)))
        \\  (setf (gethash 'a h) 1)
        \\  (and (eq (remhash 'a h) t)
        \\       (null (remhash 'a h))
        \\       (= (hash-table-count h) 0)
        \\       (null (gethash 'a h))))
    );
}

test "a key can be put back after being removed" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table)))
        \\  (setf (gethash 'a h) 1)
        \\  (remhash 'a h)
        \\  (setf (gethash 'a h) 2)
        \\  (and (eql (gethash 'a h) 2) (= (hash-table-count h) 1)))
    );
}

test "clrhash empties the table and returns it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table)))
        \\  (setf (gethash 'a h) 1)
        \\  (setf (gethash 'b h) 2)
        \\  (and (eq (clrhash h) h)
        \\       (= (hash-table-count h) 0)
        \\       (null (gethash 'a h))))
    );
    try fx.expectT(
        \\(let ((h (make-hash-table)))
        \\  (setf (gethash 'a h) 1)
        \\  (clrhash h)
        \\  (setf (gethash 'a h) 3)
        \\  (eql (gethash 'a h) 3))
    );
}

// --- traversal ---

test "maphash visits every live pair" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix(
        \\(let ((h (make-hash-table)) (total 0))
        \\  (setf (gethash 'a h) 1)
        \\  (setf (gethash 'b h) 2)
        \\  (setf (gethash 'c h) 3)
        \\  (remhash 'b h)
        \\  (maphash (lambda (k v) (setq total (+ total v))) h)
        \\  total)
    , 4);
    try fx.expectNil("(maphash #'cons (make-hash-table))");
}

test "with-hash-table-iterator walks the pairs one at a time" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix(
        \\(let ((h (make-hash-table)) (total 0))
        \\  (setf (gethash 'a h) 1)
        \\  (setf (gethash 'b h) 2)
        \\  (with-hash-table-iterator (next h)
        \\    (tagbody
        \\     step
        \\       (multiple-value-bind (more key val) (next)
        \\         (declare (ignore key))
        \\         (when more
        \\           (setq total (+ total val))
        \\           (go step)))))
        \\  total)
    , 3);
    try fx.expectNil(
        \\(let ((h (make-hash-table)))
        \\  (with-hash-table-iterator (next h) (next)))
    );
}

test "traversal checks its arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(maphash #'cons)");
    try fx.expectErr(Error.TypeError, "(maphash #'cons 7)");
    try fx.expectErr(Error.TypeError, "(maphash 7 (make-hash-table))");
    try fx.expectErr(Error.UnboundFunction, "(maphash 'no-such-visitor (make-hash-table))");
    try fx.expectErr(Error.WrongArgCount, "(%hash-table-entries)");
    try fx.expectErr(Error.TypeError, "(%hash-table-entries 7)");
}

// --- introspection ---

test "the accessors reject anything that is not a hash table" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "(gethash 'a 7)",
        "(%puthash 'a 7 1)",
        "(remhash 'a 7)",
        "(clrhash 7)",
        "(hash-table-count 7)",
        "(hash-table-size 7)",
        "(hash-table-test 7)",
        "(hash-table-rehash-size 7)",
        "(hash-table-rehash-threshold 7)",
    }) |src| {
        try fx.expectErr(Error.TypeError, src);
    }
}

test "the accessors check their argument counts" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "(gethash 'a)",
        "(gethash 'a (make-hash-table) 1 2)",
        "(%puthash 'a (make-hash-table))",
        "(remhash 'a)",
        "(clrhash)",
        "(hash-table-count)",
        "(hash-table-size)",
        "(hash-table-test)",
        "(hash-table-rehash-size)",
        "(hash-table-rehash-threshold)",
    }) |src| {
        try fx.expectErr(Error.WrongArgCount, src);
    }
}
