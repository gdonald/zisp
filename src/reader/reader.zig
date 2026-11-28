//! Common Lisp reader.
//!
//! Reads one character at a time and does what the readtable says each
//! one means, following the algorithm of CLHS 2.2: whitespace is skipped,
//! a macro character calls its function, and anything else starts a
//! token, which is a number when it has number syntax in `*read-base*`
//! and a symbol otherwise.
//!
//! The reader's own macro functions are Zig. A function a program
//! installs with `set-macro-character` is called through the `Host` with
//! a stream positioned where the reader has got to, and the reader picks
//! up from wherever the function leaves that stream.
//!
//! Allocates through a `Heap` and interns through an `Interner`. Source
//! positions are written to an optional side-table keyed on cons address.

const std = @import("std");
const source_mod = @import("source.zig");
const float_parse = @import("float_parse.zig");
const readtable = @import("readtable.zig");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const bignum = @import("../runtime/bignum.zig");
const complex = @import("../runtime/complex.zig");
const character = @import("../runtime/character.zig");
const pathname_mod = @import("../runtime/pathname.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");
const symbol = @import("../runtime/symbol.zig");
const source_pos = @import("../runtime/source_pos.zig");
const stack_mod = @import("../runtime/stack.zig");
const function = @import("../eval/function.zig");

/// A build with no file system has no pathname functions, so `#P` is a
/// reader error there.
const pathnames_available = !build_options.freestanding and builtin.os.tag != .freestanding;

const Position = source_mod.Position;
const Source = source_mod.Source;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = symbol.Interner;
const Builtin = readtable.Builtin;
const PositionTable = source_pos.PositionTable;
const SourcePosition = source_pos.SourcePosition;

/// What reading can fail with: the reader's own errors, and whatever a
/// macro function written in Lisp fails with.
pub const Error = error{
    /// The input ended inside an object.
    EndOfInput,
    /// A `)` with no list open.
    UnbalancedParens,
    /// Text that is not the syntax of any object.
    BadToken,
    /// A `pkg:name` prefix named a package that does not exist.
    NoSuchPackage,
    /// `pkg:name` where `name` is not external in `pkg`.
    SymbolNotExternal,
} || function.NativeError;

/// `readtable-case`: how an unescaped symbol name is folded.
pub const SymbolCase = enum(u64) { upcase = 0, downcase = 1, preserve = 2, invert = 3 };

/// What the reader needs from an evaluator. The context is opaque so the
/// reader needs no evaluator type.
pub const Host = struct {
    context: *anyopaque,
    /// Evaluate a form, for `#.`.
    eval: *const fn (*anyopaque, Value) function.NativeError!Value,
    /// Call a function, returning its first value, or null when it
    /// returned none.
    call: *const fn (*anyopaque, Value, []const Value) function.NativeError!?Value,
    /// A string input stream over `bytes`, for a macro function to read
    /// from when the reader was not given a stream.
    openStream: *const fn (*anyopaque, []const u8) function.NativeError!Value,
};

/// The read in progress, which a recursive read shares labels and
/// whitespace handling with.
var active: ?*Reader = null;

/// What reading from one character came to.
const Step = union(enum) {
    value: Value,
    /// Nothing: a comment, or a form a feature test left out.
    none,
    /// A token that is a single dot, where a list allows one.
    dot,
};

/// One character of a token, and whether an escape made it stand for
/// itself.
const TokenChar = struct { code: u21, escaped: bool };

const Token = struct {
    chars: std.ArrayListUnmanaged(TokenChar) = .empty,
    escaped: bool = false,
    /// How many characters the token held when its last `|...|` closed,
    /// so `pkg::||` names the empty symbol rather than ending at a colon.
    escape_end: ?usize = null,

    fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        self.chars.deinit(allocator);
    }

    fn append(self: *Token, allocator: std.mem.Allocator, code: u21, escaped: bool) !void {
        if (escaped) self.escaped = true;
        try self.chars.append(allocator, .{ .code = code, .escaped = escaped });
    }
};

/// The slots of the region the outermost read holds its values in.
const LABELS_SLOT = 0;
const TABLE_SLOT = 1;
const STREAM_SLOT = 2;

pub const Reader = struct {
    source: *Source,
    heap: *Heap,
    interner: *Interner,
    /// The readtable's vector. Null until a read needs one, which is then
    /// the standard readtable.
    table: ?Value = null,
    own_table: bool = false,
    /// Optional side-table for cons positions.
    positions: ?*PositionTable = null,
    /// Filename recorded with positions. Borrowed.
    file: []const u8 = "",
    /// Feature symbols for `#+` / `#-` in place of `*features*`.
    features: ?[]const Value = null,
    /// What `*read-suppress*` says, or a discarded `#+` branch.
    suppress: bool = false,
    host: ?Host = null,
    case: SymbolCase = .upcase,
    default_float: float_parse.FloatType = .single,
    /// Whether the whitespace ending a top-level token is left unread.
    preserve_whitespace: bool = false,
    /// Whether this read is part of the read that called the macro
    /// function it was started from.
    recursive: bool = false,
    /// How many backquotes the form being read is inside.
    backquote_depth: u32 = 0,
    /// The Lisp stream being read. The source starts at `stream_base` in
    /// its input.
    stream: ?Value = null,
    stream_base: usize = 0,
    /// Whether `stream` was opened by this reader for a macro function,
    /// rather than handed to it.
    opened_stream: bool = false,
    /// Unqualified symbols are keywords, which is how a feature
    /// expression is read.
    keyword_symbols: bool = false,
    last_error_pos: ?SourcePosition = null,
    /// This read's region, which holds its readtable and stream.
    region: ?*stack_mod.Region = null,
    /// The region whose first slot holds the `#n=` labels: this read's,
    /// or that of the read a recursive one is part of.
    labels: ?*stack_mod.Region = null,
    /// Where the character `skipWhitespace` returned last was.
    char_pos: Position = .{},

    pub fn init(source: *Source, heap: *Heap, interner: *Interner) Reader {
        return .{ .source = source, .heap = heap, .interner = interner };
    }

    /// A reader that records the position of every cons it reads under
    /// the name `file`. Pass `null` for `positions` to skip that.
    pub fn initFull(
        source: *Source,
        heap: *Heap,
        interner: *Interner,
        positions: ?*PositionTable,
        file: []const u8,
    ) Reader {
        return .{ .source = source, .heap = heap, .interner = interner, .positions = positions, .file = file };
    }

    pub fn setFeatures(self: *Reader, features: []const Value) void {
        self.features = features;
    }

    /// Where the last failing `read` stopped, or null after a success.
    pub fn lastErrorPos(self: *const Reader) ?SourcePosition {
        return self.last_error_pos;
    }

    /// Fail at the start of the object being read.
    fn fail(self: *Reader, err: Error) Error {
        if (self.last_error_pos == null) {
            const p = self.char_pos;
            self.last_error_pos = .{ .file = self.file, .line = p.line, .column = p.column };
        }
        return err;
    }

    fn failAt(self: *Reader, p: Position, err: Error) Error {
        self.last_error_pos = .{ .file = self.file, .line = p.line, .column = p.column };
        return err;
    }

    fn allocator(self: *Reader) std.mem.Allocator {
        return self.heap.allocator;
    }

    // --- entry points ------------------------------------------------

    /// Read one object. Null when the input ends before one starts.
    pub fn read(self: *Reader) Error!?Value {
        return self.enter(readTop);
    }

    /// `read-delimited-list`: the objects up to the next `close`.
    pub fn readDelimitedList(self: *Reader, close: u21) Error!Value {
        const Body = struct {
            fn run(rd: *Reader, closing: u21) Error!Value {
                const v = try rd.readDelimited(closing, false, rd.source.pos());
                return if (rd.suppress) value.NIL else v;
            }
        };
        return self.enterWith(Body.run, close);
    }

    /// Run one of the reader's own macro functions, as a call to the
    /// function `get-macro-character` returned does.
    pub fn runBuiltin(self: *Reader, which: Builtin, char: u21, arg: ?Value) Error!?Value {
        const Call = struct { which: Builtin, char: u21, arg: ?Value };
        const Body = struct {
            fn run(rd: *Reader, call: Call) Error!?Value {
                const step = if (call.which == .dispatch)
                    try rd.readDispatch(readtable.entry(rd.table.?, call.char).dispatch)
                else
                    try rd.builtinMacro(call.which, call.char, call.arg);
                return switch (step) {
                    .value => |v| v,
                    .none => null,
                    .dot => rd.fail(Error.BadToken),
                };
            }
        };
        return self.enterWith(Body.run, Call{ .which = which, .char = char, .arg = arg });
    }

    fn readTop(self: *Reader) Error!?Value {
        while (true) {
            const c = self.skipWhitespace() orelse return null;
            switch (try self.readStep(c, false)) {
                .value => |v| return v,
                .none => {},
                .dot => return self.fail(Error.BadToken),
            }
        }
    }

    fn enter(self: *Reader, comptime body: fn (*Reader) Error!?Value) Error!?Value {
        const Wrap = struct {
            fn run(rd: *Reader, _: void) Error!?Value {
                return body(rd);
            }
        };
        return self.enterWith(Wrap.run, {});
    }

    /// Set up a read: the region that keeps what it holds alive, the
    /// readtable, and what a recursive read takes from the read it is
    /// part of.
    fn enterWith(self: *Reader, comptime body: anytype, arg: anytype) ReturnOf(body) {
        self.last_error_pos = null;
        var region = self.heap.protect();
        defer region.close();
        try region.push(value.NIL);
        try region.push(value.NIL);
        try region.push(self.stream orelse value.NIL);
        // A table this reader made for itself is held only while it
        // reads, so it is made again for each read.
        if (self.table == null or self.own_table) {
            self.table = try readtable.standard(self.heap);
            self.own_table = true;
        }
        region.setItem(TABLE_SLOT, self.table.?);
        // A stream opened for a macro function lasts one read, since a
        // collection between reads can move it.
        defer if (self.opened_stream) {
            self.stream = null;
            self.opened_stream = false;
        };

        if (self.variable("*READ-SUPPRESS*")) |cell| self.suppress = !cell.equalsRaw(value.NIL);

        const outer = active;
        defer active = outer;
        const saved_region = self.region;
        const saved_labels = self.labels;
        defer {
            self.region = saved_region;
            self.labels = saved_labels;
        }
        self.region = &region;
        self.labels = &region;
        if (self.recursive) {
            if (outer) |parent| {
                self.labels = parent.labels;
                self.preserve_whitespace = parent.preserve_whitespace;
                self.backquote_depth = parent.backquote_depth;
            }
        }
        active = self;
        return body(self, arg) catch |err| return self.fail(err);
    }

    fn ReturnOf(comptime body: anytype) type {
        return @typeInfo(@TypeOf(body)).@"fn".return_type.?;
    }

    // --- characters --------------------------------------------------

    fn syntaxOf(self: *Reader, c: u21) readtable.Syntax {
        return readtable.syntaxOf(self.table.?, c);
    }

    fn nextChar(self: *Reader) ?u21 {
        return self.source.next();
    }

    fn nextCharOrEnd(self: *Reader) Error!u21 {
        return self.source.next() orelse self.fail(Error.EndOfInput);
    }

    /// The next character that is not whitespace, consumed.
    fn skipWhitespace(self: *Reader) ?u21 {
        while (true) {
            const at = self.source.pos();
            const c = self.source.next() orelse return null;
            if (self.syntaxOf(c) != .whitespace) {
                self.char_pos = at;
                return c;
            }
        }
    }

    // --- one step ----------------------------------------------------

    /// Read from `c`, the character just consumed.
    fn readStep(self: *Reader, c: u21, allow_dot: bool) Error!Step {
        const e = readtable.entry(self.table.?, c);
        return switch (e.syntax) {
            .whitespace => .none,
            .invalid => self.fail(Error.BadToken),
            .terminating_macro, .non_terminating_macro => self.callMacro(c, e),
            .constituent, .single_escape, .multiple_escape => blk: {
                const start = self.char_pos;
                var token: Token = .{};
                defer token.deinit(self.allocator());
                try self.readToken(&token, c, false);
                break :blk self.interpretToken(&token, allow_dot, start);
            },
        };
    }

    /// One object, for a macro function that needs exactly one.
    fn readObject(self: *Reader) Error!Value {
        while (true) {
            const c = self.skipWhitespace() orelse return self.fail(Error.EndOfInput);
            switch (try self.readStep(c, false)) {
                .value => |v| return v,
                .none => {},
                .dot => return self.fail(Error.BadToken),
            }
        }
    }

    fn callMacro(self: *Reader, c: u21, e: readtable.Entry) Error!Step {
        if (readtable.asBuiltin(e.function)) |b| {
            if (b == .dispatch) return self.readDispatch(e.dispatch);
            return self.builtinMacro(b, c, null);
        }
        const result = try self.callLisp(e.function, &.{ value.NIL, Value.fromChar(c) });
        return if (result) |v| .{ .value = v } else .none;
    }

    /// Call a macro function written in Lisp with the stream in the first
    /// argument's place, then carry on from where it left the stream.
    fn callLisp(self: *Reader, f: Value, args_in: []const Value) Error!?Value {
        const host = self.host orelse return self.fail(Error.BadToken);
        const stream = try self.syncStreamOut();
        var args: [3]Value = undefined;
        @memcpy(args[0..args_in.len], args_in);
        args[0] = stream;
        // A macro function sees `*read-suppress*` as the reader does.
        const suppress_cell = self.variable("*READ-SUPPRESS*");
        const saved = if (suppress_cell) |cell| cell.* else value.NIL;
        if (suppress_cell) |cell| cell.* = if (self.suppress) value.T else value.NIL;
        defer if (suppress_cell) |cell| {
            cell.* = saved;
        };
        const result = host.call(host.context, f, args[0..args_in.len]) catch |err| {
            self.syncStreamIn();
            return err;
        };
        self.syncStreamIn();
        return result;
    }

    fn syncStreamOut(self: *Reader) Error!Value {
        if (self.stream == null) {
            const host = self.host orelse return self.fail(Error.BadToken);
            self.stream = try host.openStream(host.context, self.source.src);
            self.stream_base = 0;
            self.opened_stream = true;
            if (self.region) |r| r.setItem(STREAM_SLOT, self.stream.?);
        }
        const s = heap_mod.asStream(self.stream.?);
        s.position = self.stream_base + self.source.idx;
        s.pending = null;
        return self.stream.?;
    }

    fn syncStreamIn(self: *Reader) void {
        const s = heap_mod.asStream(self.stream.?);
        var at = s.position;
        if (s.pending) |c| {
            at -= std.unicode.utf8CodepointSequenceLength(c) catch 1;
            s.pending = null;
        }
        self.source.seek(at -| self.stream_base);
    }

    /// The value cell of a standard variable.
    fn variable(self: *Reader, name: []const u8) ?*Value {
        const found = self.interner.cl.findPresent(name) orelse return null;
        const cell = &symbol.symbol(found.sym).value_cell;
        if (cell.equalsRaw(value.SPECIAL_UNBOUND)) return null;
        return cell;
    }

    // --- tokens ------------------------------------------------------

    /// Accumulate a token starting with `first`, following steps 8 and 9
    /// of CLHS 2.2. `first_escaped` takes `first` as escaped, which is
    /// how `#\` reads its character.
    fn readToken(self: *Reader, token: *Token, first: u21, first_escaped: bool) Error!void {
        const gpa = self.allocator();
        var x = first;
        if (first_escaped) {
            try token.append(gpa, x, true);
            x = self.nextChar() orelse return;
        }
        while (true) {
            switch (self.syntaxOf(x)) {
                .single_escape => try token.append(gpa, try self.nextCharOrEnd(), true),
                .multiple_escape => while (true) {
                    token.escaped = true;
                    const y = try self.nextCharOrEnd();
                    switch (self.syntaxOf(y)) {
                        .multiple_escape => {
                            token.escape_end = token.chars.items.len;
                            break;
                        },
                        .single_escape => try token.append(gpa, try self.nextCharOrEnd(), true),
                        else => try token.append(gpa, y, true),
                    }
                },
                .constituent, .non_terminating_macro => {
                    if (self.syntaxOf(x) == .constituent and readtable.invalidConstituent(x) and !self.suppress) {
                        return self.fail(Error.BadToken);
                    }
                    try token.append(gpa, x, false);
                },
                .terminating_macro => {
                    self.source.back(x);
                    return;
                },
                .whitespace => {
                    if (self.preserve_whitespace) self.source.back(x);
                    return;
                },
                .invalid => return self.fail(Error.BadToken),
            }
            x = self.nextChar() orelse return;
        }
    }

    fn interpretToken(self: *Reader, token: *Token, allow_dot: bool, start: Position) Error!Step {
        if (self.suppress) return .{ .value = value.NIL };
        const chars = token.chars.items;
        if (!token.escaped) {
            if (allDots(chars)) {
                if (chars.len == 1 and allow_dot) return .dot;
                return self.failAt(start, Error.BadToken);
            }
            if (try self.numberFromToken(chars, start)) |n| return .{ .value = n };
        }
        return .{ .value = try self.symbolFromToken(chars, token.escape_end, start) };
    }

    fn allDots(chars: []const TokenChar) bool {
        if (chars.len == 0) return false;
        for (chars) |c| if (c.code != '.') return false;
        return true;
    }

    /// The token's text, when every character of it is ASCII. The caller
    /// frees it.
    fn asciiText(self: *Reader, chars: []const TokenChar) Error!?[]u8 {
        for (chars) |c| if (c.code >= 0x80) return null;
        const text = try self.allocator().alloc(u8, chars.len);
        for (chars, text) |c, *out| out.* = @intCast(c.code);
        return text;
    }

    fn numberFromToken(self: *Reader, chars: []const TokenChar, start: Position) Error!?Value {
        const text = (try self.asciiText(chars)) orelse return null;
        defer self.allocator().free(text);
        const base = self.readBase();
        return switch (classifyNumber(text, base)) {
            .none => null,
            .integer => try self.integerFrom(text, base, start),
            .decimal_integer => try self.integerFrom(text[0 .. text.len - 1], 10, start),
            .ratio => try self.ratioFrom(text, base, start),
            .float => try self.floatFrom(text, start),
        };
    }

    fn readBase(self: *Reader) u8 {
        const cell = self.variable("*READ-BASE*") orelse return 10;
        if (!cell.isFixnum()) return 10;
        const n = cell.toFixnum();
        if (n < 2 or n > 36) return 10;
        return @intCast(n);
    }

    fn integerFrom(self: *Reader, text: []const u8, base: u8, start: Position) Error!Value {
        var negative = false;
        var digits = text;
        if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
            negative = digits[0] == '-';
            digits = digits[1..];
        }
        if (digits.len == 0) return self.failAt(start, Error.BadToken);
        var acc: i128 = 0;
        var fits = true;
        for (digits) |c| {
            const d = digitValue(c) orelse return self.failAt(start, Error.BadToken);
            if (d >= base) return self.failAt(start, Error.BadToken);
            acc = acc * base + d;
            if (acc > std.math.maxInt(i64)) {
                fits = false;
                break;
            }
        }
        if (fits) {
            const n: i64 = @intCast(if (negative) -acc else acc);
            if (n >= value.FIXNUM_MIN and n <= value.FIXNUM_MAX) return Value.fromFixnum(n);
        }
        const big = bignum.parse(self.heap, digits, base, negative) catch return self.failAt(start, Error.BadToken);
        return big orelse self.failAt(start, Error.BadToken);
    }

    fn ratioFrom(self: *Reader, text: []const u8, base: u8, start: Position) Error!Value {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return self.failAt(start, Error.BadToken);
        var held = self.heap.protect();
        defer held.close();
        try held.push(try self.integerFrom(text[0..slash], base, start));
        const den = try self.integerFrom(text[slash + 1 ..], base, start);
        if (den.isFixnum() and den.toFixnum() == 0) return self.failAt(start, Error.BadToken);
        return bignum.makeRatio(self.heap, held.items()[0], den) catch self.failAt(start, Error.BadToken);
    }

    fn floatFrom(self: *Reader, text: []const u8, start: Position) Error!Value {
        const scratch = try self.allocator().alloc(u8, text.len);
        defer self.allocator().free(scratch);
        const fv = float_parse.parseFloatInto(scratch, text, self.default_float) catch return self.failAt(start, Error.BadToken);
        return switch (fv) {
            .single => |x| if (std.math.isInf(x)) self.failAt(start, Error.BadToken) else Value.fromSingleFloat(x),
            .double => |x| if (std.math.isInf(x)) self.failAt(start, Error.BadToken) else try self.heap.allocDoubleFloat(x),
        };
    }

    /// The case `readtable-case` gives the unescaped characters of a
    /// token: `:invert` inverts only a token whose letters agree in case.
    fn effectiveCase(self: *Reader, chars: []const TokenChar) SymbolCase {
        if (self.case != .invert) return self.case;
        var upper = false;
        var lower = false;
        for (chars) |c| {
            if (c.escaped) continue;
            if (character.isUpper(c.code)) upper = true;
            if (character.isLower(c.code)) lower = true;
        }
        if (upper and !lower) return .downcase;
        if (lower and !upper) return .upcase;
        return .preserve;
    }

    /// The UTF-8 name `chars` spell with `case` applied to the unescaped
    /// ones.
    fn foldName(self: *Reader, chars: []const TokenChar, case: SymbolCase) Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator());
        for (chars) |c| {
            const code = if (c.escaped) c.code else switch (case) {
                .upcase => character.upcase(c.code),
                .downcase => character.downcase(c.code),
                .preserve, .invert => c.code,
            };
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &buf) catch return self.fail(Error.BadToken);
            try out.appendSlice(self.allocator(), buf[0..n]);
        }
        return out.toOwnedSlice(self.allocator());
    }

    fn symbolFromToken(self: *Reader, chars: []const TokenChar, escape_end: ?usize, start: Position) Error!Value {
        const case = self.effectiveCase(chars);
        var colons: [3]usize = undefined;
        var count: usize = 0;
        for (chars, 0..) |c, i| {
            if (c.escaped or c.code != ':') continue;
            if (count == colons.len) return self.failAt(start, Error.BadToken);
            colons[count] = i;
            count += 1;
        }
        if (count == 0) {
            const name = try self.foldName(chars, case);
            defer self.allocator().free(name);
            if (self.keyword_symbols) return self.interner.internKeyword(name);
            return self.interner.internCurrent(name);
        }
        const first = colons[0];
        const double = count == 2 and colons[1] == first + 1;
        if (count > 2 or (count == 2 and !double)) return self.failAt(start, Error.BadToken);
        const name_start = first + count;
        const escaped_name = if (escape_end) |at| at >= name_start else false;
        if (name_start >= chars.len and first != 0 and !escaped_name) return self.failAt(start, Error.BadToken);
        const name = try self.foldName(chars[name_start..], case);
        defer self.allocator().free(name);
        if (first == 0) return self.interner.internKeyword(name);
        const package_name = try self.foldName(chars[0..first], case);
        defer self.allocator().free(package_name);
        const pkg = self.interner.registry.find(package_name) orelse
            return self.failAt(start, Error.NoSuchPackage);
        if (double) return self.interner.internIn(pkg, name);
        const found = pkg.findSymbol(name) orelse return self.failAt(start, Error.SymbolNotExternal);
        if (found.status != .external) return self.failAt(start, Error.SymbolNotExternal);
        return found.sym;
    }

    // --- macro characters --------------------------------------------

    fn builtinMacro(self: *Reader, which: Builtin, c: u21, arg: ?Value) Error!Step {
        const v: Value = switch (which) {
            .left_paren => blk: {
                const list = try self.readDelimited(')', true, self.char_pos);
                break :blk if (self.suppress) value.NIL else list;
            },
            .right_paren => return self.fail(Error.UnbalancedParens),
            .quote => try self.wrapNext("QUOTE"),
            .semicolon => {
                while (self.nextChar()) |ch| if (ch == '\n') break;
                return .none;
            },
            .double_quote => try self.readString(c),
            .backquote => blk: {
                self.backquote_depth += 1;
                defer self.backquote_depth -= 1;
                break :blk try self.wrapNext("QUASIQUOTE");
            },
            .comma => blk: {
                if (self.backquote_depth == 0 and !self.suppress) return self.fail(Error.BadToken);
                var name: []const u8 = "UNQUOTE";
                if (self.source.peek()) |next| {
                    if (next == '@' or next == '.') {
                        _ = self.nextChar();
                        name = "UNQUOTE-SPLICING";
                    }
                }
                const depth = self.backquote_depth;
                self.backquote_depth -|= 1;
                defer self.backquote_depth = depth;
                break :blk try self.wrapNext(name);
            },
            .dispatch => return self.fail(Error.BadToken),
            else => return self.sharpMacro(which, c, arg),
        };
        return .{ .value = v };
    }

    /// `(name object)` for the next object, or NIL under suppression.
    fn wrapNext(self: *Reader, name: []const u8) Error!Value {
        const start = self.char_pos;
        const inner = try self.readObject();
        if (self.suppress) return value.NIL;
        var held = self.heap.protect();
        defer held.close();
        try held.push(inner);
        const sym = try self.interner.intern(name);
        const tail = try self.allocConsAt(inner, value.NIL, start);
        held.setItem(0, tail);
        return self.allocConsAt(sym, tail, start);
    }

    fn allocConsAt(self: *Reader, car_v: Value, cdr_v: Value, pos: Position) Error!Value {
        const cell = try self.heap.allocCons(car_v, cdr_v);
        if (self.positions) |table| {
            try table.record(cell, .{ .file = self.file, .line = pos.line, .column = pos.column });
        }
        return cell;
    }

    /// The objects up to `close`, as a list. `allow_dot` permits a dotted
    /// tail, which is what `(` reads and `read-delimited-list` does not.
    fn readDelimited(self: *Reader, close: u21, allow_dot: bool, open_pos: Position) Error!Value {
        var held = self.heap.protect();
        defer held.close();
        try held.push(value.NIL);
        var tail: Value = value.NIL;
        while (true) {
            const c = self.skipWhitespace() orelse return self.failAt(open_pos, Error.EndOfInput);
            if (c == close) return held.items()[0];
            const elem_pos = self.char_pos;
            switch (try self.readStep(c, allow_dot)) {
                .none => {},
                .value => |elem| {
                    const cell_pos = if (tail.equalsRaw(value.NIL)) open_pos else elem_pos;
                    const cell = try self.allocConsAt(elem, value.NIL, cell_pos);
                    if (tail.equalsRaw(value.NIL)) {
                        held.setItem(0, cell);
                    } else {
                        heap_mod.setCdr(self.heap, tail, cell);
                    }
                    tail = cell;
                },
                .dot => {
                    if (tail.equalsRaw(value.NIL)) return self.fail(Error.BadToken);
                    const rest = try self.readDottedTail();
                    heap_mod.setCdr(self.heap, tail, rest);
                    try self.expectClose(close, open_pos);
                    return held.items()[0];
                },
            }
        }
    }

    fn readDottedTail(self: *Reader) Error!Value {
        while (true) {
            const c = self.skipWhitespace() orelse return self.fail(Error.EndOfInput);
            if (c == ')') return self.fail(Error.BadToken);
            switch (try self.readStep(c, false)) {
                .value => |v| return v,
                .none => {},
                .dot => return self.fail(Error.BadToken),
            }
        }
    }

    /// Only comments may come between a dotted tail and the `)`.
    fn expectClose(self: *Reader, close: u21, open_pos: Position) Error!void {
        while (true) {
            const c = self.skipWhitespace() orelse return self.failAt(open_pos, Error.EndOfInput);
            if (c == close) return;
            switch (try self.readStep(c, false)) {
                .none => {},
                else => return self.fail(Error.BadToken),
            }
        }
    }

    /// A string up to the next unescaped `close`.
    fn readString(self: *Reader, close: u21) Error!Value {
        var codes: std.ArrayListUnmanaged(u32) = .empty;
        defer codes.deinit(self.allocator());
        while (true) {
            var c = try self.nextCharOrEnd();
            if (c == close) break;
            if (self.syntaxOf(c) == .single_escape) c = try self.nextCharOrEnd();
            try codes.append(self.allocator(), c);
        }
        if (self.suppress) return value.NIL;
        return self.heap.allocStringFromChars(codes.items);
    }

    // --- dispatching macro characters --------------------------------

    fn readDispatch(self: *Reader, dispatch: Value) Error!Step {
        const start = self.char_pos;
        var arg: ?u64 = null;
        const digits_start = self.source.idx;
        var sub = try self.nextCharOrEnd();
        var overflow = false;
        while (sub >= '0' and sub <= '9') {
            const d: u64 = sub - '0';
            const so_far = arg orelse 0;
            const times = @mulWithOverflow(so_far, 10);
            const plus = @addWithOverflow(times[0], d);
            if (times[1] != 0 or plus[1] != 0) overflow = true;
            arg = plus[0];
            sub = try self.nextCharOrEnd();
        }
        const digits_end = self.source.idx - self.source.last_width;
        if (dispatch.equalsRaw(value.NIL)) return self.failAt(start, Error.BadToken);
        const f = readtable.subFunction(dispatch, sub);
        if (f.equalsRaw(value.NIL)) return self.failAt(start, Error.BadToken);

        var arg_value: ?Value = null;
        if (arg) |n| {
            arg_value = if (!overflow and n <= value.FIXNUM_MAX)
                Value.fromFixnum(@intCast(n))
            else
                try self.integerFrom(self.source.src[digits_start..digits_end], 10, start);
        }
        if (readtable.asBuiltin(f)) |b| return self.sharpMacro(b, sub, arg_value);
        const result = try self.callLisp(f, &.{ value.NIL, Value.fromChar(sub), arg_value orelse value.NIL });
        return if (result) |v| .{ .value = v } else .none;
    }

    /// The numeric argument of a dispatching macro, as a count.
    fn argCount(self: *Reader, arg: ?Value) Error!?usize {
        const a = arg orelse return null;
        if (!a.isFixnum()) return self.fail(Error.BadToken);
        return @intCast(a.toFixnum());
    }

    fn sharpMacro(self: *Reader, which: Builtin, sub: u21, arg: ?Value) Error!Step {
        const v: Value = switch (which) {
            .sharp_backslash => try self.readCharacter(),
            .sharp_quote => try self.wrapNext("FUNCTION"),
            .sharp_left_paren => try self.readVector(arg),
            .sharp_asterisk => try self.readBitVector(arg),
            .sharp_colon => try self.readUninterned(),
            .sharp_dot => try self.readEval(),
            .sharp_b => try self.readRational(2),
            .sharp_o => try self.readRational(8),
            .sharp_x => try self.readRational(16),
            .sharp_r => blk: {
                if (self.suppress) break :blk try self.readRational(10);
                const radix = (try self.argCount(arg)) orelse return self.fail(Error.BadToken);
                if (radix < 2 or radix > 36) return self.fail(Error.BadToken);
                break :blk try self.readRational(@intCast(radix));
            },
            .sharp_c => try self.readComplex(),
            .sharp_a => try self.readArray(arg),
            .sharp_s => try self.readStructure(),
            .sharp_p => try self.readPathname(),
            .sharp_equal => try self.readLabelDefinition(arg),
            .sharp_sharp => try self.readLabelReference(arg),
            .sharp_plus => return self.readConditional(true),
            .sharp_minus => return self.readConditional(false),
            .sharp_bar => {
                try self.skipBlockComment();
                return .none;
            },
            else => return self.builtinMacro(which, sub, arg),
        };
        return .{ .value = v };
    }

    /// `#\x`: the token that starts with `x` taken as escaped names a
    /// character, by being one or by its name.
    fn readCharacter(self: *Reader) Error!Value {
        const start = self.char_pos;
        const first = try self.nextCharOrEnd();
        var token: Token = .{};
        defer token.deinit(self.allocator());
        try self.readToken(&token, first, true);
        if (self.suppress) return value.NIL;
        const chars = token.chars.items;
        if (chars.len == 1) return Value.fromChar(chars[0].code);
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        for (chars) |c| {
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c.code, &enc) catch return self.failAt(start, Error.BadToken);
            if (len + n > buf.len) return self.failAt(start, Error.BadToken);
            @memcpy(buf[len..][0..n], enc[0..n]);
            len += n;
        }
        const code = decodeCharName(buf[0..len]) orelse return self.failAt(start, Error.BadToken);
        return Value.fromChar(code);
    }

    /// `#(...)`, or `#n(...)`, whose last element fills the rest.
    fn readVector(self: *Reader, arg: ?Value) Error!Value {
        const start = self.char_pos;
        var held = self.heap.protect();
        defer held.close();
        while (true) {
            const c = self.skipWhitespace() orelse return self.failAt(start, Error.EndOfInput);
            if (c == ')') break;
            switch (try self.readStep(c, false)) {
                .value => |elem| try held.push(elem),
                .none => {},
                .dot => return self.fail(Error.BadToken),
            }
        }
        if (self.suppress) return value.NIL;
        const elements = held.items();
        const length = (try self.argCount(arg)) orelse return self.heap.allocVector(elements);
        if (elements.len > length) return self.fail(Error.BadToken);
        if (elements.len == 0 and length > 0) return self.fail(Error.BadToken);
        const v = try self.heap.allocArray(&.{length}, .t);
        const slots = heap_mod.arrayElements(v);
        for (slots, 0..) |*slot, i| slot.* = elements[@min(i, elements.len - 1)];
        return v;
    }

    /// `#*bits`, or `#n*bits`, whose last bit fills the rest.
    fn readBitVector(self: *Reader, arg: ?Value) Error!Value {
        var token: Token = .{};
        defer token.deinit(self.allocator());
        if (self.source.peek()) |first| {
            const syntax = self.syntaxOf(first);
            if (syntax != .whitespace and syntax != .terminating_macro) {
                _ = self.nextChar();
                try self.readToken(&token, first, false);
            }
        }
        if (self.suppress) return value.NIL;
        const bits = token.chars.items;
        for (bits) |b| {
            if (b.escaped or (b.code != '0' and b.code != '1')) return self.fail(Error.BadToken);
        }
        const length = (try self.argCount(arg)) orelse bits.len;
        if (bits.len > length) return self.fail(Error.BadToken);
        if (bits.len == 0 and length > 0) return self.fail(Error.BadToken);
        const v = try self.heap.allocArray(&.{length}, .bit);
        for (heap_mod.arrayElements(v), 0..) |*slot, i| {
            slot.* = Value.fromFixnum(if (bits[@min(i, bits.len - 1)].code == '1') 1 else 0);
        }
        return v;
    }

    /// The token after a dispatching macro, read as one with no package
    /// markers.
    fn readFollowingToken(self: *Reader, token: *Token) Error!void {
        const first = self.nextChar() orelse return self.fail(Error.EndOfInput);
        switch (self.syntaxOf(first)) {
            .constituent, .non_terminating_macro, .single_escape, .multiple_escape => try self.readToken(token, first, false),
            else => {
                self.source.back(first);
                if (!self.suppress) return self.fail(Error.BadToken);
            },
        }
    }

    fn readUninterned(self: *Reader) Error!Value {
        const start = self.char_pos;
        var token: Token = .{};
        defer token.deinit(self.allocator());
        if (self.source.peek()) |first| {
            const syntax = self.syntaxOf(first);
            if (syntax != .whitespace and syntax != .terminating_macro) {
                _ = self.nextChar();
                try self.readToken(&token, first, false);
            }
        }
        if (self.suppress) return value.NIL;
        const chars = token.chars.items;
        for (chars) |c| {
            if (!c.escaped and c.code == ':') return self.failAt(start, Error.BadToken);
        }
        const name = try self.foldName(chars, self.effectiveCase(chars));
        defer self.allocator().free(name);
        return self.interner.makeUninterned(name);
    }

    /// `#.form`: the value of the form, evaluated now.
    fn readEval(self: *Reader) Error!Value {
        const form = try self.readObject();
        if (self.suppress) return value.NIL;
        if (self.variable("*READ-EVAL*")) |cell| {
            if (cell.equalsRaw(value.NIL)) return self.fail(Error.BadToken);
        }
        const host = self.host orelse return self.fail(Error.BadToken);
        var held = self.heap.protect();
        defer held.close();
        try held.push(form);
        return host.eval(host.context, form);
    }

    /// `#B`, `#O`, `#X` and `#nR`: a rational in that radix.
    fn readRational(self: *Reader, radix: u8) Error!Value {
        const start = self.char_pos;
        var token: Token = .{};
        defer token.deinit(self.allocator());
        try self.readFollowingToken(&token);
        if (self.suppress) return value.NIL;
        if (token.escaped) return self.failAt(start, Error.BadToken);
        const text = (try self.asciiText(token.chars.items)) orelse return self.failAt(start, Error.BadToken);
        defer self.allocator().free(text);
        return switch (classifyNumber(text, radix)) {
            .integer => self.integerFrom(text, radix, start),
            .ratio => self.ratioFrom(text, radix, start),
            else => self.failAt(start, Error.BadToken),
        };
    }

    /// `#C(real imaginary)`.
    fn readComplex(self: *Reader) Error!Value {
        const start = self.char_pos;
        const parts = try self.readObject();
        if (self.suppress) return value.NIL;
        if (!parts.isCons()) return self.failAt(start, Error.BadToken);
        const rest = heap_mod.cdr(parts);
        if (!rest.isCons() or !heap_mod.cdr(rest).equalsRaw(value.NIL)) return self.failAt(start, Error.BadToken);
        return complex.make(self.heap, heap_mod.car(parts), heap_mod.car(rest)) catch self.failAt(start, Error.BadToken);
    }

    /// `#nA contents`: an array of rank n whose dimensions are the lengths
    /// of the first sequence at each level of `contents`.
    fn readArray(self: *Reader, arg: ?Value) Error!Value {
        const start = self.char_pos;
        const contents = try self.readObject();
        if (self.suppress) return value.NIL;
        const rank = (try self.argCount(arg)) orelse return self.failAt(start, Error.BadToken);
        if (rank >= heap_mod.ARRAY_RANK_LIMIT) return self.failAt(start, Error.BadToken);
        var held = self.heap.protect();
        defer held.close();
        try held.push(contents);
        const sizes = try self.allocator().alloc(usize, rank);
        defer self.allocator().free(sizes);
        var level = contents;
        for (sizes) |*size| {
            size.* = sequenceLength(level) orelse return self.failAt(start, Error.BadToken);
            if (size.* > 0) level = sequenceElement(level, 0);
        }
        var elements: std.ArrayListUnmanaged(Value) = .empty;
        defer elements.deinit(self.allocator());
        if (!try flattenArrayContents(self.allocator(), contents, sizes, &elements)) return self.failAt(start, Error.BadToken);
        const result = try self.heap.allocArray(sizes, .t);
        @memcpy(heap_mod.arrayElements(result), elements.items);
        return result;
    }

    /// `#S(name slot value ...)`, which the host builds.
    fn readStructure(self: *Reader) Error!Value {
        const start = self.char_pos;
        const form = try self.readObject();
        if (self.suppress) return value.NIL;
        if (!form.isCons()) return self.failAt(start, Error.BadToken);
        const found = self.interner.cl.findPresent("%READ-STRUCTURE") orelse return self.failAt(start, Error.BadToken);
        const f = symbol.symbol(found.sym).function_cell;
        const host = self.host orelse return self.failAt(start, Error.BadToken);
        var held = self.heap.protect();
        defer held.close();
        try held.push(form);
        const made = (try host.call(host.context, f, &.{form})) orelse value.NIL;
        if (made.equalsRaw(value.NIL)) return self.failAt(start, Error.BadToken);
        return made;
    }

    /// `#P"namestring"`.
    fn readPathname(self: *Reader) Error!Value {
        const start = self.char_pos;
        const namestring = try self.readObject();
        if (self.suppress) return value.NIL;
        if (!heap_mod.isString(namestring)) return self.failAt(start, Error.BadToken);
        if (!pathnames_available) return self.failAt(start, Error.BadToken);
        const text = try heap_mod.stringUtf8Alloc(self.allocator(), namestring);
        defer self.allocator().free(text);
        return pathname_mod.parseText(self.heap, self.interner, text) catch self.failAt(start, Error.BadToken);
    }

    fn skipBlockComment(self: *Reader) Error!void {
        var depth: usize = 1;
        var previous: u21 = 0;
        while (depth > 0) {
            const c = try self.nextCharOrEnd();
            if (previous == '|' and c == '#') {
                depth -= 1;
                previous = 0;
            } else if (previous == '#' and c == '|') {
                depth += 1;
                previous = 0;
            } else {
                previous = c;
            }
        }
    }

    // --- labels ------------------------------------------------------

    fn labelsAlist(self: *Reader) Value {
        const region = self.labels orelse return value.NIL;
        return region.items()[LABELS_SLOT];
    }

    fn labelEntry(self: *Reader, number: Value) ?Value {
        var rest = self.labelsAlist();
        while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
            const entry = heap_mod.car(rest);
            if (heap_mod.car(entry).equalsRaw(number)) return entry;
        }
        return null;
    }

    /// `#n=object`: OBJECT, which `#n#` names for the rest of the read.
    /// A reference inside OBJECT reads as a placeholder that is replaced
    /// by OBJECT once it is complete.
    fn readLabelDefinition(self: *Reader, arg: ?Value) Error!Value {
        if (self.suppress) {
            _ = try self.readObject();
            return value.NIL;
        }
        const start = self.char_pos;
        const number = arg orelse return self.failAt(start, Error.BadToken);
        const region = self.labels orelse return self.failAt(start, Error.BadToken);
        if (self.labelEntry(number) != null) return self.failAt(start, Error.BadToken);
        var held = self.heap.protect();
        defer held.close();
        try held.push(try self.heap.allocCons(value.NIL, value.NIL));
        const placeholder = held.items()[0];
        const entry = try self.heap.allocCons(number, placeholder);
        region.setItem(LABELS_SLOT, try self.heap.allocCons(entry, region.items()[LABELS_SLOT]));
        const object = try self.readObject();
        if (object.equalsRaw(placeholder)) return self.failAt(start, Error.BadToken);
        heap_mod.setCdr(self.heap, entry, object);
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(self.allocator());
        return self.replacePlaceholder(object, placeholder, object, &seen);
    }

    fn readLabelReference(self: *Reader, arg: ?Value) Error!Value {
        if (self.suppress) return value.NIL;
        const number = arg orelse return self.fail(Error.BadToken);
        const entry = self.labelEntry(number) orelse return self.fail(Error.BadToken);
        return heap_mod.cdr(entry);
    }

    /// TREE with every occurrence of PLACEHOLDER in its conses and its
    /// vectors replaced by OBJECT, in place.
    fn replacePlaceholder(
        self: *Reader,
        tree: Value,
        placeholder: Value,
        object: Value,
        seen: *std.AutoHashMapUnmanaged(u64, void),
    ) Error!Value {
        if (tree.equalsRaw(placeholder)) return object;
        if (tree.isCons()) {
            if ((try seen.getOrPut(self.allocator(), tree.raw)).found_existing) return tree;
            var rest = tree;
            while (rest.isCons()) {
                const head = heap_mod.car(rest);
                const replaced = try self.replacePlaceholder(head, placeholder, object, seen);
                if (!replaced.equalsRaw(head)) heap_mod.setCar(self.heap, rest, replaced);
                const next = heap_mod.cdr(rest);
                if (next.equalsRaw(placeholder)) {
                    heap_mod.setCdr(self.heap, rest, object);
                    break;
                }
                if (!next.isCons()) break;
                if ((try seen.getOrPut(self.allocator(), next.raw)).found_existing) break;
                rest = next;
            }
            return tree;
        }
        if (heap_mod.isArray(tree)) {
            if ((try seen.getOrPut(self.allocator(), tree.raw)).found_existing) return tree;
            const a = heap_mod.asArray(tree);
            if (a.element_type != .t) return tree;
            for (heap_mod.arrayElements(tree), 0..) |element, index| {
                const replaced = try self.replacePlaceholder(element, placeholder, object, seen);
                if (!replaced.equalsRaw(element)) heap_mod.setSlot(self.heap, tree, index, replaced);
            }
        }
        return tree;
    }

    // --- feature expressions -----------------------------------------

    /// `#+` and `#-`: read a feature expression as keywords with
    /// suppression off, then the next object, which is kept when the
    /// expression's truth is `want` and otherwise read suppressed and
    /// dropped.
    fn readConditional(self: *Reader, want: bool) Error!Step {
        const outer_suppress = self.suppress;
        const outer_keywords = self.keyword_symbols;
        self.suppress = false;
        self.keyword_symbols = true;
        const expr = self.readObject() catch |err| {
            self.suppress = outer_suppress;
            self.keyword_symbols = outer_keywords;
            return err;
        };
        self.suppress = outer_suppress;
        self.keyword_symbols = outer_keywords;
        const present = try self.evalFeatureExpr(expr);
        if (present == want) return .{ .value = try self.readObject() };
        self.suppress = true;
        defer self.suppress = outer_suppress;
        _ = try self.readObject();
        return .none;
    }

    /// True if `query` is one of the features in effect.
    pub fn hasFeature(self: *Reader, query: Value) bool {
        if (self.features) |given| {
            for (given) |f| if (f.equalsRaw(query)) return true;
            return false;
        }
        const cell = self.variable("*FEATURES*") orelse return false;
        var rest = cell.*;
        while (rest.isCons()) : (rest = heap_mod.cdr(rest)) {
            if (heap_mod.car(rest).equalsRaw(query)) return true;
        }
        return false;
    }

    /// CLHS 24.1.2.1.1: a symbol is true when it is a feature, `(or
    /// e...)` is false when empty, `(and e...)` true when empty, and
    /// `(not e)` takes exactly one operand.
    pub fn evalFeatureExpr(self: *Reader, expr: Value) Error!bool {
        if (expr.isSymbol()) return self.hasFeature(expr);
        if (!expr.isCons()) return Error.BadToken;
        const op_v = heap_mod.car(expr);
        if (!op_v.isSymbol()) return Error.BadToken;
        const op_name = symbol.name(op_v);
        var args = heap_mod.cdr(expr);
        if (std.ascii.eqlIgnoreCase(op_name, "OR")) {
            while (args.isCons()) : (args = heap_mod.cdr(args)) {
                if (try self.evalFeatureExpr(heap_mod.car(args))) return true;
            }
            if (!args.equalsRaw(value.NIL)) return Error.BadToken;
            return false;
        }
        if (std.ascii.eqlIgnoreCase(op_name, "AND")) {
            while (args.isCons()) : (args = heap_mod.cdr(args)) {
                if (!try self.evalFeatureExpr(heap_mod.car(args))) return false;
            }
            if (!args.equalsRaw(value.NIL)) return Error.BadToken;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(op_name, "NOT")) {
            if (!args.isCons()) return Error.BadToken;
            const only = heap_mod.car(args);
            if (!heap_mod.cdr(args).equalsRaw(value.NIL)) return Error.BadToken;
            return !(try self.evalFeatureExpr(only));
        }
        return Error.BadToken;
    }
};

// --- numbers ---------------------------------------------------------

const NumberKind = enum { none, integer, decimal_integer, ratio, float };

/// Which number syntax of CLHS 2.3.1 `text` has, integers being read in
/// `base` and floats always in decimal. An integer reading takes
/// precedence, which is how `1e5` is an integer in base sixteen.
fn classifyNumber(text: []const u8, base: u8) NumberKind {
    var i: usize = 0;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) i = 1;
    const body = text[i..];
    if (body.len == 0) return .none;

    if (allDigitsIn(body, base)) return .integer;
    if (body.len > 1 and body[body.len - 1] == '.' and allDigitsIn(body[0 .. body.len - 1], 10)) return .decimal_integer;
    if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
        if (slash > 0 and slash + 1 < body.len and allDigitsIn(body[0..slash], base) and allDigitsIn(body[slash + 1 ..], base)) {
            return .ratio;
        }
        return .none;
    }
    return if (isFloatSyntax(body)) .float else .none;
}

fn allDigitsIn(text: []const u8, base: u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        const d = digitValue(c) orelse return false;
        if (d >= base) return false;
    }
    return true;
}

/// `{digit}* . {digit}+ [exponent]` or `{digit}+ [. {digit}*] exponent`.
fn isFloatSyntax(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len and std.ascii.isDigit(body[i])) i += 1;
    const before = i;
    var after: usize = 0;
    var point = false;
    if (i < body.len and body[i] == '.') {
        point = true;
        i += 1;
        const start = i;
        while (i < body.len and std.ascii.isDigit(body[i])) i += 1;
        after = i - start;
    }
    if (i == body.len) return point and after > 0;
    if (before + after == 0) return false;
    if (!isExponentMarker(body[i])) return false;
    i += 1;
    if (i < body.len and (body[i] == '+' or body[i] == '-')) i += 1;
    const exp_start = i;
    while (i < body.len and std.ascii.isDigit(body[i])) i += 1;
    return i == body.len and i > exp_start;
}

fn isExponentMarker(c: u8) bool {
    return switch (c) {
        'e', 'E', 's', 'S', 'f', 'F', 'd', 'D', 'l', 'L' => true,
        else => false,
    };
}

fn digitValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => null,
    };
}

// --- arrays ----------------------------------------------------------

fn flattenArrayContents(gpa: std.mem.Allocator, contents: Value, sizes: []const usize, out: *std.ArrayListUnmanaged(Value)) !bool {
    if (sizes.len == 0) {
        try out.append(gpa, contents);
        return true;
    }
    if (sequenceLength(contents) != sizes[0]) return false;
    for (0..sizes[0]) |index| {
        if (!try flattenArrayContents(gpa, sequenceElement(contents, index), sizes[1..], out)) return false;
    }
    return true;
}

fn sequenceLength(v: Value) ?usize {
    if (v.equalsRaw(value.NIL)) return 0;
    if (v.isCons()) {
        var count: usize = 0;
        var rest = v;
        while (rest.isCons()) : (rest = heap_mod.cdr(rest)) count += 1;
        return if (rest.equalsRaw(value.NIL)) count else null;
    }
    if (heap_mod.isString(v)) return heap_mod.asString(v).slice().len;
    if (heap_mod.isArray(v) and heap_mod.asArray(v).rank == 1) return activeLength(v);
    return null;
}

/// How many elements a vector has, up to its fill pointer.
fn activeLength(v: Value) usize {
    const a = heap_mod.asArray(v);
    if (a.has_fill_pointer) return @intCast(a.fill_pointer);
    return heap_mod.arrayElements(v).len;
}

fn sequenceElement(v: Value, index: usize) Value {
    if (v.isCons()) {
        var rest = v;
        for (0..index) |_| rest = heap_mod.cdr(rest);
        return heap_mod.car(rest);
    }
    if (heap_mod.isString(v)) return Value.fromChar(@intCast(heap_mod.asString(v).slice()[index]));
    return heap_mod.arrayElements(v)[index];
}

// --- characters ------------------------------------------------------

/// The character a name of more than one character names.
fn decodeCharName(text: []const u8) ?u21 {
    return character.codeForName(text);
}
