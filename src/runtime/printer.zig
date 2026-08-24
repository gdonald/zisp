//! Common Lisp printer.
//!
//! Three CL-named entry points share one core driver `write`:
//!
//!   * `prin1`  — readable, with escapes (`*print-escape*` T)
//!   * `princ`  — human, no escapes (`*print-escape*` NIL, `*print-readably*` NIL)
//!   * `print`  — newline + prin1 + space (CL's "fresh-line + readable + space")
//!
//! Settings track `*print-readably*` / `*print-escape*` / `*print-base*` /
//! `*print-radix*`. `*print-circle*` only requires the safe-from-
//! infinite-loop minimum here — cycles print as `#<cycle>` placeholders
//! rather than the full `#1=` / `#1#` markers, which wait for the pretty
//! printer.
//!
//! The bare `print` / `printToOwnedSlice` driver functions keep prin1-style
//! defaults and live alongside the CL-named variants.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const character = @import("character.zig");
const circle_mod = @import("circle.zig");
const pathname = @import("pathname.zig");
const symbol = @import("symbol.zig");
const package = @import("package.zig");
const Value = value.Value;

const MAX_DEPTH: u32 = 1024;

/// Mirrors the CL `*print-...*` variables. The eventual special-variable
/// plumbing will read these out of the dynamic environment; for now they
/// are passed per call.
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
    /// Labels for `*print-circle*`. When set, an object that appears
    /// more than once prints as `#n=` the first time and `#n#` after.
    circle: ?*circle_mod.State = null,
    /// Value of `*package*`. Symbols accessible in it print unqualified;
    /// everything else gets a `pkg:` or `pkg::` prefix. When null there is
    /// no package context and no symbol is qualified.
    current_package: ?*package.Package = null,
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

/// Readable output: strings quoted, symbols pipe-escaped when
/// they couldn't round-trip otherwise, characters as `#\X`/`#\Name`.
pub fn prin1(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    return write(allocator, writer, v, PRIN1);
}

/// Human output: strings unquoted, symbols as bare names,
/// characters written as the character itself.
pub fn princ(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    return write(allocator, writer, v, PRINC);
}

/// CL `print`: leading newline, then prin1, then trailing space.
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
    // A shared object announces its label the first time and refers back
    // to it after, which is what lets a cycle terminate on paper.
    if (ctx.settings.circle) |state| {
        if (state.get(v)) |label| {
            const id = state.assign(label);
            if (label.printed) return ctx.writer.print("#{d}#", .{id});
            label.printed = true;
            try ctx.writer.print("#{d}=", .{id});
        }
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
    if (!ctx.effectiveEscape()) {
        try ctx.writer.writeAll(name);
        return;
    }
    try printSymbolPrefix(ctx, v, name);
    try printNamePart(ctx, name);
}

/// Emit whatever package qualification `v` needs to read back as itself
/// from `ctx.settings.current_package`.
fn printSymbolPrefix(ctx: *PrintCtx, v: Value, name: []const u8) PrintError!void {
    const home = symbol.homePackage(v) orelse {
        try ctx.writer.writeAll("#:");
        return;
    };
    if (std.mem.eql(u8, home.name, symbol.KEYWORD_PACKAGE_NAME)) {
        try ctx.writer.writeByte(':');
        return;
    }
    const current = ctx.settings.current_package orelse return;
    if (current == home) return;
    if (current.findSymbol(name)) |found| {
        if (found.sym.equalsRaw(v)) return;
    }
    try printNamePart(ctx, home.name);
    try ctx.writer.writeAll(if (home.external.contains(name)) ":" else "::");
}

fn printNamePart(ctx: *PrintCtx, part: []const u8) PrintError!void {
    if (!needsSymbolEscape(part)) {
        try ctx.writer.writeAll(part);
        return;
    }
    try ctx.writer.writeByte('|');
    for (part) |c| {
        if (c == '|' or c == '\\') try ctx.writer.writeByte('\\');
        try ctx.writer.writeByte(c);
    }
    try ctx.writer.writeByte('|');
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
    // A potential number never ends in a sign (CLHS 2.3.1.1), which is what
    // keeps `1+` and `1-` printing without escapes.
    if (name.len != 0 and (name[name.len - 1] == '+' or name[name.len - 1] == '-')) return false;
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
        '!', '$', '%', '&', '*', '+', '-', '.', '/', '<', '=', '>', '?', '@', '^', '_', '~' => true,
        else => false,
    };
}

fn printHeap(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    switch (heap.heapType(v)) {
        .string => try printString(ctx, heap.asString(v).constSlice()),
        .single_float => try printFloat(ctx, f32, heap.asSingleFloat(v).value, 'f'),
        .double_float => try printFloat(ctx, f64, heap.asDoubleFloat(v).value, 'd'),
        .ratio => try printRatio(ctx, v),
        .vector => try printArray(ctx, v, depth),
        .bignum => try printBignum(ctx, v),
        .complex => {
            const z = heap.asComplex(v);
            try ctx.writer.writeAll("#C(");
            try printValue(ctx, z.realpart, depth + 1);
            try ctx.writer.writeByte(' ');
            try printValue(ctx, z.imagpart, depth + 1);
            try ctx.writer.writeByte(')');
        },
        .random_state => try ctx.writer.writeAll("#<random-state>"),
        .readtable => try ctx.writer.writeAll("#<readtable>"),
        .stream => try ctx.writer.writeAll("#<stream>"),
        .structure => try printStructure(ctx, v, depth),
        .pathname => {
            if (ctx.effectiveEscape()) try ctx.writer.writeAll("#P");
            const text = pathname.namestringOf(ctx.allocator, v) catch return error.WriteFailed;
            defer ctx.allocator.free(text);
            try printQuotedUtf8(ctx, text);
        },
        .package => try ctx.writer.print("#<PACKAGE \"{s}\">", .{package.asPackage(v).name}),
        else => try ctx.writer.print("#<heap-object {x}>", .{v.toHeapAddr()}),
    }
}

/// Slot names live on the structure name's plist under `%STRUCTURE-SLOTS`,
/// written there by `defstruct`. Matching the indicator by name keeps the
/// printer free of an interner reference.
const STRUCTURE_SLOTS = "%STRUCTURE-SLOTS";

fn structureSlotNames(name: Value) Value {
    var plist = symbol.symbol(name).plist;
    while (plist.isCons()) {
        const rest = heap.cdr(plist);
        if (!rest.isCons()) return value.NIL;
        const key = heap.car(plist);
        if (key.isSymbol() and std.mem.eql(u8, symbol.name(key), STRUCTURE_SLOTS)) {
            return heap.car(rest);
        }
        plist = heap.cdr(rest);
    }
    return value.NIL;
}

fn printStructure(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    const obj = heap.asStructure(v);
    try ctx.writer.writeAll("#S(");
    try printValue(ctx, obj.name, depth + 1);
    var names = structureSlotNames(obj.name);
    for (obj.constSlice()) |slot| {
        try ctx.writer.writeByte(' ');
        if (names.isCons()) {
            const slot_name = heap.car(names);
            names = heap.cdr(names);
            if (slot_name.isSymbol()) {
                try ctx.writer.writeByte(':');
                try ctx.writer.writeAll(symbol.name(slot_name));
                try ctx.writer.writeByte(' ');
            }
        }
        try printValue(ctx, slot, depth + 1);
    }
    try ctx.writer.writeByte(')');
}

/// String elements are characters, one per byte, so each is encoded back to
/// UTF-8 on the way out.
/// Text that is already UTF-8, printed with the quoting a string gets.
fn printQuotedUtf8(ctx: *PrintCtx, text: []const u8) PrintError!void {
    const escape = ctx.effectiveEscape();
    if (escape) try ctx.writer.writeByte('"');
    for (text) |b| {
        if (escape and (b == '"' or b == '\\')) try ctx.writer.writeByte('\\');
        try ctx.writer.writeByte(b);
    }
    if (escape) try ctx.writer.writeByte('"');
}

fn printString(ctx: *PrintCtx, s: []const u32) PrintError!void {
    const escape = ctx.effectiveEscape();
    if (escape) try ctx.writer.writeByte('"');
    for (s) |c| {
        if (escape and (c == '"' or c == '\\')) try ctx.writer.writeByte('\\');
        try writeRawChar(ctx.writer, @intCast(c));
    }
    if (escape) try ctx.writer.writeByte('"');
}

fn printBignum(ctx: *PrintCtx, v: Value) PrintError!void {
    const base = clampBase(ctx.settings.base);
    if (ctx.settings.radix) try writeRadixPrefix(ctx, base);
    try writeIntegerValue(ctx, v, base);
}

fn printRatio(ctx: *PrintCtx, v: Value) PrintError!void {
    const base = clampBase(ctx.settings.base);
    if (ctx.settings.radix) try writeRadixPrefix(ctx, base);
    const r = heap.asRatio(v);
    try writeIntegerValue(ctx, r.numerator, base);
    try ctx.writer.writeByte('/');
    try writeIntegerValue(ctx, r.denominator, base);
}

/// An integer component of a larger form, whichever representation it has.
fn writeIntegerValue(ctx: *PrintCtx, v: Value, base: u8) PrintError!void {
    if (v.isFixnum()) return writeIntegerInBase(ctx.writer, v.toFixnum(), base);
    const text = heap.asBignum(v).toConst().toStringAlloc(ctx.allocator, base, .lower) catch
        return error.OutOfMemory;
    defer ctx.allocator.free(text);
    try ctx.writer.writeAll(text);
}

fn printCons(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    // With labels in play the cycle guard is unnecessary, and it would
    // stop the tail of a circular list from printing as a back-reference.
    if (ctx.settings.circle != null) return printConsLabelled(ctx, v, depth);
    if (ctx.seen.contains(v.toConsAddr())) {
        try ctx.writer.writeAll("#<cycle>");
        return;
    }

    // `seen` holds the conses enclosing the one being printed, so a revisit
    // means a cycle. Structure merely shared between branches is not one, so
    // this spine leaves `seen` as it found it.
    var spine: std.ArrayList(u64) = .empty;
    defer {
        for (spine.items) |addr| _ = ctx.seen.remove(addr);
        spine.deinit(ctx.allocator);
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
        try spine.append(ctx.allocator, cur_addr);

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

/// A vector prints as `#(...)`; a higher-rank array as `#nA` followed by
/// its elements nested one list per dimension.
fn printArray(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    const a = heap.asArray(v);
    const elements = heap.arrayActive(v);
    if (a.rank == 1 and a.element_type == .bit) {
        try ctx.writer.writeAll("#*");
        for (elements) |elem| {
            try ctx.writer.writeByte(if (elem.isFixnum() and elem.toFixnum() == 1) '1' else '0');
        }
        return;
    }
    if (a.rank == 1) {
        try ctx.writer.writeAll("#(");
        for (elements, 0..) |elem, i| {
            if (i != 0) try ctx.writer.writeByte(' ');
            try printValue(ctx, elem, depth + 1);
        }
        try ctx.writer.writeByte(')');
        return;
    }
    try ctx.writer.print("#{d}A", .{a.rank});
    var consumed: usize = 0;
    try printArrayAxis(ctx, a.dimensions(), heap.arrayElements(v), &consumed, depth);
}

/// One axis of a higher-rank array: a list of the slices below it, or the
/// elements themselves at the innermost axis.
fn printArrayAxis(
    ctx: *PrintCtx,
    dims: []const u64,
    elements: []const Value,
    consumed: *usize,
    depth: u32,
) PrintError!void {
    try ctx.writer.writeByte('(');
    var i: usize = 0;
    while (i < dims[0]) : (i += 1) {
        if (i != 0) try ctx.writer.writeByte(' ');
        if (dims.len == 1) {
            try printValue(ctx, elements[consumed.*], depth + 1);
            consumed.* += 1;
        } else {
            try printArrayAxis(ctx, dims[1..], elements, consumed, depth + 1);
        }
    }
    try ctx.writer.writeByte(')');
}

/// The float type `e` stands for, which is what CLHS calls
/// `*read-default-float-format*`. A float of this type prints with no
/// exponent marker in fixed form; any other type carries its own.
const DEFAULT_FLOAT_MARKER: u8 = 'f';

/// Fixed-point form covers the magnitudes CLHS 22.1.3.1.3 names, and
/// exponential form covers the rest.
fn usesFixedForm(magnitude: f64) bool {
    return magnitude == 0 or (magnitude >= 1e-3 and magnitude < 1e7);
}

/// Print a float so it reads back as the same bits: shortest digits from
/// the Ryu renderer, always a decimal point, and the exponent marker the
/// type calls for.
fn printFloat(ctx: *PrintCtx, comptime T: type, x: T, marker: u8) PrintError!void {
    if (std.math.isNan(x)) return ctx.writer.writeAll("#<not-a-number>");
    if (std.math.isInf(x)) {
        return ctx.writer.writeAll(if (x < 0) "#<negative-infinity>" else "#<infinity>");
    }

    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const magnitude = @abs(@as(f64, x));
    if (usesFixedForm(magnitude)) {
        const digits = std.fmt.float.render(&buf, x, .{ .mode = .decimal }) catch
            return error.WriteFailed;
        try ctx.writer.writeAll(digits);
        if (std.mem.indexOfScalar(u8, digits, '.') == null) try ctx.writer.writeAll(".0");
        // A fixed-form float of a non-default type still needs its marker.
        if (marker != DEFAULT_FLOAT_MARKER) try ctx.writer.print("{c}0", .{marker});
        return;
    }

    const digits = std.fmt.float.render(&buf, x, .{ .mode = .scientific }) catch
        return error.WriteFailed;
    const split = std.mem.indexOfScalar(u8, digits, 'e') orelse digits.len;
    const mantissa = digits[0..split];
    try ctx.writer.writeAll(mantissa);
    if (std.mem.indexOfScalar(u8, mantissa, '.') == null) try ctx.writer.writeAll(".0");
    // A float of the default type spells its exponent with `e`.
    try ctx.writer.writeByte(if (marker == DEFAULT_FLOAT_MARKER) 'e' else marker);
    try ctx.writer.writeAll(if (split < digits.len) digits[split + 1 ..] else "0");
}

/// The list form, where every tail is a candidate for a back-reference,
/// so a labelled tail becomes a dotted `. #n#`.
fn printConsLabelled(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    try ctx.writer.writeByte('(');
    try printValue(ctx, heap.car(v), depth + 1);
    var tail = heap.cdr(v);
    while (true) {
        if (tail.equalsRaw(value.NIL)) break;
        const labelled = if (ctx.settings.circle) |state| state.get(tail) != null else false;
        if (!tail.isCons() or labelled) {
            try ctx.writer.writeAll(" . ");
            try printValue(ctx, tail, depth + 1);
            break;
        }
        try ctx.writer.writeByte(' ');
        try printValue(ctx, heap.car(tail), depth + 1);
        tail = heap.cdr(tail);
    }
    try ctx.writer.writeByte(')');
}

fn printChar(ctx: *PrintCtx, c: u21) PrintError!void {
    if (!ctx.effectiveEscape()) {
        try writeRawChar(ctx.writer, c);
        return;
    }
    try ctx.writer.writeAll("#\\");
    if (character.nameForCode(c)) |name| return ctx.writer.writeAll(name);
    try writeRawChar(ctx.writer, c);
}

/// Encode one character to UTF-8. Used for string elements and for the
/// literal text of a format control string, both of which hold characters.
pub fn writeRawChar(writer: *std.Io.Writer, c: u21) PrintError!void {
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
