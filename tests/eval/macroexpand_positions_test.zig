//! Source positions across macroexpansion.
//!
//! Reads `tests/lisp/macroexpand-positions.lisp` with a position table
//! shared between the reader and the evaluator. Each defmacro is evaluated;
//! each call form is expanded with macroexpand-1 and the expansion's cons
//! tree is walked against the position table:
//!   - verbatim conses keep the exact position the reader recorded;
//!   - synthesized conses carry the defining macro's definition position
//!     (for the nesting macro, the inner macro's definition position).

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const heap_mod = zisp.heap;
const source_pos = zisp.source_pos;
const Tokenizer = zisp.reader.Tokenizer;
const Evaluator = zisp.eval.Evaluator;

const corpus_text = @embedFile("../lisp/macroexpand-positions.lisp");
const corpus_file = "macroexpand-positions.lisp";

/// The one macro whose expansion contains conses synthesized by another
/// macro's expander, and that other macro.
const nesting_macro = "MP-7";
const nested_inner = "MP-2";

fn samePos(a: source_pos.SourcePosition, b: source_pos.SourcePosition) bool {
    return a.line == b.line and a.column == b.column and std.mem.eql(u8, a.file, b.file);
}

const DefPos = struct {
    name: []const u8,
    pos: source_pos.SourcePosition,
};

fn findDef(defs: []const DefPos, name: []const u8) ?source_pos.SourcePosition {
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.pos;
    }
    return null;
}

/// Record the position of every cons reachable from `v` into `pre`.
/// Every reader-produced cons must already have one.
fn snapshot(
    pre: *std.AutoHashMap(u64, source_pos.SourcePosition),
    table: *const source_pos.PositionTable,
    v: value.Value,
) !void {
    if (!v.isCons()) return;
    if (pre.contains(v.toConsAddr())) return;
    const pos = table.lookup(v) orelse return error.TestUnexpectedResult;
    try pre.put(v.toConsAddr(), pos);
    try snapshot(pre, table, heap_mod.car(v));
    try snapshot(pre, table, heap_mod.cdr(v));
}

/// Walk the expansion: verbatim conses must keep their snapshot position;
/// synthesized conses must carry one of the allowed definition positions.
fn checkExpansion(
    seen: *std.AutoHashMap(u64, void),
    table: *const source_pos.PositionTable,
    pre: *const std.AutoHashMap(u64, source_pos.SourcePosition),
    allowed: []const source_pos.SourcePosition,
    v: value.Value,
) !void {
    if (!v.isCons()) return;
    if (seen.contains(v.toConsAddr())) return;
    try seen.put(v.toConsAddr(), {});

    const pos = table.lookup(v) orelse {
        std.debug.print("expansion cons has no position\n", .{});
        return error.TestUnexpectedResult;
    };
    if (pre.get(v.toConsAddr())) |orig| {
        if (!samePos(pos, orig)) {
            std.debug.print("verbatim cons lost its position\n", .{});
            return error.TestUnexpectedResult;
        }
    } else {
        var ok = false;
        for (allowed) |a| {
            if (samePos(pos, a)) ok = true;
        }
        if (!ok) {
            std.debug.print(
                "synthesized cons at {d}:{d} not stamped with a definition position\n",
                .{ pos.line, pos.column },
            );
            return error.TestUnexpectedResult;
        }
    }
    try checkExpansion(seen, table, pre, allowed, heap_mod.car(v));
    try checkExpansion(seen, table, pre, allowed, heap_mod.cdr(v));
}

test "macroexpansion preserves and stamps source positions" {
    const gpa = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var interner = try symbol_mod.Interner.init(gpa);
    defer interner.deinit();
    try symbol_mod.initStandardSymbols(&interner);
    var heap = zisp.Heap.init(arena.allocator());

    var positions = source_pos.PositionTable.init(gpa);
    defer positions.deinit();

    var ev = Evaluator.init(gpa, &heap, &interner);
    defer ev.deinit();
    try zisp.eval.registerStandardSpecialForms(&ev);
    try zisp.builtins.registerStandard(&ev);
    ev.positions = &positions;

    var tk = Tokenizer.init(corpus_text);
    var rd = zisp.reader.Reader.initFull(
        &tk,
        &heap,
        &interner,
        zisp.reader.reader.defaultReadtable(),
        &positions,
        corpus_file,
    );

    var defs: std.ArrayList(DefPos) = .empty;
    defer defs.deinit(gpa);
    var expanded: u32 = 0;

    while (try rd.read()) |form| {
        if (!form.isCons()) return error.TestUnexpectedResult;
        const head = heap_mod.car(form);
        if (head.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(head).name, "DEFMACRO")) {
            const name = heap_mod.car(heap_mod.cdr(form));
            const pos = positions.lookup(form) orelse return error.TestUnexpectedResult;
            try defs.append(gpa, .{ .name = symbol_mod.symbol(name).name, .pos = pos });
            _ = try ev.eval(form);
            continue;
        }

        // A call form to expand.
        const macro_name = symbol_mod.symbol(head).name;
        var pre = std.AutoHashMap(u64, source_pos.SourcePosition).init(gpa);
        defer pre.deinit();
        try snapshot(&pre, &positions, form);

        const expansion = (try ev.macroexpand1(form)) orelse return error.TestUnexpectedResult;

        // The nesting macro's expansion is built entirely by the inner
        // macro's expander, so its synthesized conses must carry the inner
        // macro's definition position.
        const def_name = if (std.mem.eql(u8, macro_name, nesting_macro))
            nested_inner
        else
            macro_name;
        const allowed = [_]source_pos.SourcePosition{
            findDef(defs.items, def_name) orelse return error.TestUnexpectedResult,
        };

        var seen = std.AutoHashMap(u64, void).init(gpa);
        defer seen.deinit();
        try checkExpansion(&seen, &positions, &pre, &allowed, expansion);
        expanded += 1;
    }

    try std.testing.expectEqual(@as(usize, 10), defs.items.len);
    try std.testing.expectEqual(@as(u32, 10), expanded);
}
