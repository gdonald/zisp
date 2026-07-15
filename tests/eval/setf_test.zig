//! setf machinery: get-setf-expansion's 5-value protocol, the setf macro,
//! defsetf short and long forms, define-setf-expander (via the corpus),
//! the built-in places, the place-modifying macros, and the backing
//! natives (defun, member, values-preserving funcall/apply/eval).

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

const corpus_text = @embedFile("../lisp/setf-expander-corpus.lisp");

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
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- get-setf-expansion protocol ---

test "get-setf-expansion returns the 5-value protocol for a variable" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    // temps and vals are nil, one store var, setq store form, the variable
    // itself as access form.
    try fx.expectT(
        \\(multiple-value-bind (temps vals stores store-form access-form)
        \\    (get-setf-expansion 'x)
        \\  (and (null temps) (null vals)
        \\       (equal (length stores) 1)
        \\       (eq (car store-form) 'setq)
        \\       (eq (cadr store-form) 'x)
        \\       (eq (car (cddr store-form)) (car stores))
        \\       (eq access-form 'x)))
    );
}

test "get-setf-expansion returns the 5-value protocol for a cons place" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(multiple-value-bind (temps vals stores store-form access-form)
        \\    (get-setf-expansion '(car some-cell))
        \\  (and (equal (length temps) 1)
        \\       (equal vals '(some-cell))
        \\       (equal (length stores) 1)
        \\       (consp store-form)
        \\       (equal access-form (cons 'car temps))))
    );
}

test "get-setf-expansion rejects a place with no expander" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.ProgramError, fx.evalStr(
        "(get-setf-expansion '(no-such-accessor x))",
    ));
}

// --- setf ---

test "setf on a variable is setq" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(progn (setf n 5) n)", 5);
    try fx.expectT("(equal (macroexpand-1 '(setf n 5)) '(setq n 5))");
}

test "setf with multiple pairs runs left to right and returns the last value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix(
        \\(progn (setq c (cons 1 2))
        \\       (setf (car c) 10 (cdr c) (+ (car c) 1)))
    , 11);
    try fx.expectT("(equal c '(10 . 11))");
}

test "setf with an odd number of arguments errors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.ProgramError, fx.evalStr("(setf (car x))"));
}

test "setf returns the new value for built-in places" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(progn (setq c (cons 1 2)) (setf (car c) 9))", 9);
    try fx.expectFix("(progn (setq l (list 1 2 3)) (setf (nth 1 l) 9))", 9);
    try fx.expectFix("(progn (setq l (list 1 2 3)) (setf (elt l 2) 9))", 9);
    try fx.expectFix("(setf (aref #(1 2 3) 0) 9)", 9);
    try fx.expectFix("(setf (gethash 'k (make-hash-table)) 9)", 9);
    try fx.expectFix("(setf (get 'sym 'ind) 9)", 9);
    try fx.expectFix("(setf (symbol-value 'sv) 9)", 9);
    try fx.expectFix("(setf (symbol-plist 'sp) '(a 9)) (get 'sp 'a)", 9);
}

test "setf symbol-function installs a callable function" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix(
        \\(progn (setf (symbol-function 'double) (lambda (n) (* 2 n)))
        \\       (double 21))
    , 42);
}

test "setf gethash stores; gethash returns value and presence" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(progn (setq h (make-hash-table))
        \\       (setf (gethash 'a h) 1)
        \\       (and (equal (multiple-value-list (gethash 'a h)) '(1 t))
        \\            (equal (multiple-value-list (gethash 'b h)) '(nil nil))
        \\            (equal (multiple-value-list (gethash 'b h 99)) '(99 nil))))
    );
}

// --- defsetf ---

test "defsetf short form dispatches to the update function" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    // Short-form setf returns whatever the update function returns.
    try fx.expectFix(
        \\(progn (setq cells (list 0 0))
        \\       (defun cell-ref (i) (nth i cells))
        \\       (defun cell-update (i v) (rplaca (nthcdr i cells) v) v)
        \\       (defsetf cell-ref cell-update)
        \\       (setf (cell-ref 1) 7)
        \\       (nth 1 cells))
    , 7);
}

test "defsetf long form evaluates each subform exactly once" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(progn
        \\  (setq obj-count 0 key-count 0 table (list (cons 'k 0)))
        \\  (defun my-getter (obj k) (cdr (member k obj :key #'car)))
        \\  (defsetf my-getter (obj k) (v)
        \\    `(progn (rplacd (car (member ,k ,obj :key #'car)) ,v) ,v))
        \\  (setf (my-getter (progn (setq obj-count (+ obj-count 1)) table)
        \\                   (progn (setq key-count (+ key-count 1)) 'k))
        \\        42)
        \\  (and (equal obj-count 1)
        \\       (equal key-count 1)
        \\       (equal (cdr (car table)) 42)))
    );
}

test "defsetf returns the accessor name" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(progn (defun triv (x) (car x))
        \\       (eq (defsetf triv rplaca) 'triv))
    );
}

// --- define-setf-expander corpus (SBCL-verified) ---

test "setf-expander corpus" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tk = zisp.reader.Tokenizer.init(corpus_text);
    var rd = zisp.reader.Reader.init(&tk, &fx.heap, &fx.interner);
    var checked: u32 = 0;
    while (try rd.read()) |form| {
        checked += 1;
        const got = fx.ev.eval(form) catch |e| {
            std.debug.print("setf corpus form {d}: eval error {s}\n", .{ checked, @errorName(e) });
            return e;
        };
        if (!got.equalsRaw(value.T)) {
            std.debug.print("setf corpus form {d}: expected T\n", .{checked});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(u32, 5), checked);
}

// --- place-modifying macros ---

test "push and pop work on variables and places" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(progn (setq stack nil)
        \\       (push 1 stack)
        \\       (push 2 stack)
        \\       (and (equal stack '(2 1))
        \\            (equal (pop stack) 2)
        \\            (equal stack '(1))))
    );
    try fx.expectT(
        \\(progn (setq holder (cons nil 'z))
        \\       (push 5 (car holder))
        \\       (push 6 (car holder))
        \\       (and (equal (car holder) '(6 5))
        \\            (equal (pop (car holder)) 6)
        \\            (equal (car holder) '(5))))
    );
}

test "pushnew respects :test and :key" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(progn (setq s '(1 2))
        \\       (pushnew 2 s)
        \\       (pushnew 3 s)
        \\       (equal s '(3 1 2)))
    );
    try fx.expectT(
        \\(progn (setq lol (list (list 1) (list 2)))
        \\       (pushnew (list 1) lol :test #'equal)
        \\       (pushnew (list 3) lol :test #'equal)
        \\       (equal lol '((3) (1) (2))))
    );
    try fx.expectT(
        \\(progn (setq pairs (list (cons 'a 1)))
        \\       (pushnew (cons 'a 9) pairs :key #'car)
        \\       (pushnew (cons 'b 2) pairs :key #'car)
        \\       (equal pairs '((b . 2) (a . 1))))
    );
}

test "incf and decf work on variables and places with deltas" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(progn (setq n 10) (incf n) (incf n 4) (decf n 2) (decf n) n)", 12);
    try fx.expectFix(
        \\(progn (setq c (cons 5 nil))
        \\       (incf (car c) 3)
        \\       (decf (car c))
        \\       (car c))
    , 7);
}

// --- backing natives ---

test "member finds tails with default eql, :test, and :key" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(equal (member 2 '(1 2 3)) '(2 3))");
    try fx.expectNil("(member 9 '(1 2 3))");
    try fx.expectT("(equal (member '(b) '((a) (b) (c)) :test #'equal) '((b) (c)))");
    try fx.expectT("(equal (member 'b '((a 1) (b 2)) :key #'car) '((b 2)))");
    try testing.expectError(Error.ProgramError, fx.evalStr("(member 1 '(1) :frob 2)"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(member 1)"));
}

test "defun defines a global function and returns its name" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(eq (defun add2 (n) (+ n 2)) 'add2)");
    try fx.expectFix("(progn (defun add3 (n) (+ n 3)) (add3 4))", 7);
    try fx.expectFix(
        \\(progn (defun fact (n) (if (= n 0) 1 (* n (fact (- n 1)))))
        \\       (fact 5))
    , 120);
    try testing.expectError(Error.TypeError, fx.evalStr("(defun 5 (x) x)"));
    try testing.expectError(Error.BadArgList, fx.evalStr("(defun no-params)"));
}

test "funcall, apply, and eval propagate multiple values" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT(
        \\(progn (defun two-vals () (values 1 2))
        \\       (and (equal (multiple-value-list (funcall #'two-vals)) '(1 2))
        \\            (equal (multiple-value-list (apply #'two-vals nil)) '(1 2))
        \\            (equal (multiple-value-list (eval '(two-vals))) '(1 2))))
    );
}

test "rplaca and rplacd return the cons" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectT("(equal (rplaca (cons 1 2) 9) '(9 . 2))");
    try fx.expectT("(equal (rplacd (cons 1 2) 9) '(1 . 9))");
    try testing.expectError(Error.TypeError, fx.evalStr("(rplaca 5 1)"));
}

test "get and %put manage property lists" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectNil("(get 'psym 'color)");
    try fx.expectFix("(get 'psym 'color 42)", 42);
    try fx.expectFix("(progn (setf (get 'psym 'color) 7) (get 'psym 'color))", 7);
    try fx.expectFix("(progn (setf (get 'psym 'color) 8) (get 'psym 'color))", 8);
    try fx.expectT("(equal (symbol-plist 'psym) '(color 8))");
    try testing.expectError(Error.TypeError, fx.evalStr("(get 5 'color)"));
}

test "aref and elt bounds and type errors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try fx.expectFix("(aref #(1 2 3) 2)", 3);
    try fx.expectFix("(elt #(1 2 3) 0)", 1);
    try fx.expectFix("(elt '(1 2 3) 1)", 2);
    try testing.expectError(Error.TypeError, fx.evalStr("(aref #(1) 5)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(aref '(1) 0)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(elt '(1) 5)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(elt '(1) -1)"));
}

test "symbol-value and symbol-function error when unbound" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.UnboundVariable, fx.evalStr("(symbol-value 'never-set-var)"));
    try testing.expectError(Error.UnboundFunction, fx.evalStr("(symbol-function 'never-set-fn)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(setf (symbol-function 'f) 5)"));
}
