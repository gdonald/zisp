//! defmacro, macro expansion in eval, macroexpand-1 / macroexpand, and
//! *macroexpand-hook*.

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;

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

    fn read(self: *Fixture, src: []const u8) !value.Value {
        var tk = Tokenizer.init(src);
        var rd = Reader.init(&tk, &self.heap, &self.interner);
        return (try rd.read()) orelse error.TestUnexpectedResult;
    }

    /// Read and evaluate every form in `src`, returning the last result.
    fn evalStr(self: *Fixture, src: []const u8) !value.Value {
        var tk = Tokenizer.init(src);
        var rd = Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| {
            result = try self.ev.eval(form);
        }
        return result;
    }
};

test "defmacro returns the macro name" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr("(defmacro my-mac (x) x)");
    try std.testing.expect(r.equalsRaw(try fx.interner.intern("MY-MAC")));
}

test "macro call expands and evaluates the expansion" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-if (c a b) (list 'if c a b))
        \\(my-if t 1 2)
    );
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "macro arguments are not evaluated at expansion time" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // The unbound X only appears in the untaken branch of the expansion.
    const r = try fx.evalStr(
        \\(defmacro my-if (c a b) (list 'if c a b))
        \\(my-if nil x 2)
    );
    try std.testing.expectEqual(@as(i64, 2), r.toFixnum());
}

test "macro receives argument forms, not values" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro second-form (a b) b)
        \\(second-form (no-such-function) 5)
    );
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
}

test "&body collects the remaining forms" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-progn (&body body) (cons 'progn body))
        \\(my-progn 1 2 3)
    );
    try std.testing.expectEqual(@as(i64, 3), r.toFixnum());
}

test "macro lambda list supports &optional defaults" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro plus-default (a &optional (b 10)) (list '+ a b))
        \\(plus-default 1)
    );
    try std.testing.expectEqual(@as(i64, 11), r.toFixnum());
}

test "macro expansion happens in tail position" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro seven () 7)
        \\(funcall (lambda () (seven)))
    );
    try std.testing.expectEqual(@as(i64, 7), r.toFixnum());
}

test "macroexpand-1 returns the expansion and T" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-if (c a b) (list 'if c a b))
        \\(equal (multiple-value-list (macroexpand-1 '(my-if t 1 2)))
        \\       '((if t 1 2) t))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}

test "macroexpand-1 on a non-macro form returns the form and NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(equal (multiple-value-list (macroexpand-1 '(cons 1 2)))
        \\       '((cons 1 2) nil))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}

test "macroexpand-1 on an atom returns it and NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(equal (multiple-value-list (macroexpand-1 '5)) '(5 nil))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}

test "macroexpand-1 accepts an optional environment argument" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro nine () 9)
        \\(macroexpand-1 '(nine) nil)
    );
    try std.testing.expectEqual(@as(i64, 9), r.toFixnum());
}

test "macroexpand expands repeatedly until fixed point" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro inner () 42)
        \\(defmacro outer () '(inner))
        \\(equal (multiple-value-list (macroexpand '(outer))) '(42 t))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}

test "macroexpand on a non-macro form returns the form and NIL" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(equal (multiple-value-list (macroexpand '(cons 1 2)))
        \\       '((cons 1 2) nil))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}

test "*macroexpand-hook* defaults to the funcall designator" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr("*macroexpand-hook*");
    try std.testing.expect(r.equalsRaw(try fx.interner.intern("FUNCALL")));
}

test "*macroexpand-hook* replaces the expansion when overridden" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-mac () 1)
        \\(setq *macroexpand-hook* (lambda (expander form env) ''hooked))
        \\(my-mac)
    );
    try std.testing.expect(r.equalsRaw(try fx.interner.intern("HOOKED")));
}

test "*macroexpand-hook* can delegate to the expander" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-if (c a b) (list 'if c a b))
        \\(setq *macroexpand-hook* (lambda (expander form env) (funcall expander form env)))
        \\(my-if t 1 2)
    );
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "flet function shadows a global macro" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro twice (x) (list '+ x x))
        \\(flet ((twice (x) (+ x 100)))
        \\  (twice 3))
    );
    try std.testing.expectEqual(@as(i64, 103), r.toFixnum());
}

test "defmacro rejects a missing lambda list" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr("(defmacro no-params)"));
}

test "defmacro rejects a non-symbol name" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.TypeError, fx.evalStr("(defmacro 5 (x) x)"));
}

test "defmacro rejects zero args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr("(defmacro)"));
}

test "&body is not recognized in a plain lambda list section marker set" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // In a function lambda list, &BODY is not a marker; here it binds like a
    // required parameter name, so a one-argument call succeeds.
    const r = try fx.evalStr("(funcall (lambda (&body) &body) 5)");
    try std.testing.expectEqual(@as(i64, 5), r.toFixnum());
}

test "macro call with too few arguments errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.WrongArgCount, fx.evalStr(
        \\(defmacro two-args (a b) (list '+ a b))
        \\(two-args 1)
    ));
}

test "macroexpand-1 leaves special forms alone" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(equal (multiple-value-list (macroexpand-1 '(if t 1 2)))
        \\       '((if t 1 2) nil))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}

test "unbound *macroexpand-hook* falls back to a direct call" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    _ = try fx.evalStr("(defmacro my-mac () 1)");
    const hook_sym = try fx.interner.intern("*MACROEXPAND-HOOK*");
    symbol_mod.symbol(hook_sym).value_cell = value.SPECIAL_UNBOUND;

    const r = try fx.evalStr("(my-mac)");
    try std.testing.expectEqual(@as(i64, 1), r.toFixnum());
}

test "*macroexpand-hook* as a symbol designator resolves through the function namespace" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-mac () 1)
        \\(setq *macroexpand-hook* 'my-hook)
        \\(flet ((my-hook (expander form env) ''sym-hooked))
        \\  (my-mac))
    );
    try std.testing.expect(r.equalsRaw(try fx.interner.intern("SYM-HOOKED")));
}

test "*macroexpand-hook* bound to an undefined function symbol errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.UnboundFunction, fx.evalStr(
        \\(defmacro my-mac () 1)
        \\(setq *macroexpand-hook* 'no-such-hook)
        \\(my-mac)
    ));
}

test "*macroexpand-hook* bound to a non-designator errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.TypeError, fx.evalStr(
        \\(defmacro my-mac () 1)
        \\(setq *macroexpand-hook* 99)
        \\(my-mac)
    ));
}

test "defmacro rejects a malformed lambda list" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr("(defmacro bad (&rest) 1)"));
}

test "macroexpand-1 rejects zero args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr("(macroexpand-1)"));
}

test "macroexpand-1 rejects more than two args" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr("(macroexpand-1 '(cons 1 2) nil nil)"));
}

test "funcall of a macro function with the wrong arg count errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.WrongArgCount, fx.evalStr(
        \\(defmacro my-mac () 1)
        \\(funcall (function my-mac) '(my-mac))
    ));
}

test "funcall of a macro function with a non-cons form errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.TypeError, fx.evalStr(
        \\(defmacro my-mac () 1)
        \\(funcall (function my-mac) 5 nil)
    ));
}

test "funcall of a macro function with a dotted form errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr(
        \\(defmacro my-mac (&body b) 1)
        \\(funcall (function my-mac) '(my-mac 1 . 2) nil)
    ));
}

test "funcall of a macro function uses the (form env) protocol" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr(
        \\(defmacro my-if (c a b) (list 'if c a b))
        \\(equal (funcall (function my-if) '(my-if t 1 2) nil) '(if t 1 2))
    );
    try std.testing.expect(r.equalsRaw(value.T));
}
