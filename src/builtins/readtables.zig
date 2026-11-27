//! The reader as Lisp sees it: readtables, macro characters, and the
//! functions that read.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const reader_mod = @import("../reader.zig");
const streams = @import("streams.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const Reader = reader_mod.Reader;
const Source = reader_mod.Source;
const table_mod = reader_mod.readtable;
const Builtin = table_mod.Builtin;

pub const VARIABLE = "*READTABLE*";

pub fn registerReadtables(ev: *Evaluator) !void {
    _ = try ev.defineNative("COPY-READTABLE", &copyReadtableFn);
    _ = try ev.defineNative("READTABLEP", &readtablepFn);
    _ = try ev.defineNative("READTABLE-CASE", &readtableCaseFn);
    _ = try ev.defineNative("%SET-READTABLE-CASE", &setReadtableCaseFn);
    _ = try ev.defineNative("SET-MACRO-CHARACTER", &setMacroCharacterFn);
    function.asFunction(try ev.defineNative("GET-MACRO-CHARACTER", &getMacroCharacterFn))
        .preserves_values = true;
    _ = try ev.defineNative("MAKE-DISPATCH-MACRO-CHARACTER", &makeDispatchMacroCharacterFn);
    _ = try ev.defineNative("SET-DISPATCH-MACRO-CHARACTER", &setDispatchMacroCharacterFn);
    _ = try ev.defineNative("GET-DISPATCH-MACRO-CHARACTER", &getDispatchMacroCharacterFn);
    _ = try ev.defineNative("SET-SYNTAX-FROM-CHAR", &setSyntaxFromCharFn);

    _ = try ev.defineNative("READ", readFn(false));
    _ = try ev.defineNative("READ-PRESERVING-WHITESPACE", readFn(true));
    function.asFunction(try ev.defineNative("READ-FROM-STRING", &readFromStringFn))
        .preserves_values = true;
    _ = try ev.defineNative("READ-DELIMITED-LIST", &readDelimitedListFn);

    inline for (@typeInfo(Builtin).@"enum".field_values) |field_value| {
        const which: Builtin = @fromBackingInt(@intCast(field_value));
        function.asFunction(try ev.defineNative(builtinName(which), builtinFn(which)))
            .preserves_values = true;
    }

    const sym = symbol_mod.symbol(try ev.interner.intern(VARIABLE));
    sym.value_cell = try allocStandard(ev);
    sym.special = true;
}

fn allocStandard(ev: *Evaluator) Error!Value {
    return ev.heap.allocReadtable(try table_mod.standard(ev.heap), 0);
}

/// The readtable `*readtable*` names, or null when it names something
/// else.
pub fn active(ev: *Evaluator) ?*heap.HeapReadtable {
    const found = ev.interner.cl.findPresent(VARIABLE) orelse return null;
    const bound = symbol_mod.symbol(found.sym).value_cell;
    if (!heap.isReadtable(bound)) return null;
    return heap.asReadtable(bound);
}

/// Point a fresh reader at the active readtable and its case, at the
/// float format `*read-default-float-format*` names, and at this
/// evaluator for what it calls.
pub fn install(ev: *Evaluator, rd: *Reader) void {
    rd.default_float = defaultFloat(ev);
    rd.host = host(ev);
    const rt = active(ev) orelse return;
    rd.table = rt.table;
    rd.own_table = false;
    rd.case = @fromBackingInt(@intCast(rt.case));
}

pub fn host(ev: *Evaluator) reader_mod.Host {
    return .{ .context = @ptrCast(ev), .eval = &hostEval, .call = &hostCall, .openStream = &hostOpenStream };
}

fn hostEval(context: *anyopaque, form: Value) Error!Value {
    return Evaluator.fromOpaque(context).eval(form);
}

fn hostCall(context: *anyopaque, f: Value, args: []const Value) Error!?Value {
    const ev = Evaluator.fromOpaque(context);
    const callee = if (f.isSymbol()) symbol_mod.symbol(f).function_cell else f;
    const result = try ev.callFunction(callee, args);
    if (ev.values.items.len == 0) return null;
    return result;
}

fn hostOpenStream(context: *anyopaque, bytes: []const u8) Error!Value {
    const ev = Evaluator.fromOpaque(context);
    var stream = streams.emptyStream(.string, .input);
    stream.input = try ev.heap.allocator.dupe(u8, bytes);
    return ev.heap.allocStream(stream);
}

fn defaultFloat(ev: *Evaluator) reader_mod.FloatType {
    const found = ev.interner.cl.findPresent("*READ-DEFAULT-FLOAT-FORMAT*") orelse return .single;
    const format = symbol_mod.symbol(found.sym).value_cell;
    if (!format.isSymbol()) return .single;
    const name = symbol_mod.symbol(format).name;
    if (std.mem.eql(u8, name, "DOUBLE-FLOAT") or std.mem.eql(u8, name, "LONG-FLOAT")) return .double;
    return .single;
}

/// What a failure the reader returned is as a native failure.
pub fn failure(err: reader_mod.ReaderError) Error {
    return switch (err) {
        error.EndOfInput => Error.EndOfFile,
        error.BadToken, error.UnbalancedParens, error.NoSuchPackage, error.SymbolNotExternal => Error.ReaderError,
        else => |e| e,
    };
}

/// `failure`, recording the stream that was being read for the condition
/// that stands for it. A reader with no stream of its own is given one
/// over its text.
fn failureOf(ev: *Evaluator, rd: *Reader, err: reader_mod.ReaderError) Error {
    const native = failure(err);
    if (native != Error.EndOfFile and native != Error.ReaderError) return native;
    const stream = rd.stream orelse hostOpenStream(@ptrCast(ev), rd.source.src) catch |e| return e;
    ev.error_stream = stream;
    return native;
}

// --- readtables ------------------------------------------------------

fn expectReadtable(ev: *Evaluator, v: Value) Error!*heap.HeapReadtable {
    if (!heap.isReadtable(v)) return ev.typeMismatch(v, "READTABLE");
    return heap.asReadtable(v);
}

/// The readtable an optional argument names: `*readtable*` when it is
/// missing, and when it is NIL the standard one if `nil_is_standard`.
fn readtableArg(ev: *Evaluator, args: []const Value, index: usize, nil_is_standard: bool) Error!*heap.HeapReadtable {
    if (args.len > index) {
        const given = args[index];
        if (!given.equalsRaw(value.NIL)) return expectReadtable(ev, given);
        if (nil_is_standard) return heap.asReadtable(try allocStandard(ev));
    }
    return active(ev) orelse ev.typeMismatch(value.NIL, "READTABLE");
}

fn copyReadtableFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len > 2) return Error.WrongArgCount;
    const from = try readtableArg(ev, args, 0, true);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(Value.fromHeapAddr(@intFromPtr(from)));
    if (args.len == 2 and !args[1].equalsRaw(value.NIL)) {
        const into = try expectReadtable(ev, args[1]);
        try table_mod.copyInto(ev.heap, from.table, into.table);
        into.case = from.case;
        return ev.set1(args[1]);
    }
    const table = try table_mod.copy(ev.heap, from.table);
    return ev.set1(try ev.heap.allocReadtable(table, heap.asReadtable(held.items()[0]).case));
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
    const rt = try expectReadtable(ev, args[0]);
    return ev.set1(try ev.interner.internKeyword(CASE_NAMES[@intCast(rt.case)]));
}

fn setReadtableCaseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len != 2) return Error.WrongArgCount;
    const rt = try expectReadtable(ev, args[0]);
    for (CASE_NAMES, 0..) |candidate, index| {
        if (args[1].equalsRaw(try ev.interner.internKeyword(candidate))) {
            rt.case = index;
            return ev.set1(args[1]);
        }
    }
    var held = ev.heap.protect();
    defer held.close();
    try held.push(args[1]);
    var builder = ev.heap.listBuilder();
    try builder.append(try ev.interner.intern("MEMBER"));
    for (CASE_NAMES) |name| try builder.append(try ev.interner.internKeyword(name));
    ev.error_expected = builder.finish();
    ev.error_datum = held.items()[0];
    return Error.TypeError;
}

// --- macro characters ------------------------------------------------

fn expectChar(ev: *Evaluator, v: Value) Error!u21 {
    if (v.tag() != .char) return ev.typeMismatch(v, "CHARACTER");
    return v.toChar();
}

fn builtinName(comptime which: Builtin) []const u8 {
    const name = comptime blk: {
        var text: []const u8 = "%READER-";
        for (@tagName(which)) |c| text = text ++ &[_]u8{if (c == '_') '-' else std.ascii.toUpper(c)};
        break :blk text;
    };
    return name;
}

/// The function `get-macro-character` hands out for one of the reader's
/// own macros. Calling it reads from the stream it is given as the
/// reader would have.
fn builtinFn(comptime which: Builtin) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = Evaluator.fromOpaque(p);
            if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
            const char = try expectChar(ev, args[1]);
            const arg: ?Value = if (args.len == 3 and !args[2].equalsRaw(value.NIL)) args[2] else null;
            var source: Source = undefined;
            var rd = try onStream(ev, args[0], &source);
            rd.recursive = true;
            const result = rd.runBuiltin(which, char, arg) catch |e| {
                finishOnStream(&rd);
                return failureOf(ev, &rd, e);
            };
            finishOnStream(&rd);
            if (result) |v| return ev.set1(v);
            return ev.setValues(&.{});
        }
    }.f;
}

/// What a readtable holds for `f`: one of the reader's own macros when
/// `f` is the function standing for it.
fn stored(ev: *Evaluator, f: Value) Value {
    inline for (@typeInfo(Builtin).@"enum".field_values) |field_value| {
        const which: Builtin = @fromBackingInt(@intCast(field_value));
        if (ev.interner.cl.findPresent(builtinName(which))) |found| {
            if (symbol_mod.symbol(found.sym).function_cell.equalsRaw(f)) return table_mod.builtinValue(which);
        }
    }
    return f;
}

/// The function a readtable entry stands for, as `get-macro-character`
/// returns it.
fn handedOut(ev: *Evaluator, f: Value) Value {
    const which = table_mod.asBuiltin(f) orelse return f;
    inline for (@typeInfo(Builtin).@"enum".field_values) |field_value| {
        if (field_value == @backingInt(which)) {
            const found = ev.interner.cl.findPresent(builtinName(@fromBackingInt(@intCast(field_value)))) orelse return value.NIL;
            return symbol_mod.symbol(found.sym).function_cell;
        }
    }
    return value.NIL;
}

fn expectFunctionDesignator(ev: *Evaluator, f: Value) Error!void {
    if (function.isFunction(f) or (f.isSymbol() and !f.equalsRaw(value.NIL))) return;
    return ev.typeMismatch(f, "FUNCTION");
}

fn setMacroCharacterFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 2 or args.len > 4) return Error.WrongArgCount;
    const char = try expectChar(ev, args[0]);
    try expectFunctionDesignator(ev, args[1]);
    const non_terminating = args.len > 2 and !args[2].equalsRaw(value.NIL);
    const rt = try readtableArg(ev, args, 3, false);
    try table_mod.setMacro(ev.heap, rt.table, char, stored(ev, args[1]), !non_terminating, false);
    return ev.set1(value.T);
}

fn getMacroCharacterFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const char = try expectChar(ev, args[0]);
    const rt = try readtableArg(ev, args, 1, true);
    const entry = table_mod.entry(rt.table, char);
    return switch (entry.syntax) {
        .terminating_macro => ev.setValues(&.{ handedOut(ev, entry.function), value.NIL }),
        .non_terminating_macro => ev.setValues(&.{ handedOut(ev, entry.function), value.T }),
        else => ev.setValues(&.{ value.NIL, value.NIL }),
    };
}

fn makeDispatchMacroCharacterFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 1 or args.len > 3) return Error.WrongArgCount;
    const char = try expectChar(ev, args[0]);
    const non_terminating = args.len > 1 and !args[1].equalsRaw(value.NIL);
    const rt = try readtableArg(ev, args, 2, false);
    try table_mod.setMacro(ev.heap, rt.table, char, table_mod.builtinValue(.dispatch), !non_terminating, true);
    return ev.set1(value.T);
}

/// The sub-character table of `char`, which has to be a dispatching
/// macro character.
fn dispatchTable(ev: *Evaluator, rt: *heap.HeapReadtable, char: u21) Error!Value {
    const entry = table_mod.entry(rt.table, char);
    if (entry.dispatch.equalsRaw(value.NIL)) return ev.typeMismatch(Value.fromChar(char), "CHARACTER");
    return entry.dispatch;
}

fn isDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn setDispatchMacroCharacterFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 3 or args.len > 4) return Error.WrongArgCount;
    const char = try expectChar(ev, args[0]);
    const sub = try expectChar(ev, args[1]);
    try expectFunctionDesignator(ev, args[2]);
    if (isDigit(sub)) return Error.ProgramError;
    const rt = try readtableArg(ev, args, 3, false);
    const dispatch = try dispatchTable(ev, rt, char);
    try table_mod.setSubFunction(ev.heap, dispatch, sub, stored(ev, args[2]));
    return ev.set1(value.T);
}

fn getDispatchMacroCharacterFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    const char = try expectChar(ev, args[0]);
    const sub = try expectChar(ev, args[1]);
    const rt = try readtableArg(ev, args, 2, true);
    const dispatch = try dispatchTable(ev, rt, char);
    if (isDigit(sub)) return ev.set1(value.NIL);
    return ev.set1(handedOut(ev, table_mod.subFunction(dispatch, sub)));
}

fn setSyntaxFromCharFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 2 or args.len > 4) return Error.WrongArgCount;
    const to = try expectChar(ev, args[0]);
    const from = try expectChar(ev, args[1]);
    const into = try readtableArg(ev, args, 2, false);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(Value.fromHeapAddr(@intFromPtr(into)));
    const source = try readtableArg(ev, args, 3, true);
    try held.push(Value.fromHeapAddr(@intFromPtr(source)));
    try table_mod.copyCharacter(ev.heap, source.table, from, into.table, to);
    return ev.set1(value.T);
}

// --- reading ---------------------------------------------------------

/// A reader over what `given`, a stream designator, has left to read.
/// `source` is where the reader keeps its place, and the stream is moved
/// past what was read by `finishOnStream`.
pub fn onStream(ev: *Evaluator, given: ?Value, source: *Source) Error!Reader {
    const s = try streams.streamOf(ev, given, .input);
    try streams.expectInput(s);
    if (s.pending) |c| {
        // A character handed back by `unread-char` came off the input,
        // so it is read again from there.
        s.position -= std.unicode.utf8CodepointSequenceLength(c) catch 1;
        s.pending = null;
    }
    source.* = Source.init(s.input[s.position..]);
    var rd = Reader.init(source, ev.heap, ev.interner);
    rd.stream = Value.fromHeapAddr(@intFromPtr(s));
    rd.stream_base = s.position;
    install(ev, &rd);
    return rd;
}

pub fn finishOnStream(rd: *Reader) void {
    const s = heap.asStream(rd.stream.?);
    s.position = rd.stream_base + rd.source.idx;
    s.pending = null;
}

/// The next object `given` holds, or null at its end.
pub fn readStreamForm(ev: *Evaluator, given: ?Value) Error!?Value {
    var source: Source = undefined;
    var rd = try onStream(ev, given, &source);
    return readFrom(ev, &rd);
}

fn readFrom(ev: *Evaluator, rd: *Reader) Error!?Value {
    var held = ev.heap.protect();
    defer held.close();
    try held.push(rd.stream.?);
    const form = rd.read() catch |e| {
        finishOnStream(rd);
        // What follows a form a person typed that will not read cannot be
        // told apart from the rest of it, so the line is given up.
        const s = heap.asStream(rd.stream.?);
        if (s.kind == .console) s.position = s.input.len;
        return failureOf(ev, rd, e);
    };
    finishOnStream(rd);
    // At a terminal, what a person types ends with the newline that sends
    // it, so output picks up at the left margin.
    if (heap.asStream(rd.stream.?).kind == .console) ev.output_column = 0;
    return form;
}

/// `(read &optional stream eof-error-p eof-value recursive-p)`, and
/// `read-preserving-whitespace`, which leaves the whitespace that ends
/// a token unread.
fn readFn(comptime preserve: bool) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = Evaluator.fromOpaque(p);
            const eof = try streams.EofBehavior.parse(args, 1);
            var source: Source = undefined;
            var rd = try onStream(ev, if (args.len > 0) args[0] else null, &source);
            rd.preserve_whitespace = preserve;
            rd.recursive = args.len > 3 and !args[3].equalsRaw(value.NIL);
            const form = try readFrom(ev, &rd);
            return form orelse eof.result(ev, heap.asStream(rd.stream.?));
        }
    }.f;
}

/// `(read-delimited-list char &optional stream recursive-p)`.
fn readDelimitedListFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 1 or args.len > 3) return Error.WrongArgCount;
    const close = try expectChar(ev, args[0]);
    var source: Source = undefined;
    var rd = try onStream(ev, if (args.len > 1) args[1] else null, &source);
    rd.recursive = args.len > 2 and !args[2].equalsRaw(value.NIL);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(rd.stream.?);
    const list = rd.readDelimitedList(close) catch |e| {
        finishOnStream(&rd);
        return failureOf(ev, &rd, e);
    };
    finishOnStream(&rd);
    return ev.set1(list);
}

fn keywordIs(ev: *Evaluator, v: Value, name: []const u8) Error!bool {
    return v.equalsRaw(try ev.interner.internKeyword(name));
}

/// The byte offset of character `index` in `text`.
fn byteOffset(text: []const u8, index: usize) ?usize {
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var count: usize = 0;
    while (count < index) : (count += 1) {
        _ = view.nextCodepointSlice() orelse return null;
    }
    return view.i;
}

/// `(read-from-string string &optional eof-error-p eof-value &key start
/// end preserve-whitespace)` returns the object and the index of the
/// first character it did not read.
fn readFromStringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = Evaluator.fromOpaque(p);
    if (args.len < 1) return Error.WrongArgCount;
    if (!heap.isString(args[0])) return ev.typeMismatch(args[0], "STRING");
    const signal_eof = args.len < 2 or !args[1].equalsRaw(value.NIL);
    const eof_value = if (args.len > 2) args[2] else value.NIL;
    var start: usize = 0;
    var end: ?usize = null;
    var preserve = false;
    if (args.len > 3) {
        const keys = args[3..];
        if (keys.len % 2 != 0) return Error.ProgramError;
        // The first occurrence of a keyword is the one that counts.
        var seen_start = false;
        var seen_end = false;
        var seen_preserve = false;
        var allow_other: ?bool = null;
        var unknown = false;
        var i: usize = 0;
        while (i < keys.len) : (i += 2) {
            const v = keys[i + 1];
            if (try keywordIs(ev, keys[i], "START")) {
                if (seen_start) continue;
                seen_start = true;
                if (!v.isFixnum() or v.toFixnum() < 0) return ev.typeMismatch(v, "INTEGER");
                start = @intCast(v.toFixnum());
            } else if (try keywordIs(ev, keys[i], "END")) {
                if (seen_end) continue;
                seen_end = true;
                if (v.equalsRaw(value.NIL)) continue;
                if (!v.isFixnum() or v.toFixnum() < 0) return ev.typeMismatch(v, "INTEGER");
                end = @intCast(v.toFixnum());
            } else if (try keywordIs(ev, keys[i], "PRESERVE-WHITESPACE")) {
                if (seen_preserve) continue;
                seen_preserve = true;
                preserve = !v.equalsRaw(value.NIL);
            } else if (try keywordIs(ev, keys[i], "ALLOW-OTHER-KEYS")) {
                if (allow_other == null) allow_other = !v.equalsRaw(value.NIL);
            } else {
                unknown = true;
            }
        }
        if (unknown and allow_other != true) return Error.ProgramError;
    }
    const text = try heap.stringUtf8Alloc(ev.allocator, args[0]);
    defer ev.allocator.free(text);
    const length = std.unicode.utf8CountCodepoints(text) catch text.len;
    const last = end orelse length;
    if (start > last or last > length) return Error.TypeError;
    const from = byteOffset(text, start) orelse return Error.TypeError;
    const to = byteOffset(text, last) orelse return Error.TypeError;

    var source = Source.init(text[from..to]);
    var rd = Reader.init(&source, ev.heap, ev.interner);
    install(ev, &rd);
    rd.preserve_whitespace = preserve;
    const form = rd.read() catch |e| return failureOf(ev, &rd, e);
    const consumed = std.unicode.utf8CountCodepoints(source.src[0..source.idx]) catch source.idx;
    const position = Value.fromFixnum(@intCast(start + consumed));
    if (form) |v| return ev.setValues(&.{ v, position });
    if (signal_eof) return failureOf(ev, &rd, error.EndOfInput);
    return ev.setValues(&.{ eof_value, position });
}
