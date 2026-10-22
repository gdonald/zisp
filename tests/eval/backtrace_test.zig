//! Backtraces, read from corpora whose source positions are recorded.
//!
//! Each file under `tests/lisp/` named here is read with a position table
//! under its own name, so the positions a backtrace reports can be
//! written into the cases. Every top-level form must evaluate to T.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;

fn runCorpus(file: []const u8, text: []const u8) !u32 {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var interner = try symbol_mod.Interner.init(gpa);
    defer interner.deinit();
    try symbol_mod.initStandardSymbols(&interner);
    var heap = zisp.Heap.init(arena.allocator());
    var ev = Evaluator.init(gpa, &heap, &interner);
    defer ev.deinit();
    try zisp.eval.registerStandardSpecialForms(&ev);
    try zisp.builtins.registerStandard(&ev);

    var tk = zisp.reader.Tokenizer.init(text);
    var rd = zisp.reader.Reader.initFull(
        &tk,
        &heap,
        &interner,
        zisp.reader.reader.defaultReadtable(),
        try ev.sourcePositions(),
        file,
    );
    var checked: u32 = 0;
    while (try rd.read()) |form| {
        checked += 1;
        const got = ev.eval(form) catch |e| {
            std.debug.print("{s} form {d}: eval error {s}\n", .{ file, checked, @errorName(e) });
            return e;
        };
        if (!got.equalsRaw(value.T)) {
            std.debug.print("{s} form {d}: expected T\n", .{ file, checked });
            return error.TestUnexpectedResult;
        }
    }
    return checked;
}

test "a backtrace lists every call of a recursion with its arguments and place" {
    const checked = try runCorpus("backtrace-corpus.lisp", @embedFile("../lisp/backtrace-corpus.lisp"));
    try testing.expectEqual(@as(u32, 11), checked);
}

test "a backtrace places a call a macro built where the macro was called" {
    const checked = try runCorpus("backtrace-macroexpand.lisp", @embedFile("../lisp/backtrace-macroexpand.lisp"));
    try testing.expectEqual(@as(u32, 6), checked);
}
