//! Common Lisp printer (ROADMAP Phase 1.3).
//!
//! Three CL-named entry points share one core driver `write`:
//!
//!   * `prin1`  — readable, with escapes (`*print-escape*` T)
//!   * `princ`  — human, no escapes (`*print-escape*` NIL, `*print-readably*` NIL)
//!   * `print`  — newline + prin1 + space (CL's "fresh-line + readable + space")
//!
//! Settings track `*print-readably*` / `*print-escape*` / `*print-base*` /
//! `*print-radix*`. `*print-circle*` (1.3.5) only requires the safe-from-
//! infinite-loop minimum here — cycles print as `#<cycle>` placeholders
//! rather than the full `#1=` / `#1#` markers, which wait for the pretty
//! printer at Phase 4.10.
//!
//! For backward compatibility with Phase-0 callers, the bare `print` /
//! `printToOwnedSlice` driver functions kept their prin1-style defaults
//! and live alongside the CL-named variants.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const symbol = @import("symbol.zig");
const Value = value.Value;

const MAX_DEPTH: u32 = 1024;

/// Mirrors the CL `*print-...*` variables. The eventual special-variable
/// plumbing (Phase 2) will read these out of the dynamic environment;
/// Phase 1 just passes them per call.
pub const Settings = struct {
    /// `*print-escape*` — wrap strings in quotes, escape symbols, etc.
    escape: bool = true,
    /// `*print-readably*` — when true, escape regardless of `escape`.
    /// CLHS 22.1.3.5: readably output must round-trip via `read`.
    readably: bool = false,
    /// `*print-base*` — radix used for integer/ratio output; clamped to
    /// `[2, 36]`. Defaults to 10.
    base: u8 = 10,
    /// `*print-radix*` — when true, prefix radix indicator (`#b`, `#o`,
    /// `#x`, or `#nnR`) ahead of integers and ratios.
    radix: bool = false,
};

/// `prin1` defaults: `*print-escape*` T.
pub const PRIN1: Settings = .{ .escape = true, .readably = false };

/// `princ` defaults: `*print-escape*` NIL, `*print-readably*` NIL.
pub const PRINC: Settings = .{ .escape = false, .readably = false };

const PrintCtx = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(u64, void),
    settings: Settings,

    fn effectiveEscape(self: *const PrintCtx) bool {
        return self.settings.escape or self.settings.readably;
    }
};

const PrintError = std.Io.Writer.Error || std.mem.Allocator.Error;

/// Write `v` to `writer` using the supplied settings. The other entry
/// points are thin wrappers around this one.
pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value, settings: Settings) PrintError!void {
    var ctx: PrintCtx = .{
        .writer = writer,
        .allocator = allocator,
        .seen = .{},
        .settings = settings,
    };
    defer ctx.seen.deinit(allocator);
    try printValue(&ctx, v, 0);
}

/// 1.3.1. Readable output: strings quoted, symbols pipe-escaped when
/// they couldn't round-trip otherwise, characters as `#\X`/`#\Name`.
pub fn prin1(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    return write(allocator, writer, v, PRIN1);
}

/// 1.3.2. Human output: strings unquoted, symbols as bare names,
/// characters written as the character itself.
pub fn princ(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    return write(allocator, writer, v, PRINC);
}

/// 1.3.3. CL `print`: leading newline, then prin1, then trailing space.
pub fn print(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    try writer.writeByte('\n');
    try prin1(allocator, writer, v);
    try writer.writeByte(' ');
}

/// Phase-0 alias kept for callers that pre-date the CL-named entries.
/// Equivalent to `prin1` (readable form).
pub fn printValueDefault(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    return prin1(allocator, writer, v);
}

fn printValue(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    if (depth > MAX_DEPTH) {
        try ctx.writer.writeAll("#<deep>");
        return;
    }
    if (v.equalsRaw(value.NIL)) {
        try ctx.writer.writeAll("NIL");
        return;
    }
    switch (v.tag()) {
        .fixnum => try printInteger(ctx, v.toFixnum()),
        .cons => try printCons(ctx, v, depth),
        .symbol => try printSymbol(ctx, v),
        .heap => try printHeap(ctx, v, depth),
        .char => try printChar(ctx, v.toChar()),
        .special => try printSpecial(ctx, v),
        else => try ctx.writer.writeAll("#<?>"),
    }
}

fn printInteger(ctx: *PrintCtx, n: i64) PrintError!void {
    const base = clampBase(ctx.settings.base);
    if (ctx.settings.radix) try writeRadixPrefix(ctx, base);
    try writeIntegerInBase(ctx.writer, n, base);
    if (ctx.settings.radix and base == 10) {
        // CL writes a trailing `.` for base-10 integers when radix is
        // requested (`#10R12` is unusual; `12.` is the conventional form).
        try ctx.writer.writeByte('.');
    }
}

fn clampBase(base: u8) u8 {
    if (base < 2) return 2;
    if (base > 36) return 36;
    return base;
}

fn writeRadixPrefix(ctx: *PrintCtx, base: u8) PrintError!void {
    switch (base) {
        2 => try ctx.writer.writeAll("#b"),
        8 => try ctx.writer.writeAll("#o"),
        16 => try ctx.writer.writeAll("#x"),
        10 => {}, // trailing `.` instead, written after the digits
        else => try ctx.writer.print("#{d}r", .{base}),
    }
}

fn writeIntegerInBase(writer: *std.Io.Writer, n: i64, base: u8) PrintError!void {
    if (n == 0) {
        try writer.writeByte('0');
        return;
    }
    var buf: [65]u8 = undefined;
    var len: usize = 0;
    var negative = false;
    var u: u128 = blk: {
        if (n < 0) {
            negative = true;
            // Use u128 so `i64.min` doesn't overflow on negation.
            break :blk @as(u128, @intCast(-@as(i128, n)));
        }
        break :blk @as(u128, @intCast(n));
    };
    while (u > 0) : (len += 1) {
        const d = @as(u8, @intCast(u % base));
        u /= base;
        buf[len] = digitChar(d);
    }
    if (negative) {
        buf[len] = '-';
        len += 1;
    }
    // Reverse into the writer.
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        try writer.writeByte(buf[i]);
    }
}

fn digitChar(d: u8) u8 {
    return if (d < 10) '0' + d else 'A' + (d - 10);
}

fn printSymbol(ctx: *PrintCtx, v: Value) PrintError!void {
    const name = symbol.name(v);
    if (ctx.effectiveEscape() and needsSymbolEscape(name)) {
        try ctx.writer.writeByte('|');
        for (name) |c| {
            if (c == '|' or c == '\\') try ctx.writer.writeByte('\\');
            try ctx.writer.writeByte(c);
        }
        try ctx.writer.writeByte('|');
        return;
    }
    try ctx.writer.writeAll(name);
}

/// True if `name` needs `|...|` escaping to round-trip through the
/// reader. Empty names, names that would lex as numbers, or names that
/// contain characters outside CL's reader-safe set all need escaping.
fn needsSymbolEscape(name: []const u8) bool {
    if (name.len == 0) return true;
    if (looksLikeNumber(name)) return true;
    for (name) |c| {
        if (!isSafeSymbolChar(c)) return true;
    }
    return false;
}

fn looksLikeNumber(name: []const u8) bool {
    var i: usize = 0;
    if (i < name.len and (name[i] == '+' or name[i] == '-')) i += 1;
    if (i >= name.len) return false;
    if (name[i] == '.') {
        // `.` alone, or `.foo` — not a number unless followed by a digit.
        if (i + 1 < name.len and std.ascii.isDigit(name[i + 1])) return true;
        return false;
    }
    return std.ascii.isDigit(name[i]);
}

fn isSafeSymbolChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', '0'...'9' => true,
        '!', '$', '%', '&', '*', '+', '-', '.', '/', ':', '<', '=', '>', '?', '@', '^', '_', '~' => true,
        else => false,
    };
}

fn printHeap(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    switch (heap.heapType(v)) {
        .string => try printString(ctx, heap.asString(v).constSlice()),
        .single_float => {
            const x = heap.asSingleFloat(v).value;
            try ctx.writer.print("{e}", .{x});
        },
        .double_float => {
            const x = heap.asDoubleFloat(v).value;
            try ctx.writer.print("{e}d0", .{x});
        },
        .ratio => {
            const r = heap.asRatio(v);
            try printRatio(ctx, r.numerator, r.denominator);
        },
        .vector => {
            try ctx.writer.writeAll("#(");
            const items = heap.asVector(v).constSlice();
            for (items, 0..) |elem, i| {
                if (i != 0) try ctx.writer.writeByte(' ');
                try printValue(ctx, elem, depth + 1);
            }
            try ctx.writer.writeByte(')');
        },
        else => try ctx.writer.print("#<heap-object {x}>", .{v.toHeapAddr()}),
    }
}

fn printString(ctx: *PrintCtx, s: []const u8) PrintError!void {
    if (ctx.effectiveEscape()) {
        try ctx.writer.writeByte('"');
        for (s) |c| {
            if (c == '"' or c == '\\') try ctx.writer.writeByte('\\');
            try ctx.writer.writeByte(c);
        }
        try ctx.writer.writeByte('"');
    } else {
        try ctx.writer.writeAll(s);
    }
}

fn printRatio(ctx: *PrintCtx, num: i64, den: i64) PrintError!void {
    const base = clampBase(ctx.settings.base);
    if (ctx.settings.radix) try writeRadixPrefix(ctx, base);
    try writeIntegerInBase(ctx.writer, num, base);
    try ctx.writer.writeByte('/');
    try writeIntegerInBase(ctx.writer, den, base);
}

fn printCons(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    if (ctx.seen.contains(v.toConsAddr())) {
        try ctx.writer.writeAll("#<cycle>");
        return;
    }

    try ctx.writer.writeByte('(');
    var cur = v;
    var first = true;
    while (cur.isCons()) {
        const cur_addr = cur.toConsAddr();
        if (!first and ctx.seen.contains(cur_addr)) {
            try ctx.writer.writeAll(" . #<cycle>");
            break;
        }
        try ctx.seen.put(ctx.allocator, cur_addr, {});

        if (!first) try ctx.writer.writeByte(' ');
        try printValue(ctx, heap.car(cur), depth + 1);
        first = false;

        const tail = heap.cdr(cur);
        if (tail.equalsRaw(value.NIL)) break;
        if (!tail.isCons()) {
            try ctx.writer.writeAll(" . ");
            try printValue(ctx, tail, depth + 1);
            break;
        }
        cur = tail;
    }
    try ctx.writer.writeByte(')');
}

fn printChar(ctx: *PrintCtx, c: u21) PrintError!void {
    if (!ctx.effectiveEscape()) {
        try writeRawChar(ctx.writer, c);
        return;
    }
    try ctx.writer.writeAll("#\\");
    switch (c) {
        ' ' => try ctx.writer.writeAll("Space"),
        '\n' => try ctx.writer.writeAll("Newline"),
        '\t' => try ctx.writer.writeAll("Tab"),
        '\r' => try ctx.writer.writeAll("Return"),
        0 => try ctx.writer.writeAll("Null"),
        else => try writeRawChar(ctx.writer, c),
    }
}

fn writeRawChar(writer: *std.Io.Writer, c: u21) PrintError!void {
    if (c < 0x80) {
        try writer.writeByte(@intCast(c));
        return;
    }
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch {
        try writer.print("U+{X}", .{c});
        return;
    };
    try writer.writeAll(buf[0..n]);
}

fn printSpecial(ctx: *PrintCtx, v: Value) PrintError!void {
    switch (v.toSpecialIndex()) {
        0 => try ctx.writer.writeAll("#<unbound>"),
        1 => try ctx.writer.writeAll("#<eof>"),
        else => |idx| try ctx.writer.print("#<special:{d}>", .{idx}),
    }
}

/// Convenience: prints to a buffer using prin1 settings (Phase-0 default).
pub fn printToOwnedSlice(allocator: std.mem.Allocator, v: Value) ![]u8 {
    return writeToOwnedSlice(allocator, v, PRIN1);
}

/// Convenience: prints to a buffer using princ settings (no escapes).
pub fn princToOwnedSlice(allocator: std.mem.Allocator, v: Value) ![]u8 {
    return writeToOwnedSlice(allocator, v, PRINC);
}

/// Convenience: prints to a buffer using arbitrary settings.
pub fn writeToOwnedSlice(allocator: std.mem.Allocator, v: Value, settings: Settings) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try write(allocator, &aw.writer, v, settings);
    return aw.toOwnedSlice();
}
