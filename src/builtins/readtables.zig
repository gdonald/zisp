//! The readtable as a Lisp object.
//!
//! The dispatch table itself lives in the reader; this wraps one in a heap
//! object so `*readtable*` can be bound, copied, and asked for its case.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const reader_mod = @import("../reader.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const Readtable = reader_mod.Readtable;

pub const VARIABLE = "*READTABLE*";

pub fn registerReadtables(ev: *Evaluator) !void {
    _ = try ev.defineNative("COPY-READTABLE", &copyReadtableFn);
    _ = try ev.defineNative("READTABLEP", &readtablepFn);
    _ = try ev.defineNative("READTABLE-CASE", &readtableCaseFn);
    _ = try ev.defineNative("%SET-READTABLE-CASE", &setReadtableCaseFn);

    const sym = try ev.interner.intern(VARIABLE);
    symbol_mod.symbol(sym).value_cell = try allocStandard(ev, 0);
}

fn allocStandard(ev: *Evaluator, case: u64) Error!Value {
    return allocCopy(ev, reader_mod.reader.defaultReadtable(), case);
}

/// A heap readtable holding its own copy of `source`'s handler table.
fn allocCopy(ev: *Evaluator, source: *const Readtable, case: u64) Error!Value {
    const bytes = try ev.heap.allocator.alignedAlloc(u8, .of(Readtable), @sizeOf(Readtable));
    const table: *Readtable = @ptrCast(bytes.ptr);
    table.* = source.*;
    return ev.heap.allocReadtable(bytes, case);
}

/// The readtable `*readtable*` names, or the standard one when the
/// variable holds something else.
pub fn active(ev: *Evaluator) ?*heap.HeapReadtable {
    const found = ev.interner.cl.findPresent(VARIABLE) orelse return null;
    const bound = symbol_mod.symbol(found.sym).value_cell;
    if (!heap.isReadtable(bound)) return null;
    return heap.asReadtable(bound);
}

/// Point a fresh reader at the active readtable and its case.
pub fn install(ev: *Evaluator, rd: *reader_mod.Reader) void {
    const rt = active(ev) orelse return;
    rd.readtable = @ptrCast(@alignCast(rt.handlers));
    rd.case = @enumFromInt(rt.case);
}

fn expectReadtable(v: Value) Error!*heap.HeapReadtable {
    if (!heap.isReadtable(v)) return Error.TypeError;
    return heap.asReadtable(v);
}

fn copyReadtableFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len > 2) return Error.WrongArgCount;
    const source = if (args.len == 0 or args[0].equalsRaw(value.NIL))
        active(ev) orelse return Error.TypeError
    else
        try expectReadtable(args[0]);
    const from: *const Readtable = @ptrCast(@alignCast(source.handlers));
    return ev.set1(try allocCopy(ev, from, source.case));
}

fn readtablepFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len != 1) return Error.WrongArgCount;
    return ev.set1(if (heap.isReadtable(args[0])) value.T else value.NIL);
}

const CASE_NAMES = [_][]const u8{ "UPCASE", "DOWNCASE", "PRESERVE", "INVERT" };

fn readtableCaseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len != 1) return Error.WrongArgCount;
    const rt = try expectReadtable(args[0]);
    return ev.set1(try ev.interner.internKeyword(CASE_NAMES[@intCast(rt.case)]));
}

fn setReadtableCaseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len != 2) return Error.WrongArgCount;
    const rt = try expectReadtable(args[0]);
    if (!args[1].isSymbol()) return Error.TypeError;
    const name = symbol_mod.symbol(args[1]).name;
    for (CASE_NAMES, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) {
            rt.case = index;
            return ev.set1(args[1]);
        }
    }
    return Error.TypeError;
}
