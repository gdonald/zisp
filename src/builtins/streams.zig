//! Streams: opening and closing files, string streams, and the character
//! and byte operations over both.
//!
//! A file stream reads its contents in whole when it opens and writes its
//! buffer back when it closes, so there is no live cursor into the
//! operating system to keep in step.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const character = @import("../runtime/character.zig");
const pathname_mod = @import("../runtime/pathname.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const printer = @import("../runtime/printer.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const pathnames = @import("pathnames.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const Stream = heap.HeapStream;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerStreams(ev: *Evaluator) !void {
    _ = try ev.defineNative("OPEN", &openFn);
    _ = try ev.defineNative("CLOSE", &closeFn);
    _ = try ev.defineNative("STREAMP", &streampFn);
    _ = try ev.defineNative("INPUT-STREAM-P", directionFn(.input));
    _ = try ev.defineNative("OUTPUT-STREAM-P", directionFn(.output));
    _ = try ev.defineNative("OPEN-STREAM-P", &openStreamPFn);
    _ = try ev.defineNative("STREAM-ELEMENT-TYPE", &streamElementTypeFn);
    _ = try ev.defineNative("READ-CHAR", &readCharFn);
    _ = try ev.defineNative("PEEK-CHAR", &peekCharFn);
    _ = try ev.defineNative("UNREAD-CHAR", &unreadCharFn);
    _ = try ev.defineNative("WRITE-CHAR", &writeCharFn);
    // `read-line` reports whether the line ran to the end of the input.
    function.asFunction(try ev.defineNative("READ-LINE", &readLineFn)).preserves_values = true;
    _ = try ev.defineNative("WRITE-STRING", writeStringFn(false));
    _ = try ev.defineNative("WRITE-LINE", writeStringFn(true));
    _ = try ev.defineNative("READ-BYTE", &readByteFn);
    _ = try ev.defineNative("WRITE-BYTE", &writeByteFn);
    _ = try ev.defineNative("MAKE-STRING-INPUT-STREAM", &makeStringInputStreamFn);
    _ = try ev.defineNative("MAKE-STRING-OUTPUT-STREAM", &makeStringOutputStreamFn);
    _ = try ev.defineNative("GET-OUTPUT-STREAM-STRING", &getOutputStreamStringFn);
    _ = try ev.defineNative("FORCE-OUTPUT", &noOpStreamFn);
    _ = try ev.defineNative("FINISH-OUTPUT", &noOpStreamFn);
    _ = try ev.defineNative("CLEAR-OUTPUT", &noOpStreamFn);

    for ([_][]const u8{
        "INPUT",     "OUTPUT",  "IO",                "PROBE",       "SUPERSEDE", "APPEND",
        "OVERWRITE", "RENAME",  "RENAME-AND-DELETE", "NEW-VERSION", "CREATE",    "UTF-8",
        "LATIN-1",   "DEFAULT", "EOF",
    }) |n| {
        _ = try ev.interner.internKeyword(n);
    }
    try bindStandardStreams(ev);
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

fn keywordIs(ev: *Evaluator, v: Value, name: []const u8) Error!bool {
    return v.equalsRaw(try ev.interner.internKeyword(name));
}

// --- the standard stream variables ---

fn bindStandardStreams(ev: *Evaluator) !void {
    const console = try ev.heap.allocStream(consoleStream());
    for ([_][]const u8{
        "*STANDARD-OUTPUT*", "*ERROR-OUTPUT*", "*TRACE-OUTPUT*",
        "*QUERY-IO*",        "*TERMINAL-IO*",  "*DEBUG-IO*",
    }) |n| {
        symbol_mod.symbol(try ev.interner.intern(n)).value_cell = console;
    }
    const input = try ev.heap.allocStream(emptyStream(.string, .input));
    symbol_mod.symbol(try ev.interner.intern("*STANDARD-INPUT*")).value_cell = input;
}

fn consoleStream() Stream {
    return emptyStream(.console, .io);
}

pub fn emptyStream(kind: heap.StreamKind, direction: heap.StreamDirection) Stream {
    return .{
        .header = undefined,
        .kind = kind,
        .direction = direction,
        .element = .character,
        .external_format = .utf8,
        .is_open = true,
        .path = value.NIL,
        .input = &.{},
        .position = 0,
        .output = .empty,
        .write_position = 0,
        .pending = null,
        .delete_on_close = value.NIL,
        .tokens = .empty,
        .target = value.NIL,
        .block_depth = 0,
        .circle = null,
    };
}

// --- stream designators ---

/// A stream argument: an actual stream, `t` for the console, or `nil` for
/// standard input or output depending on which side is wanted.
pub const Side = enum { input, output };

pub fn streamOf(ev: *Evaluator, given: ?Value, side: Side) Error!*Stream {
    const v = given orelse value.NIL;
    if (heap.isStream(v)) return heap.asStream(v);
    const name = if (v.equalsRaw(value.T))
        "*TERMINAL-IO*"
    else if (v.equalsRaw(value.NIL))
        (if (side == .input) "*STANDARD-INPUT*" else "*STANDARD-OUTPUT*")
    else
        return Error.TypeError;
    const sym = try ev.interner.intern(name);
    const bound = ev.env.lookupValue(sym) orelse return ev.unbound(sym, Error.UnboundVariable);
    if (!heap.isStream(bound)) return Error.TypeError;
    return heap.asStream(bound);
}

fn expectStream(v: Value) Error!*Stream {
    if (!heap.isStream(v)) return Error.TypeError;
    return heap.asStream(v);
}

fn streampFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(heap.isStream(args[0]));
}

fn directionFn(comptime side: enum { input, output }) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len != 1) return Error.WrongArgCount;
            const s = try expectStream(args[0]);
            return boolv(switch (side) {
                .input => s.direction == .input or s.direction == .io,
                .output => s.direction == .output or s.direction == .io,
            });
        }
    }.f;
}

fn openStreamPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv((try expectStream(args[0])).is_open);
}

fn streamElementTypeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const s = try expectStream(args[0]);
    return switch (s.element) {
        .character => ev.interner.intern("CHARACTER"),
        .unsigned_byte_8 => byteType(ev, "UNSIGNED-BYTE", 8),
        .signed_byte_16 => byteType(ev, "SIGNED-BYTE", 16),
    };
}

fn byteType(ev: *Evaluator, name: []const u8, bits: i64) Error!Value {
    const tail = try ev.heap.allocCons(Value.fromFixnum(bits), value.NIL);
    return ev.heap.allocCons(try ev.interner.intern(name), tail);
}

// --- opening and closing files ---

const OpenOptions = struct {
    direction: heap.StreamDirection = .input,
    element: heap.StreamElement = .character,
    external_format: heap.ExternalFormat = .utf8,
    /// Null means the caller did not say, and the default depends on the
    /// direction: input errors, output creates.
    if_exists: ?Value = null,
    if_does_not_exist: ?Value = null,
};

fn parseOpenOptions(ev: *Evaluator, args: []const Value) Error!OpenOptions {
    if (args.len % 2 != 0) return Error.WrongArgCount;
    var options = OpenOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const v = args[i + 1];
        if (try keywordIs(ev, args[i], "DIRECTION")) {
            options.direction = try directionOf(ev, v);
        } else if (try keywordIs(ev, args[i], "ELEMENT-TYPE")) {
            options.element = try elementOf(ev, v);
        } else if (try keywordIs(ev, args[i], "EXTERNAL-FORMAT")) {
            options.external_format = try formatOf(ev, v);
        } else if (try keywordIs(ev, args[i], "IF-EXISTS")) {
            options.if_exists = try checkedIfExists(ev, v);
        } else if (try keywordIs(ev, args[i], "IF-DOES-NOT-EXIST")) {
            options.if_does_not_exist = try checkedIfMissing(ev, v);
        } else return Error.ProgramError;
    }
    return options;
}

/// The options are checked when they are read rather than when they
/// apply, so a misspelling is caught whether or not the file exists.
fn checkedIfExists(ev: *Evaluator, v: Value) Error!Value {
    if (v.equalsRaw(value.NIL)) return v;
    for ([_][]const u8{
        "ERROR",  "SUPERSEDE",         "APPEND",      "OVERWRITE",
        "RENAME", "RENAME-AND-DELETE", "NEW-VERSION",
    }) |name| {
        if (try keywordIs(ev, v, name)) return v;
    }
    return Error.TypeError;
}

fn checkedIfMissing(ev: *Evaluator, v: Value) Error!Value {
    if (v.equalsRaw(value.NIL)) return v;
    if (try keywordIs(ev, v, "ERROR") or try keywordIs(ev, v, "CREATE")) return v;
    return Error.TypeError;
}

fn directionOf(ev: *Evaluator, v: Value) Error!heap.StreamDirection {
    if (try keywordIs(ev, v, "INPUT")) return .input;
    if (try keywordIs(ev, v, "OUTPUT")) return .output;
    if (try keywordIs(ev, v, "IO")) return .io;
    if (try keywordIs(ev, v, "PROBE")) return .probe;
    return Error.TypeError;
}

fn elementOf(ev: *Evaluator, v: Value) Error!heap.StreamElement {
    _ = ev;
    if (v.isSymbol()) {
        const n = symbol_mod.symbol(v).name;
        if (std.mem.eql(u8, n, "CHARACTER") or std.mem.eql(u8, n, "BASE-CHAR")) return .character;
        if (std.mem.eql(u8, n, "DEFAULT")) return .character;
        return Error.TypeError;
    }
    if (v.isCons() and heap.car(v).isSymbol()) {
        const head = symbol_mod.symbol(heap.car(v)).name;
        const rest = heap.cdr(v);
        if (rest.isCons() and heap.car(rest).isFixnum()) {
            const bits = heap.car(rest).toFixnum();
            if (std.mem.eql(u8, head, "UNSIGNED-BYTE") and bits == 8) return .unsigned_byte_8;
            if (std.mem.eql(u8, head, "SIGNED-BYTE") and bits == 16) return .signed_byte_16;
        }
    }
    return Error.TypeError;
}

fn formatOf(ev: *Evaluator, v: Value) Error!heap.ExternalFormat {
    if (try keywordIs(ev, v, "UTF-8") or try keywordIs(ev, v, "DEFAULT")) return .utf8;
    if (try keywordIs(ev, v, "LATIN-1")) return .latin1;
    return Error.TypeError;
}

fn readWholeFile(ev: *Evaluator, path: []const u8) Error!?[]u8 {
    const io = ev.io orelse return Error.FileError;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var contents: std.ArrayList(u8) = .empty;
    file_reader.interface.appendRemainingUnlimited(ev.heap.allocator, &contents) catch
        return Error.FileError;
    return contents.items;
}

fn openFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1) return Error.WrongArgCount;
    const options = try parseOpenOptions(ev, args[1..]);
    const path = try pathnames.namestringOf(ev.heap.allocator, args[0]);
    const existing = try readWholeFile(ev, path);

    if (existing == null) {
        const missing = options.if_does_not_exist orelse defaultIfMissing(ev, options.direction);
        if (try keywordIs(ev, missing, "ERROR")) return Error.FileError;
        if (missing.equalsRaw(value.NIL)) return value.NIL;
        if (!try keywordIs(ev, missing, "CREATE")) return Error.TypeError;
    } else if (options.direction == .output or options.direction == .io) {
        const clash = options.if_exists orelse try ev.interner.internKeyword("NEW-VERSION");
        if (try keywordIs(ev, clash, "ERROR")) return Error.FileError;
        if (clash.equalsRaw(value.NIL)) return value.NIL;
    }

    var stream = emptyStream(.file, options.direction);
    stream.element = options.element;
    stream.external_format = options.external_format;
    stream.path = try pathname_mod.parseText(ev.heap, ev.interner, path);
    stream.input = existing orelse &.{};
    if (options.direction == .probe) {
        stream.is_open = false;
        return ev.heap.allocStream(stream);
    }
    if (options.direction == .output or options.direction == .io) {
        try prepareOutput(ev, &stream, path, existing, options);
    }
    return ev.heap.allocStream(stream);
}

fn defaultIfMissing(ev: *Evaluator, direction: heap.StreamDirection) Value {
    const name = switch (direction) {
        .input, .probe => "ERROR",
        .output, .io => "CREATE",
    };
    return ev.interner.internKeyword(name) catch value.NIL;
}

/// Set up the write buffer according to `:if-exists`. The file itself is
/// only touched at close, except for the two options that rename it.
fn prepareOutput(
    ev: *Evaluator,
    stream: *Stream,
    path: []const u8,
    existing: ?[]const u8,
    options: OpenOptions,
) Error!void {
    const clash = options.if_exists orelse try ev.interner.internKeyword("NEW-VERSION");
    if (existing == null) return;

    if (try keywordIs(ev, clash, "APPEND")) {
        try stream.output.appendSlice(ev.heap.allocator, existing.?);
        stream.write_position = stream.output.items.len;
        return;
    }
    if (try keywordIs(ev, clash, "OVERWRITE")) {
        try stream.output.appendSlice(ev.heap.allocator, existing.?);
        stream.write_position = 0;
        return;
    }
    const renaming = try keywordIs(ev, clash, "RENAME") or
        try keywordIs(ev, clash, "RENAME-AND-DELETE");
    if (renaming) {
        const backup = try std.fmt.allocPrint(ev.heap.allocator, "{s}.bak", .{path});
        const io = ev.io orelse return Error.FileError;
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup, io) catch return Error.FileError;
        if (try keywordIs(ev, clash, "RENAME-AND-DELETE")) {
            stream.delete_on_close = try ev.heap.allocString(backup);
        }
        return;
    }
    // :supersede and :new-version both start from nothing.
    const fresh = try keywordIs(ev, clash, "SUPERSEDE") or
        try keywordIs(ev, clash, "NEW-VERSION");
    if (!fresh) return Error.TypeError;
}

fn closeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1) return Error.WrongArgCount;
    const s = try expectStream(args[0]);
    if (!s.is_open) return value.NIL;
    s.is_open = false;
    if (s.kind != .file) return value.T;
    if (s.direction == .output or s.direction == .io) try writeBack(ev, s);
    if (heap.isString(s.delete_on_close)) {
        const io = ev.io orelse return Error.FileError;
        const backup = try heap.stringUtf8Alloc(ev.heap.allocator, s.delete_on_close);
        std.Io.Dir.cwd().deleteFile(io, backup) catch {};
    }
    return value.T;
}

fn writeBack(ev: *Evaluator, s: *Stream) Error!void {
    const io = ev.io orelse return Error.FileError;
    const path = try pathnames.namestringOf(ev.heap.allocator, s.path);
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.FileError;
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &write_buf);
    file_writer.interface.writeAll(s.output.items) catch return Error.FileError;
    file_writer.interface.flush() catch return Error.FileError;
}

fn noOpStreamFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    _ = try streamOf(ev, if (args.len == 1) args[0] else null, .output);
    return value.NIL;
}

// --- reading and writing characters ---

fn expectInput(s: *Stream) Error!void {
    if (!s.is_open) return Error.FileError;
    if (s.direction != .input and s.direction != .io) return Error.TypeError;
}

fn expectOutput(s: *Stream) Error!void {
    if (!s.is_open) return Error.FileError;
    if (s.direction != .output and s.direction != .io and s.kind != .console) {
        return Error.TypeError;
    }
}

/// The next character, decoding the stream's external format. Null at the
/// end of the input.
fn nextChar(s: *Stream) ?u21 {
    if (s.pending) |c| {
        s.pending = null;
        return c;
    }
    if (s.position >= s.input.len) return null;
    const byte = s.input[s.position];
    if (s.external_format == .latin1 or byte < 0x80) {
        s.position += 1;
        return byte;
    }
    const width = std.unicode.utf8ByteSequenceLength(byte) catch {
        s.position += 1;
        return byte;
    };
    if (s.position + width > s.input.len) {
        s.position += 1;
        return byte;
    }
    const decoded = std.unicode.utf8Decode(s.input[s.position .. s.position + width]) catch {
        s.position += 1;
        return byte;
    };
    s.position += width;
    return decoded;
}

/// The three trailing arguments the reading operations share:
/// `eof-error-p`, `eof-value`, and a recursive-call flag that is ignored.
const EofBehavior = struct {
    signal: bool,
    on_eof: Value,

    fn parse(args: []const Value, first: usize) Error!EofBehavior {
        if (args.len > first + 3) return Error.WrongArgCount;
        return .{
            .signal = if (args.len > first) !args[first].equalsRaw(value.NIL) else true,
            .on_eof = if (args.len > first + 1) args[first + 1] else value.NIL,
        };
    }

    fn result(self: EofBehavior) Error!Value {
        if (self.signal) return Error.FileError;
        return self.on_eof;
    }
};

fn readCharFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    const s = try streamOf(ev, if (args.len > 0) args[0] else null, .input);
    try expectInput(s);
    const eof = try EofBehavior.parse(args, 1);
    const c = nextChar(s) orelse return eof.result();
    return Value.fromChar(c);
}

fn peekCharFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    // The first argument is a peek type, which selects which character to
    // stop at; only the default "next character" form is supported.
    if (args.len > 0 and !args[0].equalsRaw(value.NIL)) {
        if (!args[0].equalsRaw(value.T)) return Error.TypeError;
    }
    const s = try streamOf(ev, if (args.len > 1) args[1] else null, .input);
    try expectInput(s);
    const eof = try EofBehavior.parse(args, 2);
    const skip_whitespace = args.len > 0 and args[0].equalsRaw(value.T);

    while (true) {
        const before = s.position;
        const pending = s.pending;
        const c = nextChar(s) orelse return eof.result();
        if (skip_whitespace and (c == ' ' or c == '\n' or c == '\t' or c == '\r')) continue;
        s.position = before;
        s.pending = pending;
        return Value.fromChar(c);
    }
}

fn unreadCharFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    if (args[0].tag() != .char) return Error.TypeError;
    const s = try streamOf(ev, if (args.len == 2) args[1] else null, .input);
    try expectInput(s);
    if (s.pending != null) return Error.ControlError;
    s.pending = args[0].toChar();
    return value.NIL;
}

/// Append one character to a stream's output, honoring its format.
fn emit(ev: *Evaluator, s: *Stream, c: u21) Error!void {
    if (s.kind == .pretty) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch return Error.TypeError;
        return @import("pprint.zig").recordText(ev, s, buf[0..n]);
    }
    if (s.kind == .console) {
        const out = ev.out orelse return Error.NoOutputStream;
        try printer.writeRawChar(out, c);
        ev.output_column = if (c == '\n') 0 else ev.output_column + 1;
        return;
    }
    var buf: [4]u8 = undefined;
    const bytes: []const u8 = if (s.external_format == .latin1) blk: {
        if (c > 0xFF) return Error.TypeError;
        buf[0] = @intCast(c);
        break :blk buf[0..1];
    } else blk: {
        const n = std.unicode.utf8Encode(c, &buf) catch return Error.TypeError;
        break :blk buf[0..n];
    };
    try emitBytes(ev, s, bytes);
}

/// Writes land at the write position, overwriting what is already there
/// before extending, which is what `:if-exists :overwrite` needs.
pub fn emitBytes(ev: *Evaluator, s: *Stream, bytes: []const u8) Error!void {
    if (s.kind == .pretty) return @import("pprint.zig").recordText(ev, s, bytes);
    if (s.kind == .console) {
        const out = ev.out orelse return Error.NoOutputStream;
        out.writeAll(bytes) catch return Error.WriteFailed;
        for (bytes) |b| {
            if (b == '\n') {
                ev.output_column = 0;
            } else if (b & 0xC0 != 0x80) {
                ev.output_column += 1;
            }
        }
        return;
    }
    for (bytes) |b| {
        if (s.write_position < s.output.items.len) {
            s.output.items[s.write_position] = b;
        } else {
            try s.output.append(ev.heap.allocator, b);
        }
        s.write_position += 1;
    }
}

fn writeCharFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    if (args[0].tag() != .char) return Error.TypeError;
    const s = try streamOf(ev, if (args.len == 2) args[1] else null, .output);
    try expectOutput(s);
    try emit(ev, s, args[0].toChar());
    return args[0];
}

fn readLineFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    const s = try streamOf(ev, if (args.len > 0) args[0] else null, .input);
    try expectInput(s);
    const eof = try EofBehavior.parse(args, 1);

    var codes: std.ArrayList(u32) = .empty;
    defer codes.deinit(ev.allocator);
    var saw_any = false;
    while (nextChar(s)) |c| {
        saw_any = true;
        if (c == '\n') {
            return ev.setValues(&.{ try ev.heap.allocStringFromChars(codes.items), value.NIL });
        }
        try codes.append(ev.allocator, c);
    }
    if (!saw_any) {
        // A line that ends at the end of input is still a line; only an
        // empty read is the end of the file.
        return ev.setValues(&.{ try eof.result(), value.T });
    }
    return ev.setValues(&.{ try ev.heap.allocStringFromChars(codes.items), value.T });
}

fn writeStringFn(comptime newline: bool) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len < 1) return Error.WrongArgCount;
            if (!heap.isString(args[0])) return Error.TypeError;
            const s = try streamOf(ev, if (args.len > 1) args[1] else null, .output);
            try expectOutput(s);
            for (heap.asString(args[0]).constSlice()) |c| try emit(ev, s, @intCast(c));
            if (newline) try emit(ev, s, '\n');
            return args[0];
        }
    }.f;
}

// --- bytes ---

fn readByteFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len < 1) return Error.WrongArgCount;
    const s = try expectStream(args[0]);
    try expectInput(s);
    const eof = try EofBehavior.parse(args, 1);
    const width: usize = if (s.element == .signed_byte_16) 2 else 1;
    if (s.position + width > s.input.len) return eof.result();

    if (width == 1) {
        const b = s.input[s.position];
        s.position += 1;
        return Value.fromFixnum(b);
    }
    const low: u16 = s.input[s.position];
    const high: u16 = s.input[s.position + 1];
    s.position += 2;
    return Value.fromFixnum(@as(i16, @bitCast(low | (high << 8))));
}

fn writeByteFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isFixnum()) return Error.TypeError;
    const s = try expectStream(args[1]);
    try expectOutput(s);
    const n = args[0].toFixnum();
    if (s.element == .signed_byte_16) {
        if (n < std.math.minInt(i16) or n > std.math.maxInt(i16)) return Error.TypeError;
        const bits: u16 = @bitCast(@as(i16, @intCast(n)));
        try emitBytes(ev, s, &.{ @intCast(bits & 0xFF), @intCast(bits >> 8) });
        return args[0];
    }
    if (n < 0 or n > 255) return Error.TypeError;
    try emitBytes(ev, s, &.{@intCast(n)});
    return args[0];
}

// --- string streams ---

fn makeStringInputStreamFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 3) return Error.WrongArgCount;
    if (!heap.isString(args[0])) return Error.TypeError;
    var stream = emptyStream(.string, .input);
    stream.input = try heap.stringUtf8Alloc(ev.heap.allocator, args[0]);
    return ev.heap.allocStream(stream);
}

fn makeStringOutputStreamFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len % 2 != 0) return Error.WrongArgCount;
    return ev.heap.allocStream(emptyStream(.string, .output));
}

/// The text written so far, which the stream then forgets.
fn getOutputStreamStringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const s = try expectStream(args[0]);
    if (s.kind != .string) return Error.TypeError;
    const text = try ev.heap.allocString(s.output.items);
    s.output.clearRetainingCapacity();
    s.write_position = 0;
    return text;
}
