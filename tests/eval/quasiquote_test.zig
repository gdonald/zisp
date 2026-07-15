//! Quasiquote expander: produced form shape, edge-case errors, and
//! evaluation through the special form.

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

test "the expander produces an append/list/quote form" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // `(a ,b ,@c) reads as (quasiquote template); expand the template.
    const form = try fx.read("`(a ,b ,@c)");
    const template = heap_mod.car(heap_mod.cdr(form));
    const expansion = try zisp.eval.quasiquote.expand(&fx.ev, template);

    try std.testing.expect(expansion.isCons());
    try std.testing.expect(heap_mod.car(expansion).equalsRaw(try fx.interner.intern("APPEND")));
    // First segment is (list 'a); the quote of a is buried one level down.
    const seg1 = heap_mod.car(heap_mod.cdr(expansion));
    try std.testing.expect(heap_mod.car(seg1).equalsRaw(try fx.interner.intern("LIST")));
}

test "bare unquote outside backquote errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.ProgramError, fx.evalStr("(let ((x 1)) ,x)"));
}

test "bare unquote-splicing outside backquote errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.ProgramError, fx.evalStr("(let ((x '(1))) ,@x)"));
}

test "splice at the top level of a template errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.ProgramError, fx.evalStr("(let ((x '(1))) `,@x)"));
}

test "splice in dotted tail position errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.ProgramError, fx.evalStr("(let ((x '(1))) `(a . ,@x))"));
}

test "doubly nested template with inner double unquote evaluates" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr("(let ((x 5)) ``(,(,x)))");
    try std.testing.expect(r.isCons());
}

test "quasiquote requires exactly one template" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.BadArgList, fx.evalStr("(quasiquote)"));
    try std.testing.expectError(Error.BadArgList, fx.evalStr("(quasiquote a b)"));
}

test "unquote with no subform inside a template errors" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.ProgramError, fx.evalStr("`(a (unquote))"));
}

test "a multi-subform unquote element distributes its subforms" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    // (unquote f1 f2) only arises when an earlier round distributed a
    // splice into a marker; each subform becomes its own element.
    const r = try fx.evalStr("(equal `(a (unquote 1 2)) '(a 1 2))");
    try std.testing.expect(r.equalsRaw(value.T));
}

test "nested backquote in dotted tail position round-trips" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    const r = try fx.evalStr("(equal (eval (cdr `(a . `(b)))) '(b))");
    try std.testing.expect(r.equalsRaw(value.T));
}

test "eval builtin rejects wrong arg counts" {
    const fx = try Fixture.init(std.testing.allocator);
    defer fx.deinit(std.testing.allocator);

    try std.testing.expectError(Error.WrongArgCount, fx.evalStr("(eval)"));
    try std.testing.expectError(Error.WrongArgCount, fx.evalStr("(eval '1 '2)"));
}
