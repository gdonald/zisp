//! The pretty printer's Lisp surface: logical blocks, conditional
//! newlines, indentation, and the dispatch table.
//!
//! Writing to a pretty stream records layout tokens instead of characters.
//! When the outermost block closes, the tokens are laid out against
//! `*print-right-margin*` and the text goes to the underlying stream.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const pretty = @import("../runtime/pretty.zig");
const printer = @import("../runtime/printer.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const equality = @import("../runtime/equality.zig");
const circle_mod = @import("../runtime/circle.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const streams = @import("streams.zig");
const format = @import("format.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const Stream = heap.HeapStream;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerPprint(ev: *Evaluator) !void {
    function.asFunction(try ev.defineNative("PPRINT", &pprintFn)).preserves_values = true;
    _ = try ev.defineNative("PRIN1", writerFn(.escape));
    _ = try ev.defineNative("PRINC", writerFn(.plain));
    _ = try ev.defineNative("%WRITE", writerFn(.current));
    _ = try ev.defineNative("PRINT", &printFn);
    _ = try ev.defineNative("TERPRI", &terpriFn);
    _ = try ev.defineNative("FRESH-LINE", &freshLineFn);
    _ = try ev.defineNative("%MAKE-PRETTY-STREAM", &makePrettyStreamFn);
    _ = try ev.defineNative("%PRETTY-STREAM-FINISH", &finishFn);
    _ = try ev.defineNative("%PPRINT-BLOCK-START", &blockStartFn);
    _ = try ev.defineNative("%PPRINT-BLOCK-END", &blockEndFn);
    _ = try ev.defineNative("PPRINT-NEWLINE", &pprintNewlineFn);
    _ = try ev.defineNative("PPRINT-INDENT", &pprintIndentFn);
    _ = try ev.defineNative("PPRINT-TAB", &pprintTabFn);
    function.asFunction(try ev.defineNative("%PPRINT-OPEN", &pprintOpenFn)).preserves_values = true;
    _ = try ev.defineNative("%PPRINT-CLOSE", &pprintCloseFn);
    _ = try ev.defineNative("%PPRINT-SHARED-P", &pprintSharedFn);
    _ = try ev.defineNative("SET-PPRINT-DISPATCH", &setPprintDispatchFn);
    _ = try ev.defineNative("COPY-PPRINT-DISPATCH", &copyPprintDispatchFn);
    _ = try ev.defineNative("%PPRINT-DISPATCH-TABLE-P", &tablePFn);
    function.asFunction(try ev.defineNative("PPRINT-DISPATCH", &pprintDispatchFn))
        .preserves_values = true;

    try bindVariable(ev, "*PRINT-PRETTY*", value.NIL);
    try bindVariable(ev, "*PRINT-RIGHT-MARGIN*", value.NIL);
    try bindVariable(ev, "*PRINT-MISER-WIDTH*", value.NIL);
    try bindVariable(ev, "*PRINT-PPRINT-DISPATCH*", try emptyTable(ev));
    try bindVariable(ev, "*PRINT-CIRCLE*", value.NIL);
}

fn bindVariable(ev: *Evaluator, name: []const u8, initial: Value) !void {
    const sym = try ev.interner.intern(name);
    symbol_mod.symbol(sym).special = true;
    if (symbol_mod.symbol(sym).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) {
        symbol_mod.symbol(sym).value_cell = initial;
    }
}

fn variableOf(ev: *Evaluator, name: []const u8) Error!Value {
    const sym = try ev.interner.intern(name);
    return ev.env.lookupValue(sym) orelse value.NIL;
}

// --- the pretty stream ---

fn expectPretty(v: Value) Error!*Stream {
    if (!heap.isStream(v)) return Error.TypeError;
    const s = heap.asStream(v);
    if (s.kind != .pretty) return Error.TypeError;
    return s;
}

/// Record a span of text in the stream's buffer and return where it went.
fn intern(ev: *Evaluator, s: *Stream, text: []const u8) Error!heap.Span {
    const start: u32 = @intCast(s.output.items.len);
    try s.output.appendSlice(ev.heap.storage, text);
    return .{ .start = start, .len = @intCast(text.len) };
}

/// Append text a pretty stream was asked to write.
pub fn recordText(ev: *Evaluator, s: *Stream, text: []const u8) Error!void {
    const span = try intern(ev, s, text);
    try s.tokens.append(ev.heap.storage, .{ .text = .{ .start = span.start, .len = span.len } });
}

fn makePrettyStreamFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    _ = try streams.streamOf(ev, args[0], .output);
    return openPretty(ev, args[0]);
}

/// Lay the recorded tokens out and hand the text to the target stream.
fn finishFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return finish(ev, try expectPretty(args[0]));
}

pub fn finish(ev: *Evaluator, s: *Stream) Error!Value {
    const target = try streams.streamOf(ev, s.target, .output);

    var tokens: std.ArrayList(pretty.Token) = .empty;
    defer tokens.deinit(ev.allocator);
    for (s.tokens.items) |token| {
        try tokens.append(ev.allocator, try resolve(s, token));
    }

    const text = try pretty.layout(ev.allocator, tokens.items, .{
        .right_margin = try marginOf(ev),
        .miser_width = try miserWidthOf(ev),
        .lines = try linesOf(ev),
        .start_column = s.write_position,
    });
    defer ev.allocator.free(text);
    try streams.emitBytes(ev, target, text);
    return value.NIL;
}

fn resolve(s: *Stream, token: heap.PrettyToken) Error!pretty.Token {
    return switch (token) {
        .text => |span| .{ .text = s.output.items[span.start .. span.start + span.len] },
        .newline => |kind| .{ .newline = kind },
        .indent => |request| .{ .indent = .{ .kind = request.kind, .amount = request.amount } },
        .tab => |tab| .{ .tab = .{ .kind = tab.kind, .colnum = tab.colnum, .colinc = tab.colinc } },
        .block_start => |block| .{ .block_start = .{
            .prefix = spanText(s, block.prefix),
            .per_line = spanText(s, block.per_line),
            .suffix = spanText(s, block.suffix),
        } },
        .block_end => .block_end,
    };
}

fn spanText(s: *Stream, span: heap.Span) []const u8 {
    return s.output.items[span.start .. span.start + span.len];
}

fn marginOf(ev: *Evaluator) Error!usize {
    const v = try variableOf(ev, "*PRINT-RIGHT-MARGIN*");
    if (v.isFixnum() and v.toFixnum() > 0) return @intCast(v.toFixnum());
    return 80;
}

fn linesOf(ev: *Evaluator) Error!?usize {
    // What must read back is printed whole.
    if (!(try variableOf(ev, "*PRINT-READABLY*")).equalsRaw(value.NIL)) return null;
    const v = try variableOf(ev, "*PRINT-LINES*");
    if (v.isFixnum() and v.toFixnum() >= 0) return @intCast(v.toFixnum());
    return null;
}

fn miserWidthOf(ev: *Evaluator) Error!?usize {
    const v = try variableOf(ev, "*PRINT-MISER-WIDTH*");
    if (v.isFixnum() and v.toFixnum() >= 0) return @intCast(v.toFixnum());
    return null;
}

// --- blocks, newlines and indentation ---

fn textOf(ev: *Evaluator, v: Value) Error![]const u8 {
    if (v.equalsRaw(value.NIL)) return "";
    if (!heap.isString(v)) return Error.TypeError;
    return heap.stringUtf8Alloc(ev.heap.allocator, v);
}

fn blockStartFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 4) return Error.WrongArgCount;
    const s = try expectPretty(args[0]);
    try blockStart(ev, s, try textOf(ev, args[1]), try textOf(ev, args[2]), try textOf(ev, args[3]));
    return value.NIL;
}

pub fn blockStart(ev: *Evaluator, s: *Stream, prefix_text: []const u8, per_line_text: []const u8, suffix_text: []const u8) Error!void {
    const prefix = try intern(ev, s, prefix_text);
    const per_line = try intern(ev, s, per_line_text);
    const suffix = try intern(ev, s, suffix_text);
    try s.tokens.append(ev.heap.storage, .{ .block_start = .{
        .prefix = prefix,
        .per_line = per_line,
        .suffix = suffix,
    } });
    s.block_depth += 1;
}

fn blockEndFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const s = try expectPretty(args[0]);
    try blockEnd(ev, s, try textOf(ev, args[1]));
    return value.NIL;
}

pub fn blockEnd(ev: *Evaluator, s: *Stream, suffix_text: []const u8) Error!void {
    if (s.block_depth == 0) return Error.ControlError;
    const suffix = try intern(ev, s, suffix_text);
    try s.tokens.append(ev.heap.storage, .{ .text = .{ .start = suffix.start, .len = suffix.len } });
    try s.tokens.append(ev.heap.storage, .{ .block_end = suffix });
    s.block_depth -= 1;
}

/// A newline, indent or tab request does nothing outside a pretty
/// stream, or with `*print-pretty*` off (CLHS `pprint-newline`).
fn prettyTargetOf(ev: *Evaluator, given: ?Value) Error!?*Stream {
    const s = try streams.streamOf(ev, given, .output);
    if (s.kind != .pretty) return null;
    if (!try prettyWanted(ev)) return null;
    return s;
}

const NEWLINE_KINDS = [_][]const u8{ "LINEAR", "FILL", "MISER", "MANDATORY" };

fn newlineKindOf(ev: *Evaluator, v: Value) Error!pretty.NewlineKind {
    inline for (NEWLINE_KINDS, 0..) |name, i| {
        if (v.equalsRaw(try ev.interner.internKeyword(name))) return @fromBackingInt(@intCast(i));
    }
    // The type the kind has to be of, for the condition.
    var held = ev.heap.protect();
    defer held.close();
    try held.push(v);
    var builder = ev.heap.listBuilder();
    try builder.append(try ev.interner.intern("MEMBER"));
    for (NEWLINE_KINDS) |name| try builder.append(try ev.interner.internKeyword(name));
    ev.error_expected = builder.finish();
    ev.error_datum = held.items()[0];
    return Error.TypeError;
}

fn pprintNewlineFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const kind = try newlineKindOf(ev, args[0]);
    const s = try prettyTargetOf(ev, if (args.len == 2) args[1] else null) orelse return value.NIL;
    try s.tokens.append(ev.heap.storage, .{ .newline = kind });
    return value.NIL;
}

/// `(pprint-indent relative-to n &optional stream)`. N is a real, taken
/// as the integer it truncates to.
fn pprintIndentFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    const kind: pretty.IndentKind = if (args[0].equalsRaw(try ev.interner.internKeyword("BLOCK")))
        .block
    else if (args[0].equalsRaw(try ev.interner.internKeyword("CURRENT")))
        .current
    else
        return ev.typeMismatch(args[0], "SYMBOL");
    if (!isReal(args[1])) return ev.typeMismatch(args[1], "REAL");
    const amount: i64 = std.math.lossyCast(i64, @trunc(equality.toF64(args[1])));
    const s = try prettyTargetOf(ev, if (args.len == 3) args[2] else null) orelse return value.NIL;
    try recordIndent(ev, s, kind, amount);
    return value.NIL;
}

fn tabKindOf(v: Value) ?pretty.TabKind {
    if (!v.isSymbol()) return null;
    const n = symbol_mod.symbol(v).name;
    if (std.mem.eql(u8, n, "LINE")) return .line;
    if (std.mem.eql(u8, n, "SECTION")) return .section;
    if (std.mem.eql(u8, n, "LINE-RELATIVE")) return .line_relative;
    if (std.mem.eql(u8, n, "SECTION-RELATIVE")) return .section_relative;
    return null;
}

fn expectCount(ev: *Evaluator, v: Value) Error!u32 {
    if (!v.isFixnum() or v.toFixnum() < 0) return ev.typeMismatch(v, "UNSIGNED-BYTE");
    return std.math.cast(u32, v.toFixnum()) orelse std.math.maxInt(u32);
}

/// `(pprint-tab kind colnum colinc &optional stream)`.
fn pprintTabFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 3 or args.len > 4) return Error.WrongArgCount;
    const kind = tabKindOf(args[0]) orelse return ev.typeMismatch(args[0], "SYMBOL");
    const colnum = try expectCount(ev, args[1]);
    const colinc = try expectCount(ev, args[2]);
    const s = try prettyTargetOf(ev, if (args.len == 4) args[3] else null) orelse return value.NIL;
    try recordTab(ev, s, kind, colnum, colinc);
    return value.NIL;
}

pub fn recordTab(ev: *Evaluator, s: *Stream, kind: pretty.TabKind, colnum: u32, colinc: u32) Error!void {
    try s.tokens.append(ev.heap.storage, .{ .tab = .{ .kind = kind, .colnum = colnum, .colinc = colinc } });
}

pub fn recordNewline(ev: *Evaluator, s: *Stream, kind: pretty.NewlineKind) Error!void {
    try s.tokens.append(ev.heap.storage, .{ .newline = kind });
}

pub fn recordIndent(ev: *Evaluator, s: *Stream, kind: pretty.IndentKind, amount: i64) Error!void {
    try s.tokens.append(ev.heap.storage, .{ .indent = .{ .kind = kind, .amount = amount } });
}

// --- logical blocks ---

/// `(%pprint-open stream object prefix per-line-prefix suffix)` opens a
/// logical block for OBJECT on STREAM, which is given a pretty stream of
/// its own unless it is one. Returns that stream and whether it is new,
/// or NIL where the block stands in as `#` past `*print-level*` or as the
/// `#n#` of an object already printed.
fn pprintOpenFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 5) return Error.WrongArgCount;
    const given = try streams.streamOf(ev, args[0], .output);
    var held = ev.heap.protect();
    defer held.close();
    const fresh = given.kind != .pretty;
    try held.push(if (fresh) try openPretty(ev, Value.fromHeapAddr(@intFromPtr(given))) else Value.fromHeapAddr(@intFromPtr(given)));
    const s = heap.asStream(held.items()[0]);
    if (fresh) try attachCircle(ev, s, args[1]);
    if (try levelExceeded(ev, s)) {
        try recordText(ev, s, "#");
        if (fresh) _ = try finish(ev, s);
        return ev.setValues(&.{ value.NIL, value.NIL });
    }
    if (s.circle) |state| {
        if (state.get(args[1])) |label| {
            const id = state.assign(label);
            var buf: [24]u8 = undefined;
            if (label.printed) {
                try recordText(ev, s, std.fmt.bufPrint(&buf, "#{d}#", .{id}) catch unreachable);
                if (fresh) _ = try finish(ev, s);
                return ev.setValues(&.{ value.NIL, value.NIL });
            }
            label.printed = true;
            try recordText(ev, s, std.fmt.bufPrint(&buf, "#{d}=", .{id}) catch unreachable);
        }
    }
    _ = try blockStartFn(p, &.{ held.items()[0], args[2], args[3], args[4] });
    return ev.setValues(&.{ held.items()[0], if (fresh) value.T else value.NIL });
}

/// Whether a block opened at this depth is past `*print-level*`.
pub fn levelExceeded(ev: *Evaluator, s: *Stream) Error!bool {
    if (!(try variableOf(ev, "*PRINT-READABLY*")).equalsRaw(value.NIL)) return false;
    const level = try variableOf(ev, "*PRINT-LEVEL*");
    if (!level.isFixnum()) return false;
    return s.block_depth >= level.toFixnum();
}

/// `(%pprint-close stream suffix fresh)` ends the block, and lays a
/// fresh pretty stream out onto the stream it was made for.
fn pprintCloseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    const s = try expectPretty(args[0]);
    _ = try blockEndFn(p, args[0..2]);
    if (!args[2].equalsRaw(value.NIL)) _ = try finish(ev, s);
    return value.NIL;
}

/// Whether `*print-circle*` labels OBJECT in the block STREAM is laying
/// out, which makes a tail a back-reference.
fn pprintSharedFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!heap.isStream(args[0])) return value.NIL;
    const state = heap.asStream(args[0]).circle orelse return value.NIL;
    return if (state.get(args[1]) != null) value.T else value.NIL;
}

// --- printing a list ---

const ListStyle = enum { linear, fill };

/// A pretty stream that lays itself out onto `target` when it finishes.
pub fn openPretty(ev: *Evaluator, target: Value) Error!Value {
    var stream = streams.emptyStream(.pretty, .output);
    stream.target = target;
    // Where the layout starts, which the first line's room is counted
    // from.
    stream.write_position = try columnOf(ev, try streams.streamOf(ev, target, .output));
    return ev.heap.allocStream(stream);
}

/// The column a stream's output has reached.
pub fn columnOf(ev: *Evaluator, s: *Stream) Error!usize {
    if (s.kind == .console) return ev.output_column;
    if (s.kind == .pretty) return 0;
    const written = s.output.items[0..@min(s.write_position, s.output.items.len)];
    const line = if (std.mem.lastIndexOfScalar(u8, written, '\n')) |at| written[at + 1 ..] else written;
    var n: usize = 0;
    for (line) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

fn printList(
    ev: *Evaluator,
    s: *Stream,
    list: Value,
    style: ListStyle,
    parens: bool,
) Error!void {
    const allocator = ev.heap.storage;
    const open = try intern(ev, s, if (parens) "(" else "");
    const empty = try intern(ev, s, "");
    try s.tokens.append(allocator, .{ .block_start = .{
        .prefix = open,
        .per_line = empty,
        .suffix = empty,
    } });

    var rest = list;
    var first = true;
    while (rest.isCons()) {
        // A labeled tail is a back-reference, which has to be written
        // after a dot rather than walked into.
        const labeled = if (s.circle) |state| !first and state.get(rest) != null else false;
        if (labeled) break;
        if (!first) {
            try recordText(ev, s, " ");
            try s.tokens.append(allocator, .{
                .newline = if (style == .fill) .fill else .linear,
            });
        }
        try recordValue(ev, s, heap.car(rest));
        first = false;
        rest = heap.cdr(rest);
    }
    if (!rest.equalsRaw(value.NIL)) {
        try recordText(ev, s, " . ");
        try recordValue(ev, s, rest);
    }
    if (parens) try recordText(ev, s, ")");
    try s.tokens.append(allocator, .{ .block_end = empty });
}

/// One element, laid out as a block of its own when it is a list. A
/// dispatch entry for the object's type takes over when one matches.
fn recordValue(ev: *Evaluator, s: *Stream, v: Value) Error!void {
    if (try dispatchFor(ev, v)) |handler| {
        const stream_value = Value.fromHeapAddr(@intFromPtr(s));
        _ = try ev.callFunction(handler, &.{ stream_value, v });
        return;
    }
    if (s.circle) |state| {
        if (state.get(v)) |label| {
            const id = state.assign(label);
            var buf: [16]u8 = undefined;
            if (label.printed) {
                const text = std.fmt.bufPrint(&buf, "#{d}#", .{id}) catch unreachable;
                return recordText(ev, s, text);
            }
            label.printed = true;
            const text = std.fmt.bufPrint(&buf, "#{d}=", .{id}) catch unreachable;
            try recordText(ev, s, text);
        }
    }
    if (v.isCons()) return printList(ev, s, v, .linear, true);
    var settings = format.writeSettings(ev);
    settings.circle = s.circle;
    const text = printer.writeToOwnedSlice(ev.allocator, v, settings) catch |e| return ev.printFailure(e);
    defer ev.allocator.free(text);
    try recordText(ev, s, text);
}

/// Give a pretty stream the labels for the object it is about to lay out.
fn attachCircle(ev: *Evaluator, s: *Stream, v: Value) Error!void {
    if (!format.circleWanted(ev)) return;
    const state = try ev.heap.storage.create(circle_mod.State);
    state.* = try circle_mod.scanLimited(ev.heap.storage, v, format.circleLimits(ev));
    s.circle = state;
}

/// The dispatch function for `v`, or null when no entry matches. An entry
/// whose function is nil turns dispatch off for that type.
fn dispatchFor(ev: *Evaluator, v: Value) Error!?Value {
    return lookupDispatch(ev, v, try variableOf(ev, "*PRINT-PPRINT-DISPATCH*"));
}

/// The function of the matching entry with the highest priority, the
/// most recently set among equals, resolved from a symbol when it names
/// one.
fn lookupDispatch(ev: *Evaluator, v: Value, table: Value) Error!?Value {
    const types = @import("types.zig");
    var best: ?Value = null;
    var best_priority: f64 = 0;
    var rest = table;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const entry = heap.car(rest);
        if (!entry.isCons() or !heap.cdr(entry).isCons()) continue;
        const spec = heap.car(entry);
        const handler = heap.car(heap.cdr(entry));
        const tail = heap.cdr(heap.cdr(entry));
        const priority = if (tail.isCons()) equality.toF64(heap.car(tail)) else 0;
        if (best != null and priority <= best_priority) continue;
        if (!(types.typep(ev, v, spec) catch false)) continue;
        best = handler;
        best_priority = priority;
    }
    const handler = best orelse return null;
    if (handler.isSymbol()) return ev.env.lookupFunction(handler);
    return handler;
}

fn pprintFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const stream = if (args.len == 2) args[1] else value.NIL;
    // `pprint` is `write` with escaping and pretty printing on, after a
    // newline that puts the object on a line of its own.
    try streams.emitBytes(ev, try streams.streamOf(ev, stream, .output), "\n");
    const mark = ev.dynamicMark();
    defer ev.unwindSpecials(mark);
    try ev.bindSpecial(try ev.interner.intern("*PRINT-PRETTY*"), value.T);
    try writeValue(ev, args[0], stream, .escape);
    return ev.setValues(&.{});
}

// --- the dispatch table ---

/// A dispatch table is a list headed by `%PPRINT-DISPATCH-TABLE`, so it
/// can be changed in place, followed by `(type-specifier function
/// priority)` entries, most recently set first. A lookup passes over the
/// head, which is not an entry.
fn isReal(v: Value) bool {
    if (v.isFixnum() or v.isSingleFloat()) return true;
    if (v.tag() != .heap) return false;
    return switch (heap.heapType(v)) {
        .bignum, .ratio, .double_float => true,
        else => false,
    };
}

fn emptyTable(ev: *Evaluator) Error!Value {
    return ev.heap.list(&.{try ev.interner.intern("%PPRINT-DISPATCH-TABLE")});
}

fn isTable(ev: *Evaluator, v: Value) Error!bool {
    return v.isCons() and heap.car(v).equalsRaw(try ev.interner.intern("%PPRINT-DISPATCH-TABLE"));
}

fn expectTable(ev: *Evaluator, v: Value) Error!Value {
    if (try isTable(ev, v)) return v;
    var held = ev.heap.protect();
    defer held.close();
    try held.push(v);
    ev.error_expected = try ev.heap.list(&.{ try ev.interner.intern("SATISFIES"), try ev.interner.intern("%PPRINT-DISPATCH-TABLE-P") });
    ev.error_datum = held.items()[0];
    return Error.TypeError;
}

fn tablePFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return if (try isTable(ev, args[0])) value.T else value.NIL;
}

fn setPprintDispatchFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 4) return Error.WrongArgCount;
    const priority = if (args.len >= 3) args[2] else Value.fromFixnum(0);
    if (!isReal(priority)) return ev.typeMismatch(priority, "REAL");
    if (!(args[1].isSymbol() or function.isFunction(args[1]))) return ev.typeMismatch(args[1], "FUNCTION");
    const table = try expectTable(ev, if (args.len == 4) args[3] else try variableOf(ev, "*PRINT-PPRINT-DISPATCH*"));

    // An entry for the same type is replaced, and a NIL function removes it.
    var previous = table;
    while (heap.cdr(previous).isCons()) {
        const entry = heap.car(heap.cdr(previous));
        if (equality.equal(heap.car(entry), args[0])) {
            heap.setCdr(ev.heap, previous, heap.cdr(heap.cdr(previous)));
        } else {
            previous = heap.cdr(previous);
        }
    }
    if (args[1].equalsRaw(value.NIL)) return value.NIL;
    var held = ev.heap.protect();
    defer held.close();
    try held.push(table);
    const entry = try ev.heap.list(&.{ args[0], args[1], priority });
    heap.setCdr(ev.heap, table, try ev.heap.allocCons(entry, heap.cdr(table)));
    return value.NIL;
}

/// A fresh table holding what `from` holds: the current table when it is
/// missing, and none of the program's entries when it is NIL.
fn copyPprintDispatchFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    const from = if (args.len == 0) try variableOf(ev, "*PRINT-PPRINT-DISPATCH*") else args[0];
    if (from.equalsRaw(value.NIL)) return emptyTable(ev);
    const source = try expectTable(ev, from);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(source);
    var builder = ev.heap.listBuilder();
    var rest = source;
    while (rest.isCons()) : (rest = heap.cdr(rest)) try builder.append(heap.car(rest));
    return builder.finish();
}

/// The function a table would use for an object, and whether one matched.
/// An entry whose function is nil says "print this type the ordinary
/// way", so it reports no match.
fn pprintDispatchFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const table = if (args.len == 2 and !args[1].equalsRaw(value.NIL))
        args[1]
    else
        try variableOf(ev, "*PRINT-PPRINT-DISPATCH*");

    const handler = try lookupDispatch(ev, args[0], table) orelse
        return ev.setValues(&.{ value.NIL, value.NIL });
    return ev.setValues(&.{ handler, value.T });
}

// --- the printing operations ---

/// How a printing operation escapes: always, never, or as
/// `*print-escape*` says.
pub const WriteStyle = enum { escape, plain, current };

/// Whether printing should lay a list out rather than run it flat.
fn prettyWanted(ev: *Evaluator) Error!bool {
    return !(try variableOf(ev, "*PRINT-PRETTY*")).equalsRaw(value.NIL);
}

/// Print `v` to `stream` the way `style` says: `princ` binds
/// `*print-escape*` and `*print-readably*` off and `prin1` binds
/// `*print-escape*` on, so everything printed inside, a dispatch
/// function or a pretty layout included, sees the same settings.
pub fn writeValue(ev: *Evaluator, v: Value, stream: Value, comptime style: WriteStyle) Error!void {
    const mark = ev.dynamicMark();
    defer ev.unwindSpecials(mark);
    switch (style) {
        .plain => {
            try ev.bindSpecial(try ev.interner.intern("*PRINT-ESCAPE*"), value.NIL);
            try ev.bindSpecial(try ev.interner.intern("*PRINT-READABLY*"), value.NIL);
        },
        .escape => try ev.bindSpecial(try ev.interner.intern("*PRINT-ESCAPE*"), value.T),
        .current => {},
    }
    const target = try streams.streamOf(ev, stream, .output);
    if (try prettyWanted(ev)) {
        if (!v.isCons()) {
            if (try dispatchFor(ev, v)) |handler| {
                _ = try ev.callFunction(handler, &.{ Value.fromHeapAddr(@intFromPtr(target)), v });
                return;
            }
        } else {
            if (target.kind == .pretty) return recordValue(ev, target, v);
            const wrapper = try openPretty(ev, stream);
            try attachCircle(ev, heap.asStream(wrapper), v);
            try recordValue(ev, heap.asStream(wrapper), v);
            _ = try finish(ev, heap.asStream(wrapper));
            return;
        }
    }
    var settings = format.writeSettings(ev);
    if (!settings.escape) {
        var arena = std.heap.ArenaAllocator.init(ev.allocator);
        defer arena.deinit();
        if (try format.reportText(ev, arena.allocator(), v)) |text| {
            return streams.emitBytes(ev, target, text);
        }
    }
    var state: ?circle_mod.State = null;
    defer if (state) |*owned| owned.deinit(ev.allocator);
    if (format.circleWanted(ev)) {
        state = try circle_mod.scanLimited(ev.allocator, v, format.circleLimits(ev));
        settings.circle = &state.?;
    }
    const text = printer.writeToOwnedSlice(ev.allocator, v, settings) catch |e| return ev.printFailure(e);
    defer ev.allocator.free(text);
    try streams.emitBytes(ev, target, text);
}

fn writerFn(comptime style: WriteStyle) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
            const stream = if (args.len >= 2) args[1] else value.NIL;
            try writeValue(ev, args[0], stream, style);
            return args[0];
        }
    }.f;
}

/// `print` puts its object on a line of its own and follows it with a
/// space, which is what distinguishes it from `prin1`.
fn printFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const stream = if (args.len == 2) args[1] else value.NIL;
    const target = try streams.streamOf(ev, stream, .output);
    try streams.emitBytes(ev, target, "\n");
    try writeValue(ev, args[0], stream, .escape);
    try streams.emitBytes(ev, target, " ");
    return args[0];
}

fn terpriFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    const target = try streams.streamOf(ev, if (args.len == 1) args[0] else null, .output);
    try streams.emitBytes(ev, target, "\n");
    return value.NIL;
}

/// A newline only when the line has something on it already.
fn freshLineFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    const target = try streams.streamOf(ev, if (args.len == 1) args[0] else null, .output);
    if (atLineStart(ev, target)) return value.NIL;
    try streams.emitBytes(ev, target, "\n");
    return value.T;
}

fn atLineStart(ev: *Evaluator, s: *Stream) bool {
    if (s.kind == .console) return ev.output_column == 0;
    if (s.output.items.len == 0) return true;
    return s.output.items[s.output.items.len - 1] == '\n';
}
