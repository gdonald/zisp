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
    _ = try ev.defineNative("PPRINT", &pprintFn);
    _ = try ev.defineNative("PRIN1", writerFn(.escape));
    _ = try ev.defineNative("PRINC", writerFn(.plain));
    _ = try ev.defineNative("WRITE", writerFn(.escape));
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
    _ = try ev.defineNative("PPRINT-FILL", listPrinter(.fill));
    _ = try ev.defineNative("PPRINT-LINEAR", listPrinter(.linear));
    _ = try ev.defineNative("PPRINT-TABULAR", listPrinter(.fill));
    _ = try ev.defineNative("SET-PPRINT-DISPATCH", &setPprintDispatchFn);
    _ = try ev.defineNative("COPY-PPRINT-DISPATCH", &copyPprintDispatchFn);
    function.asFunction(try ev.defineNative("PPRINT-DISPATCH", &pprintDispatchFn))
        .preserves_values = true;

    try bindVariable(ev, "*PRINT-PRETTY*", value.NIL);
    try bindVariable(ev, "*PRINT-RIGHT-MARGIN*", value.NIL);
    try bindVariable(ev, "*PRINT-MISER-WIDTH*", value.NIL);
    try bindVariable(ev, "*PRINT-PPRINT-DISPATCH*", value.NIL);
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
    try s.output.appendSlice(ev.heap.allocator, text);
    return .{ .start = start, .len = @intCast(text.len) };
}

/// Append text a pretty stream was asked to write.
pub fn recordText(ev: *Evaluator, s: *Stream, text: []const u8) Error!void {
    const span = try intern(ev, s, text);
    try s.tokens.append(ev.heap.allocator, .{ .text = .{ .start = span.start, .len = span.len } });
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

fn finish(ev: *Evaluator, s: *Stream) Error!Value {
    const target = try streams.streamOf(ev, s.target, .output);

    var tokens: std.ArrayList(pretty.Token) = .empty;
    defer tokens.deinit(ev.allocator);
    for (s.tokens.items) |token| {
        try tokens.append(ev.allocator, try resolve(s, token));
    }

    const text = try pretty.layout(ev.allocator, tokens.items, .{
        .right_margin = try marginOf(ev),
        .miser_width = try miserWidthOf(ev),
        .start_column = if (target.kind == .console) ev.output_column else 0,
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
    const prefix = try intern(ev, s, try textOf(ev, args[1]));
    const per_line = try intern(ev, s, try textOf(ev, args[2]));
    const suffix = try intern(ev, s, try textOf(ev, args[3]));
    try s.tokens.append(ev.heap.allocator, .{ .block_start = .{
        .prefix = prefix,
        .per_line = per_line,
        .suffix = suffix,
    } });
    s.block_depth += 1;
    return value.NIL;
}

fn blockEndFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const s = try expectPretty(args[0]);
    if (s.block_depth == 0) return Error.ControlError;
    const suffix = try intern(ev, s, try textOf(ev, args[1]));
    try s.tokens.append(ev.heap.allocator, .{ .text = .{ .start = suffix.start, .len = suffix.len } });
    try s.tokens.append(ev.heap.allocator, .{ .block_end = suffix });
    s.block_depth -= 1;
    return value.NIL;
}

/// A newline or indent request outside a pretty stream does nothing,
/// which is what CLHS says about a stream that is not pretty.
fn prettyTargetOf(ev: *Evaluator, given: ?Value) Error!?*Stream {
    const s = try streams.streamOf(ev, given, .output);
    if (s.kind != .pretty) return null;
    return s;
}

fn newlineKindOf(ev: *Evaluator, v: Value) Error!pretty.NewlineKind {
    if (!v.isSymbol()) return Error.TypeError;
    const n = symbol_mod.symbol(v).name;
    if (std.mem.eql(u8, n, "LINEAR")) return .linear;
    if (std.mem.eql(u8, n, "FILL")) return .fill;
    if (std.mem.eql(u8, n, "MISER")) return .miser;
    if (std.mem.eql(u8, n, "MANDATORY")) return .mandatory;
    _ = ev;
    return Error.TypeError;
}

fn pprintNewlineFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const kind = try newlineKindOf(ev, args[0]);
    const s = try prettyTargetOf(ev, if (args.len == 2) args[1] else null) orelse return value.NIL;
    try s.tokens.append(ev.heap.allocator, .{ .newline = kind });
    return value.NIL;
}

fn pprintIndentFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const name = symbol_mod.symbol(args[0]).name;
    const kind: pretty.IndentKind = if (std.mem.eql(u8, name, "BLOCK"))
        .block
    else if (std.mem.eql(u8, name, "CURRENT"))
        .current
    else
        return Error.TypeError;
    if (!args[1].isFixnum()) return Error.TypeError;
    const s = try prettyTargetOf(ev, if (args.len == 3) args[2] else null) orelse return value.NIL;
    try s.tokens.append(ev.heap.allocator, .{
        .indent = .{ .kind = kind, .amount = args[1].toFixnum() },
    });
    return value.NIL;
}

/// `pprint-tab` moves to a column. Only the section-relative forms differ
/// from the line-relative ones once a block has an indent, and both land
/// on an indent request here.
fn pprintTabFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 3 or args.len > 4) return Error.WrongArgCount;
    if (!args[1].isFixnum() or !args[2].isFixnum()) return Error.TypeError;
    const s = try prettyTargetOf(ev, if (args.len == 4) args[3] else null) orelse return value.NIL;
    try s.tokens.append(ev.heap.allocator, .{
        .indent = .{ .kind = .block, .amount = args[1].toFixnum() },
    });
    return value.NIL;
}

// --- printing a list ---

const ListStyle = enum { linear, fill };

fn listPrinter(comptime style: ListStyle) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len < 2) return Error.WrongArgCount;
            // Writing onto a stream that is already pretty joins its
            // layout; any other stream gets one of its own.
            if (try prettyTargetOf(ev, args[0])) |s| {
                try printList(ev, s, args[1], style);
                return value.NIL;
            }
            const wrapper = try openPretty(ev, args[0]);
            try attachCircle(ev, heap.asStream(wrapper), args[1]);
            try printList(ev, heap.asStream(wrapper), args[1], style);
            return finishFn(p, &.{wrapper});
        }
    }.f;
}

/// A pretty stream that lays itself out onto `target` when it finishes.
fn openPretty(ev: *Evaluator, target: Value) Error!Value {
    var stream = streams.emptyStream(.pretty, .output);
    stream.target = target;
    return ev.heap.allocStream(stream);
}

fn printList(ev: *Evaluator, s: *Stream, list: Value, style: ListStyle) Error!void {
    const allocator = ev.heap.allocator;
    const open = try intern(ev, s, "(");
    const empty = try intern(ev, s, "");
    try s.tokens.append(allocator, .{ .block_start = .{
        .prefix = open,
        .per_line = empty,
        .suffix = empty,
    } });

    var rest = list;
    var first = true;
    while (rest.isCons()) {
        // A labelled tail is a back-reference, which has to be written
        // after a dot rather than walked into.
        const labelled = if (s.circle) |state| !first and state.get(rest) != null else false;
        if (labelled) break;
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
    try recordText(ev, s, ")");
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
    if (v.isCons()) return printList(ev, s, v, .linear);
    var settings = format.prin1Settings(ev);
    settings.circle = s.circle;
    const text = try printer.writeToOwnedSlice(ev.allocator, v, settings);
    defer ev.allocator.free(text);
    try recordText(ev, s, text);
}

/// Give a pretty stream the labels for the object it is about to lay out.
fn attachCircle(ev: *Evaluator, s: *Stream, v: Value) Error!void {
    if (!format.circleWanted(ev)) return;
    const state = try ev.heap.allocator.create(circle_mod.State);
    state.* = try circle_mod.scan(ev.heap.allocator, v);
    s.circle = state;
}

/// The dispatch function for `v`, or null when no entry matches. An entry
/// whose function is nil turns dispatch off for that type.
fn dispatchFor(ev: *Evaluator, v: Value) Error!?Value {
    return lookupDispatch(ev, v, try variableOf(ev, "*PRINT-PPRINT-DISPATCH*"));
}

fn lookupDispatch(ev: *Evaluator, v: Value, table: Value) Error!?Value {
    const types = @import("types.zig");
    var rest = table;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const entry = heap.car(rest);
        if (!entry.isCons() or !heap.cdr(entry).isCons()) continue;
        const spec = heap.car(entry);
        const handler = heap.car(heap.cdr(entry));
        if (!(types.typep(ev, v, spec) catch false)) continue;
        if (handler.equalsRaw(value.NIL)) return null;
        return handler;
    }
    return null;
}

fn pprintFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const target = try streams.streamOf(ev, if (args.len == 2) args[1] else null, .output);

    _ = target;
    const pretty_value = try openPretty(ev, if (args.len == 2) args[1] else value.NIL);
    const s = heap.asStream(pretty_value);
    try attachCircle(ev, s, args[0]);
    // `pprint` starts on a line of its own.
    try recordText(ev, s, "\n");
    try recordValue(ev, s, args[0]);
    return finishFn(p, &.{pretty_value});
}

// --- the dispatch table ---

/// A dispatch table is a list of `(type-specifier function priority)`
/// entries, most recently set first.
fn setPprintDispatchFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 4) return Error.WrongArgCount;
    const table_sym = try ev.interner.intern("*PRINT-PPRINT-DISPATCH*");
    const priority = if (args.len >= 3) args[2] else Value.fromFixnum(0);
    const current = ev.env.lookupValue(table_sym) orelse value.NIL;

    var held = ev.heap.protect();
    defer held.close();
    try held.push(current);
    const entry = try ev.heap.list(&.{ args[0], args[1], priority });
    try held.push(entry);
    symbol_mod.symbol(table_sym).value_cell = try ev.heap.listWithTail(&.{entry}, current);
    return value.NIL;
}

fn copyPprintDispatchFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    if (args.len == 1 and !args[0].equalsRaw(value.NIL)) return args[0];
    return variableOf(ev, "*PRINT-PPRINT-DISPATCH*");
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

const WriteStyle = enum { escape, plain };

/// Whether printing should lay a list out rather than run it flat.
fn prettyWanted(ev: *Evaluator) Error!bool {
    return !(try variableOf(ev, "*PRINT-PRETTY*")).equalsRaw(value.NIL);
}

fn writeValue(ev: *Evaluator, v: Value, stream: Value, comptime style: WriteStyle) Error!void {
    const target = try streams.streamOf(ev, stream, .output);
    if (style == .escape and v.isCons() and try prettyWanted(ev)) {
        if (target.kind == .pretty) {
            try recordValue(ev, target, v);
            return;
        }
        const wrapper = try openPretty(ev, stream);
        try attachCircle(ev, heap.asStream(wrapper), v);
        try recordValue(ev, heap.asStream(wrapper), v);
        _ = try finish(ev, heap.asStream(wrapper));
        return;
    }
    var settings = if (style == .escape) format.prin1Settings(ev) else format.princSettings(ev);
    var state: ?circle_mod.State = null;
    defer if (state) |*owned| owned.deinit(ev.allocator);
    if (format.circleWanted(ev)) {
        state = try circle_mod.scan(ev.allocator, v);
        settings.circle = &state.?;
    }
    const text = try printer.writeToOwnedSlice(ev.allocator, v, settings);
    defer ev.allocator.free(text);
    try streams.emitBytes(ev, target, text);
}

fn writerFn(comptime style: WriteStyle) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len < 1) return Error.WrongArgCount;
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
