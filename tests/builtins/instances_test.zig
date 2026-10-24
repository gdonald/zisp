//! The natives CLOS is built on: instances, funcallable instances,
//! `class-of`, the slot fast paths, dispatch, and the helpers the Lisp side
//! calls for lambda lists, initforms and precedence lists.

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
        fx.ev.io = testing.io;
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

    fn expectErr(self: *Fixture, expected: anyerror, src: []const u8) !void {
        try testing.expectError(expected, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

test "the instance natives check how many arguments they are given" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    for ([_][]const u8{
        "(cl::%allocate-standard-instance 1)",
        "(cl::%allocate-funcallable-instance 1)",
        "(cl::%instance-p)",
        "(cl::%funcallable-instance-p)",
        "(cl::%instance-class)",
        "(cl::%instance-slots)",
        "(cl::%instance-wrapper)",
        "(cl::%set-instance-layout 1)",
        "(cl::%set-funcallable-instance-function 1)",
        "(cl::%set-function-name 1)",
        "(cl::%class-of)",
        "(cl::%write-unhooked 1)",
        "(cl::%object-address)",
        "(cl::%fast-slot-value 1)",
        "(cl::%fast-set-slot-value 1 2)",
        "(cl::%fast-slot-boundp 1)",
        "(cl::%gf-dispatch 1)",
        "(cl::%tree-names-function-p 1)",
        "(cl::%lambda-list-keyword-p)",
        "(cl::%parse-lambda-list)",
        "(cl::%initial-value 1)",
        "(cl::%direct-instance-p 1)",
        "(cl::%memq 1)",
        "(cl::%find-class-quietly)",
        "(cl::%topological-cpl)",
    }) |src| try fx.expectErr(Error.WrongArgCount, src);
}

test "what is not an instance is turned away by the instance accessors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectErr(Error.TypeError, "(cl::%instance-class 5)");
    try fx.expectErr(Error.TypeError, "(cl::%instance-slots 'a)");
    try fx.expectErr(Error.TypeError, "(cl::%instance-wrapper (list 1))");
    try fx.expectErr(Error.TypeError, "(cl::%set-instance-layout 5 1 2 3)");
    try fx.expectErr(Error.TypeError, "(cl::%set-funcallable-instance-function #'car #'car)");
    try fx.expectErr(Error.TypeError, "(cl::%set-function-name 5 'a)");
    try fx.expectT("(null (cl::%instance-p 5))");
    try fx.expectT("(null (cl::%funcallable-instance-p #'car))");
    try fx.expectT("(cl::%funcallable-instance-p #'print-object)");
}

test "a funcallable instance runs the function it was given" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    _ = try fx.evalStr(
        \\(defvar *fi* (cl::%allocate-funcallable-instance
        \\               (find-class 'standard-generic-function) nil (vector)))
    );
    try fx.expectErr(Error.TypeError, "(cl::%set-funcallable-instance-function *fi* 5)");
    _ = try fx.evalStr("(cl::%set-funcallable-instance-function *fi* (lambda (x) (* x 2)))");
    try fx.expectT("(eql (funcall *fi* 21) 42)");
    try fx.expectT("(eq (cl::%instance-class *fi*) (find-class 'standard-generic-function))");
    try fx.expectT("(simple-vector-p (cl::%instance-slots *fi*))");
    try fx.expectT("(null (cl::%instance-wrapper *fi*))");
    _ = try fx.evalStr("(cl::%set-instance-layout *fi* (find-class 'standard-generic-function) :w (vector 1))");
    try fx.expectT("(eq (cl::%instance-wrapper *fi*) :w)");
}

test "a function given a name prints with it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    _ = try fx.evalStr("(defvar *named* (lambda () 1))");
    try fx.expectT("(equal (prin1-to-string *named*) \"#<FUNCTION (LAMBDA)>\")");
    _ = try fx.evalStr("(cl::%set-function-name *named* 'renamed)");
    try fx.expectT("(equal (prin1-to-string *named*) \"#<FUNCTION RENAMED>\")");
    _ = try fx.evalStr("(cl::%set-function-name *named* '(setf renamed))");
    try fx.expectT("(equal (prin1-to-string *named*) \"#<FUNCTION (SETF RENAMED)>\")");
}

test "class-of names the built-in class of each kind of object" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(equal (mapcar (lambda (x) (class-name (class-of x)))
        \\               (list nil '(1) 'a 1 #\a (expt 2 100) 1/2 1.0 1d0 #c(1 2) "s"
        \\                     #(1) (make-array '(2 2)) #*101 (make-hash-table) #'car
        \\                     (find-package "CL") #p"/tmp/x" (make-random-state)
        \\                     *readtable* (make-string-output-stream)
        \\                     (make-condition 'simple-error)))
        \\       '(null cons symbol fixnum character bignum ratio single-float
        \\         double-float complex string vector array bit-vector hash-table
        \\         function package pathname random-state readtable string-stream
        \\         simple-error))
    );
    _ = try fx.evalStr("(setf (logical-pathname-translations \"INSTANCES\") '((\"**;*.*.*\" \"/x/**/*.*\")))");
    try fx.expectT("(eq (class-of (logical-pathname \"INSTANCES:A;B.C\")) (find-class 'logical-pathname))");
    try fx.expectT("(with-open-file (s \"build.zig\") (eq (class-of s) (find-class 'file-stream)))");
}

test "class-of a structure with no class of its own is structure-object" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(eq (class-of (cl::%make-structure 'no-class-here 1)) (find-class 'structure-object))");
    try fx.expectT("(macrolet ((m (&environment e) (eq (class-of e) (find-class 'structure-object)))) (m))");
}

test "the slot fast paths miss for what is not a standard instance" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    _ = try fx.evalStr("(defstruct fast-path-struct a)");
    try fx.expectT("(eq (cl::%fast-slot-value 5 'a) cl::*%fast-miss*)");
    try fx.expectT("(eq (cl::%fast-slot-value (make-fast-path-struct) 'a) cl::*%fast-miss*)");
    try fx.expectT("(null (cl::%fast-set-slot-value 5 'a 1))");
    try fx.expectT("(eq (cl::%fast-slot-boundp 5 'a) cl::*%fast-miss*)");
    _ = try fx.evalStr("(defclass fast-path-class () ((a) (typed :type integer) (shared :allocation :class)))");
    _ = try fx.evalStr("(defvar *fp* (make-instance 'fast-path-class))");
    try fx.expectT("(eq (cl::%fast-slot-value *fp* 'a) cl::*%fast-miss*)");
    try fx.expectT("(eq (cl::%fast-slot-value *fp* 'missing) cl::*%fast-miss*)");
    try fx.expectT("(null (cl::%fast-slot-boundp *fp* 'a))");
    try fx.expectT("(null (cl::%fast-set-slot-value *fp* 'typed 1))");
    try fx.expectT("(cl::%fast-set-slot-value *fp* 'shared 3)");
    try fx.expectT("(eql (cl::%fast-slot-value *fp* 'shared) 3)");
    try fx.expectT("(cl::%fast-slot-boundp *fp* 'shared)");
}

test "dispatch hands a call it cannot answer from its cache to Lisp" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    _ = try fx.evalStr("(defgeneric dispatched (x y))");
    _ = try fx.evalStr("(defmethod dispatched ((x integer) (y (eql :k))) :both)");
    _ = try fx.evalStr("(defmethod dispatched ((x integer) y) :first)");
    try fx.expectT("(eq (dispatched 1 :k) :both)");
    try fx.expectT("(eq (dispatched 1 :k) :both)");
    try fx.expectT("(eq (dispatched 1 2) :first)");
    try fx.expectT("(eq (handler-case (dispatched 1) (program-error () :few)) :few)");
    try fx.expectT("(eq (handler-case (dispatched 1 2 3) (program-error () :many)) :many)");
    try fx.expectErr(Error.TypeError, "(cl::%gf-dispatch 5 nil)");
}

test "the lambda list and initform helpers" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(equal (cl::%parse-lambda-list '(a b &optional c (d 1) &rest r &key e ((:f g) 2) &allow-other-keys &aux h))
        \\       '((a b) (c (d 1)) r (e ((:f g) 2)) t t))
    );
    try fx.expectT("(equal (cl::%parse-lambda-list '(a &body b)) '((a) nil b nil nil nil))");
    try fx.expectT("(and (cl::%lambda-list-keyword-p '&whole) (not (cl::%lambda-list-keyword-p 'x)))");
    try fx.expectT("(eq (cl::%initial-value ''quoted (lambda () :called)) 'quoted)");
    try fx.expectT("(eql (cl::%initial-value 5 (lambda () :called)) 5)");
    try fx.expectT("(eq (cl::%initial-value :key (lambda () :called)) :key)");
    try fx.expectT("(eq (cl::%initial-value nil (lambda () :called)) nil)");
    try fx.expectT("(eq (cl::%initial-value 'variable (lambda () :called)) :called)");
    try fx.expectT("(eq (cl::%initial-value '(+ 1 2) (lambda () :called)) :called)");
    try fx.expectT("(cl::%tree-names-function-p '(a (b #'call-next-method)) '(call-next-method))");
    try fx.expectT("(null (cl::%tree-names-function-p '(call-next-method (function)) '(call-next-method)))");
    try fx.expectT("(equal (cl::%memq 2 '(1 2 3)) '(2 3))");
    try fx.expectT("(null (cl::%memq 4 '(1 2 3)))");
    try fx.expectT("(cl::%direct-instance-p (find-class 'integer) (find-class 'built-in-class))");
    try fx.expectT("(null (cl::%direct-instance-p 5 (find-class 'built-in-class)))");
    try fx.expectT("(null (cl::%find-class-quietly 5))");
}

test "an object's address is a fixnum and stays put while nothing moves" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    _ = try fx.evalStr("(defvar *addressed* (list 1))");
    try fx.expectT("(eql (cl::%object-address *addressed*) (cl::%object-address *addressed*))");
    try fx.expectT("(typep (cl::%object-address *addressed*) 'fixnum)");
}

test "write-unhooked prints a condition's report when not escaping" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(equal (with-output-to-string (s)
        \\         (let ((*print-escape* nil))
        \\           (cl::%write-unhooked (cl::%make-restart :name 'r :report-function (lambda (s) (write-string "go" s))) s)))
        \\       "go")
    );
}
