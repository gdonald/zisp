const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Value = zisp.Value;

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
        try zisp.builtins.registerSystem(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn run(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var last = value.NIL;
        while (try rd.read()) |form| last = try self.ev.eval(form);
        return last;
    }

    fn runPrints(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.run(src);
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try zisp.printer.write(testing.allocator, &aw.writer, v, .{
            .escape = true,
            .current_package = self.interner.currentPackage(),
        });
        try testing.expectEqualStrings(expected, aw.written());
    }
};

test "defvar assigns only when the variable is unbound" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(defvar *v* 1) (defvar *v* 2) *v*", "1");
}

test "defvar with no initial value leaves the variable unbound" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v*)");
    try testing.expectError(error.UnboundVariable, fx.run("*v*"));
}

test "defvar returns the variable name" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(defvar *v* 1)", "*V*");
}

test "defvar rejects a non-symbol name" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.run("(defvar 3 1)"));
    try testing.expectError(error.BadArgList, fx.run("(defvar)"));
}

test "defparameter always reassigns" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(defparameter *v* 1) (defparameter *v* 2) *v*", "2");
}

test "defparameter requires an initial value" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.BadArgList, fx.run("(defparameter *v*)"));
    try testing.expectError(error.TypeError, fx.run("(defparameter 3 1)"));
}

test "defconstant marks the symbol constant" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defconstant +limit+ 10)");
    const sym = fx.interner.lookup("+LIMIT+").?;
    try testing.expect(symbol_mod.symbol(sym).constant);
    try fx.runPrints("+limit+", "10");
}

test "let rebinds a special variable dynamically" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v* 1)");
    _ = try fx.run("(defun peek () *v*)");
    try fx.runPrints("(let ((*v* 2)) (peek))", "2");
    try fx.runPrints("*v*", "1");
}

test "let* rebinds a special variable dynamically" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v* 1)");
    _ = try fx.run("(defun peek () *v*)");
    try fx.runPrints("(let* ((*v* 2) (other (peek))) other)", "2");
    try fx.runPrints("*v*", "1");
}

test "a non-special let binding stays lexical" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(setq plain 1)");
    _ = try fx.run("(defun peek () plain)");
    try fx.runPrints("(let ((plain 2)) (peek))", "1");
}

test "a dynamic binding unwinds when a throw passes through" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v* 1)");
    try fx.runPrints("(catch :out (let ((*v* 2)) (throw :out nil))) *v*", "1");
}

test "a lambda parameter named by a special variable binds dynamically" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v* 1)");
    _ = try fx.run("(defun peek () *v*)");
    _ = try fx.run("(defun call-with (*v*) (peek))");
    try fx.runPrints("(call-with 9)", "9");
    try fx.runPrints("*v*", "1");
}

test "a special parameter is unbound again after the call returns" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v* 1)");
    _ = try fx.run("(defun call-with (*v*) *v*)");
    try fx.runPrints("(list (call-with 9) *v*)", "(9 1)");
}

test "nested calls see their own dynamic binding and restore the outer one" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(defvar *v* 0)");
    _ = try fx.run("(defun descend (*v*) (if (= *v* 0) (list *v*) (cons *v* (descend (- *v* 1)))))");
    try fx.runPrints("(list (descend 3) *v*)", "((3 2 1 0) 0)");
}

test "declaim special makes a plain name bind dynamically" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(declaim (special dyn))");
    _ = try fx.run("(setq dyn 1)");
    _ = try fx.run("(defun peek () dyn)");
    try fx.runPrints("(let ((dyn 2)) (peek))", "2");
}

test "declaim ignores declarations other than special" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(declaim (ftype (function (t) t) f) (type list x) plain)", "NIL");
}

test "declaim special rejects a non-symbol name" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.run("(declaim (special 3))"));
}

test "*package* rebound by let is visible to the reader" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(let ((*package* (find-package \"MINE\"))) (intern \"HERE\"))");
    try fx.runPrints("(package-name (symbol-package (find-symbol \"HERE\" \"MINE\")))", "\"MINE\"");
    try fx.runPrints("(package-name *package*)", "\"COMMON-LISP-USER\"");
}
