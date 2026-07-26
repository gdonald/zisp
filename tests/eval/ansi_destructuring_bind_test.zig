//! Runs `vendor/ansi-test/data-and-control-flow/destructuring-bind.lsp`
//! without the rt framework: each `deftest` form's body is evaluated and its
//! values compared with `equal` against the expected values.
//!
//! `signals-error` cases pass when evaluation signals any error; condition
//! class discrimination needs the condition system and is not checked yet.
//! `destructuring-bind.31` needs `macrolet` and is the one expected failure,
//! keeping the file at 38/39 (97%).

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const heap_mod = zisp.heap;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;

const lsp_path = "vendor/ansi-test/data-and-control-flow/destructuring-bind.lsp";

const expected_failures = [_][]const u8{
    "DESTRUCTURING-BIND.31",
};

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

fn symbolNamed(v: value.Value, name: []const u8) bool {
    return v.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(v).name, name);
}

test "ansi-test destructuring-bind.lsp deftests" {
    const gpa = std.testing.allocator;

    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, lsp_path, .{}) catch
        return error.SkipZigTest;
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try file_reader.interface.appendRemainingUnlimited(gpa, &source);
    file.close(io);
    const src = source.items;

    const fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    // Scaffolding the rt framework would otherwise provide.
    _ = try fx.evalStr(
        \\(defmacro notnot (x) (list 'not (list 'not x)))
        \\(defmacro expand-in-current-env (f &environment env) (macroexpand f env))
    );

    const equal_sym = try fx.interner.intern("EQUAL");
    const mvl_sym = try fx.interner.intern("MULTIPLE-VALUE-LIST");
    const quote_sym = try fx.interner.intern("QUOTE");

    var total: u32 = 0;
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(gpa);

    var tk = Tokenizer.init(src);
    var rd = Reader.init(&tk, &fx.heap, &fx.interner);
    while (try rd.read()) |form| {
        if (!form.isCons() or !symbolNamed(heap_mod.car(form), "DEFTEST")) continue;
        const name_cell = heap_mod.cdr(form);
        const name = heap_mod.car(name_cell);
        const body_cell = heap_mod.cdr(name_cell);
        const test_form = heap_mod.car(body_cell);
        const expected = heap_mod.cdr(body_cell);
        total += 1;

        var pass = false;
        if (test_form.isCons() and symbolNamed(heap_mod.car(test_form), "SIGNALS-ERROR")) {
            const inner = heap_mod.car(heap_mod.cdr(test_form));
            if (fx.ev.eval(inner)) |_| {
                pass = false;
            } else |_| {
                pass = true;
            }
        } else {
            // (equal (multiple-value-list <test-form>) '<expected>)
            const mvl = try fx.heap.allocCons(mvl_sym, try fx.heap.allocCons(test_form, value.NIL));
            const quoted = try fx.heap.allocCons(quote_sym, try fx.heap.allocCons(expected, value.NIL));
            const cmp = try fx.heap.allocCons(
                equal_sym,
                try fx.heap.allocCons(mvl, try fx.heap.allocCons(quoted, value.NIL)),
            );
            if (fx.ev.eval(cmp)) |got| {
                pass = got.equalsRaw(value.T);
            } else |_| {
                pass = false;
            }
        }

        if (!pass) try failed.append(gpa, symbol_mod.symbol(name).name);
    }

    try std.testing.expectEqual(@as(u32, 39), total);
    for (failed.items) |f| {
        var known = false;
        for (expected_failures) |x| {
            if (std.mem.eql(u8, f, x)) known = true;
        }
        if (!known) {
            std.debug.print("unexpected ansi-test failure: {s}\n", .{f});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(expected_failures.len, failed.items.len);
}
