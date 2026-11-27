//! The readtable: each character's syntax type and, for a macro
//! character, what the reader calls on seeing it.
//!
//! A readtable is Lisp data, a simple vector with a slot for each
//! character below `DIRECT` and an alist past that for the rest, so the
//! functions a program installs are traced and moved by the collector
//! like any other slot.
//!
//! A slot holds a fixnum for a character that is not a macro character,
//! its `Syntax`. A macro character's slot holds a vector of three:
//! what to call, whether it terminates a token, and for a dispatching
//! character its table of sub-characters. What to call is a function, or
//! a fixnum naming one of the reader's own `Builtin` macros.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const character = @import("../runtime/character.zig");

const Value = value.Value;
const Heap = heap_mod.Heap;

/// Characters below this have a slot of their own.
pub const DIRECT: usize = 256;
/// The vector's length: the direct slots and the alist after them.
const TABLE_LEN: usize = DIRECT + 1;

pub const Syntax = enum(u8) {
    whitespace,
    constituent,
    single_escape,
    multiple_escape,
    terminating_macro,
    non_terminating_macro,
    invalid,
};

/// The reader's own macro functions. The first group are macro
/// characters, the rest the sub-characters of `#`.
pub const Builtin = enum(u8) {
    left_paren,
    right_paren,
    quote,
    semicolon,
    double_quote,
    backquote,
    comma,
    dispatch,
    sharp_backslash,
    sharp_quote,
    sharp_left_paren,
    sharp_asterisk,
    sharp_colon,
    sharp_dot,
    sharp_b,
    sharp_o,
    sharp_x,
    sharp_r,
    sharp_c,
    sharp_a,
    sharp_s,
    sharp_p,
    sharp_equal,
    sharp_sharp,
    sharp_plus,
    sharp_minus,
    sharp_bar,
};

/// What one character means to the reader.
pub const Entry = struct {
    syntax: Syntax,
    /// For a macro character, a function or a `Builtin` as a fixnum.
    function: Value,
    /// For a dispatching macro character, its sub-character table.
    dispatch: Value,
};

/// The constituent trait that makes a character an error in a token
/// when it is a constituent: what CLHS 2.1.4.2 lists as invalid.
pub fn invalidConstituent(code: u21) bool {
    return switch (code) {
        0x08, '\t', '\n', 0x0C, '\r', ' ', 0x7F => true,
        else => false,
    };
}

fn standardSyntax(code: usize) Syntax {
    return switch (code) {
        '\t', '\n', 0x0B, 0x0C, '\r', ' ' => .whitespace,
        '"', '\'', '(', ')', ',', ';', '`' => .terminating_macro,
        '#' => .non_terminating_macro,
        '\\' => .single_escape,
        '|' => .multiple_escape,
        else => .constituent,
    };
}

fn standardMacro(code: usize) ?Builtin {
    return switch (code) {
        '(' => .left_paren,
        ')' => .right_paren,
        '\'' => .quote,
        ';' => .semicolon,
        '"' => .double_quote,
        '`' => .backquote,
        ',' => .comma,
        '#' => .dispatch,
        else => null,
    };
}

fn standardSharp(code: usize) ?Builtin {
    return switch (code) {
        '\\' => .sharp_backslash,
        '\'' => .sharp_quote,
        '(' => .sharp_left_paren,
        '*' => .sharp_asterisk,
        ':' => .sharp_colon,
        '.' => .sharp_dot,
        'B' => .sharp_b,
        'O' => .sharp_o,
        'X' => .sharp_x,
        'R' => .sharp_r,
        'C' => .sharp_c,
        'A' => .sharp_a,
        'S' => .sharp_s,
        'P' => .sharp_p,
        '=' => .sharp_equal,
        '#' => .sharp_sharp,
        '+' => .sharp_plus,
        '-' => .sharp_minus,
        '|' => .sharp_bar,
        else => null,
    };
}

pub fn builtinValue(b: Builtin) Value {
    return Value.fromFixnum(@backingInt(b));
}

/// The builtin a slot's function names, if it names one.
pub fn asBuiltin(function: Value) ?Builtin {
    if (!function.isFixnum()) return null;
    const n = function.toFixnum();
    if (n < 0 or n >= @typeInfo(Builtin).@"enum".field_names.len) return null;
    return @fromBackingInt(@intCast(n));
}

fn syntaxValue(syntax: Syntax) Value {
    return Value.fromFixnum(@backingInt(syntax));
}

/// The standard readtable as a fresh vector.
pub fn standard(h: *Heap) !Value {
    var held = h.protect();
    defer held.close();
    try held.push(try h.allocArray(&.{TABLE_LEN}, .t));
    const table = held.items()[0];
    for (0..DIRECT) |code| {
        heap_mod.setSlot(h, table, code, syntaxValue(standardSyntax(code)));
    }
    try held.push(value.NIL);
    try held.push(try h.allocArray(&.{TABLE_LEN}, .t));
    const sharp = held.items()[2];
    for (0..DIRECT) |code| {
        if (standardSharp(code)) |b| heap_mod.setSlot(h, sharp, code, builtinValue(b));
    }
    for (0..DIRECT) |code| {
        const b = standardMacro(code) orelse continue;
        const syntax = standardSyntax(code);
        const sub = if (b == .dispatch) sharp else value.NIL;
        const made = try macroEntry(h, builtinValue(b), syntax == .terminating_macro, sub);
        heap_mod.setSlot(h, held.items()[0], code, made);
    }
    return held.items()[0];
}

fn macroEntry(h: *Heap, function: Value, terminating: bool, dispatch: Value) !Value {
    return h.allocVector(&.{ function, if (terminating) value.T else value.NIL, dispatch });
}

/// The slot value for `code`: the direct slot, or the alist entry's.
fn slotOf(table: Value, code: u21) Value {
    const slots = heap_mod.arrayElements(table);
    if (code < DIRECT) return slots[code];
    var rest = slots[DIRECT];
    while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
        const pair = heap_mod.car(rest);
        if (heap_mod.car(pair).toFixnum() == code) return heap_mod.cdr(pair);
    }
    return syntaxValue(.constituent);
}

fn decode(slot: Value) Entry {
    if (slot.isFixnum()) return .{ .syntax = @fromBackingInt(@intCast(slot.toFixnum())), .function = value.NIL, .dispatch = value.NIL };
    const parts = heap_mod.arrayElements(slot);
    return .{
        .syntax = if (parts[1].equalsRaw(value.NIL)) .non_terminating_macro else .terminating_macro,
        .function = parts[0],
        .dispatch = parts[2],
    };
}

pub fn entry(table: Value, code: u21) Entry {
    return decode(slotOf(table, code));
}

pub fn syntaxOf(table: Value, code: u21) Syntax {
    const slot = slotOf(table, code);
    if (slot.isFixnum()) return @fromBackingInt(@intCast(slot.toFixnum()));
    return if (heap_mod.arrayElements(slot)[1].equalsRaw(value.NIL)) .non_terminating_macro else .terminating_macro;
}

/// What `dispatch` holds for `sub`, which is looked up without case:
/// a function, a builtin's fixnum, or NIL.
pub fn subFunction(dispatch: Value, sub: u21) Value {
    const code = character.upcase(sub);
    const slots = heap_mod.arrayElements(dispatch);
    if (code < DIRECT) return slots[code];
    var rest = slots[DIRECT];
    while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
        const pair = heap_mod.car(rest);
        if (heap_mod.car(pair).toFixnum() == code) return heap_mod.cdr(pair);
    }
    return value.NIL;
}

/// Store `slot` for `code` in `table`.
fn store(h: *Heap, table: Value, code: u21, slot: Value) !void {
    if (code < DIRECT) return heap_mod.setSlot(h, table, code, slot);
    var held = h.protect();
    defer held.close();
    try held.push(table);
    try held.push(slot);
    var rest = heap_mod.arrayElements(table)[DIRECT];
    while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
        const pair = heap_mod.car(rest);
        if (heap_mod.car(pair).toFixnum() == code) return heap_mod.setCdr(h, pair, slot);
    }
    const pair = try h.allocCons(Value.fromFixnum(code), slot);
    try held.push(pair);
    const list = try h.allocCons(pair, heap_mod.arrayElements(held.items()[0])[DIRECT]);
    heap_mod.setSlot(h, held.items()[0], DIRECT, list);
}

pub fn setSyntax(h: *Heap, table: Value, code: u21, syntax: Syntax) !void {
    return store(h, table, code, syntaxValue(syntax));
}

/// Make `code` a macro character calling `function`, with an empty
/// sub-character table when it dispatches.
pub fn setMacro(h: *Heap, table: Value, code: u21, function: Value, terminating: bool, dispatching: bool) !void {
    var held = h.protect();
    defer held.close();
    try held.push(table);
    try held.push(function);
    const sub = if (dispatching) try h.allocArray(&.{TABLE_LEN}, .t) else value.NIL;
    try held.push(sub);
    const made = try macroEntry(h, held.items()[1], terminating, sub);
    return store(h, held.items()[0], code, made);
}

pub fn setSubFunction(h: *Heap, dispatch: Value, sub: u21, function: Value) !void {
    return store(h, dispatch, character.upcase(sub), function);
}

/// Copy `from`'s entries into `into`, giving `into` tables of its own so
/// a change to one readtable is not seen through the other.
pub fn copyInto(h: *Heap, from: Value, into: Value) !void {
    var held = h.protect();
    defer held.close();
    try held.push(from);
    try held.push(into);
    try held.push(value.NIL);
    for (0..DIRECT) |code| {
        const slot = try copySlot(h, heap_mod.arrayElements(from)[code]);
        heap_mod.setSlot(h, into, code, slot);
    }
    var rest = heap_mod.arrayElements(from)[DIRECT];
    while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
        const pair = heap_mod.car(rest);
        const slot = try copySlot(h, heap_mod.cdr(pair));
        const fresh = try h.allocCons(heap_mod.car(pair), slot);
        held.setItem(2, try h.allocCons(fresh, held.items()[2]));
    }
    heap_mod.setSlot(h, into, DIRECT, held.items()[2]);
}

fn copySlot(h: *Heap, slot: Value) !Value {
    if (slot.isFixnum()) return slot;
    const parts = heap_mod.arrayElements(slot);
    const terminating = !parts[1].equalsRaw(value.NIL);
    if (parts[2].equalsRaw(value.NIL)) return macroEntry(h, parts[0], terminating, value.NIL);
    var held = h.protect();
    defer held.close();
    try held.push(try h.allocArray(&.{TABLE_LEN}, .t));
    const sub = held.items()[0];
    const source = parts[2];
    for (0..DIRECT) |code| heap_mod.setSlot(h, sub, code, heap_mod.arrayElements(source)[code]);
    var rest = heap_mod.arrayElements(source)[DIRECT];
    while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
        const pair = heap_mod.car(rest);
        const fresh = try h.allocCons(heap_mod.car(pair), heap_mod.cdr(pair));
        heap_mod.setSlot(h, sub, DIRECT, try h.allocCons(fresh, heap_mod.arrayElements(sub)[DIRECT]));
    }
    return macroEntry(h, parts[0], terminating, sub);
}

/// A fresh vector holding a copy of `from`.
pub fn copy(h: *Heap, from: Value) !Value {
    var held = h.protect();
    defer held.close();
    try held.push(from);
    try held.push(try h.allocArray(&.{TABLE_LEN}, .t));
    try copyInto(h, held.items()[0], held.items()[1]);
    return held.items()[1];
}

/// Give `to` in `into` the syntax `from` has in `source`, and for a macro
/// character its function and a copy of its sub-character table.
pub fn copyCharacter(h: *Heap, source: Value, from: u21, into: Value, to: u21) !void {
    var held = h.protect();
    defer held.close();
    try held.push(into);
    try held.push(try copySlot(h, slotOf(source, from)));
    return store(h, held.items()[0], to, held.items()[1]);
}

pub fn isTable(v: Value) bool {
    return heap_mod.isArray(v) and heap_mod.arrayElements(v).len == TABLE_LEN;
}
