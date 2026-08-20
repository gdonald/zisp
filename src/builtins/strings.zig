//! String builtins. A string element is a character stored in one byte, so
//! indexing and in-place update are constant time. Characters past code 255
//! are rejected by the reader and by `(setf char)`; wider strings arrive
//! with specialized array element types.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const character = @import("../runtime/character.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerStrings(ev: *Evaluator) !void {
    _ = try ev.defineNative("STRING", &stringFn);
    _ = try ev.defineNative("SIMPLE-STRING-P", &simpleStringPFn);
    _ = try ev.defineNative("MAKE-STRING", &makeStringFn);
    _ = try ev.defineNative("CHAR", &charFn);
    _ = try ev.defineNative("SCHAR", &charFn);
    _ = try ev.defineNative("%SET-CHAR", &setCharFn);
    _ = try ev.defineNative("STRING=", &stringEqFn);
    _ = try ev.defineNative("STRING-EQUAL", &stringEqualFn);
    _ = try ev.defineNative("STRING<", &stringLessFn);
    _ = try ev.defineNative("STRING-UPCASE", &stringUpcaseFn);
    _ = try ev.defineNative("STRING-DOWNCASE", &stringDowncaseFn);
    _ = try ev.defineNative("STRING-CAPITALIZE", &stringCapitalizeFn);
    _ = try ev.defineNative("NSTRING-UPCASE", &nstringUpcaseFn);
    _ = try ev.defineNative("NSTRING-DOWNCASE", &nstringDowncaseFn);
    _ = try ev.defineNative("NSTRING-CAPITALIZE", &nstringCapitalizeFn);
    _ = try ev.defineNative("STRING-TRIM", &stringTrimFn);
    _ = try ev.defineNative("STRING-LEFT-TRIM", &stringLeftTrimFn);
    _ = try ev.defineNative("STRING-RIGHT-TRIM", &stringRightTrimFn);
    _ = try ev.defineNative("UNICODE-UPCASE", fullCaseFn(.upcase));
    _ = try ev.defineNative("UNICODE-DOWNCASE", fullCaseFn(.downcase));
    _ = try ev.defineNative("UNICODE-CAPITALIZE", fullCaseFn(.capitalize));
}

/// The characters of a string.
pub fn charsOf(v: Value) Error![]u32 {
    if (!heap.isString(v)) return Error.TypeError;
    return heap.asString(v).slice();
}

/// A string designator as a string: a string is itself, a symbol becomes
/// its name, and a character becomes a one-character string.
fn designatorString(ev: *Evaluator, v: Value) Error!Value {
    if (heap.isString(v)) return v;
    if (v.isSymbol()) return ev.heap.allocString(symbol_mod.symbol(v).name);
    if (v.tag() == .char) return ev.heap.allocStringFromChars(&.{v.toChar()});
    return Error.TypeError;
}

fn designatorText(ev: *Evaluator, v: Value) Error![]const u32 {
    return heap.asString(try designatorString(ev, v)).constSlice();
}

fn stringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return designatorString(ev, args[0]);
}

fn simpleStringPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return if (heap.isString(args[0])) value.T else value.NIL;
}

fn charCode(v: Value) Error!u32 {
    if (v.tag() != .char) return Error.TypeError;
    return v.toChar();
}

fn makeStringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0 or (args.len - 1) % 2 != 0) return Error.WrongArgCount;
    if (!args[0].isFixnum() or args[0].toFixnum() < 0) return Error.TypeError;
    const size: usize = @intCast(args[0].toFixnum());

    var fill: u32 = ' ';
    const initial_kw = try ev.interner.internKeyword("INITIAL-ELEMENT");
    const element_type_kw = try ev.interner.internKeyword("ELEMENT-TYPE");
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (args[i].equalsRaw(initial_kw)) {
            fill = try charCode(args[i + 1]);
        } else if (args[i].equalsRaw(element_type_kw)) {
            if (!isCharacterType(args[i + 1])) return Error.TypeError;
        } else return Error.ProgramError;
    }

    const result = try ev.heap.allocStringUninitialized(size);
    @memset(heap.asString(result).slice(), fill);
    return result;
}

fn isCharacterType(spec: Value) bool {
    if (!spec.isSymbol()) return false;
    const n = symbol_mod.symbol(spec).name;
    return std.mem.eql(u8, n, "CHARACTER") or std.mem.eql(u8, n, "BASE-CHAR") or
        std.mem.eql(u8, n, "STANDARD-CHAR");
}

/// The element at `index_v`, bounds-checked against `chars`.
fn indexInto(chars: []const u32, index_v: Value) Error!usize {
    if (!index_v.isFixnum() or index_v.toFixnum() < 0) return Error.TypeError;
    const i: usize = @intCast(index_v.toFixnum());
    if (i >= chars.len) return Error.TypeError;
    return i;
}

fn charFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const chars = try charsOf(args[0]);
    return Value.fromChar(@intCast(chars[try indexInto(chars, args[1])]));
}

fn setCharFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 3) return Error.WrongArgCount;
    const chars = try charsOf(args[0]);
    chars[try indexInto(chars, args[1])] = try charCode(args[2]);
    return args[2];
}

/// The `:start1 :end1 :start2 :end2` bounding indices the string comparisons
/// accept, resolved against the two strings they delimit.
const Bounds = struct {
    a: []const u32,
    b: []const u32,
    /// Where `a` starts inside its whole string, so a mismatch can be
    /// reported as an index into that string rather than into the slice.
    a_offset: usize,

    fn parse(ev: *Evaluator, a_all: []const u32, b_all: []const u32, opts: []const Value) Error!Bounds {
        if (opts.len % 2 != 0) return Error.WrongArgCount;
        var start1: usize = 0;
        var end1: usize = a_all.len;
        var start2: usize = 0;
        var end2: usize = b_all.len;
        var i: usize = 0;
        while (i < opts.len) : (i += 2) {
            const target = try boundKeyword(ev, opts[i]);
            const bound = try boundValue(opts[i + 1], switch (target) {
                .start1, .end1 => a_all.len,
                .start2, .end2 => b_all.len,
            });
            switch (target) {
                .start1 => start1 = bound orelse 0,
                .end1 => end1 = bound orelse a_all.len,
                .start2 => start2 = bound orelse 0,
                .end2 => end2 = bound orelse b_all.len,
            }
        }
        if (start1 > end1 or start2 > end2) return Error.TypeError;
        return .{ .a = a_all[start1..end1], .b = b_all[start2..end2], .a_offset = start1 };
    }
};

const BoundKeyword = enum { start1, end1, start2, end2 };

fn boundKeyword(ev: *Evaluator, key: Value) Error!BoundKeyword {
    const names = [_]struct { name: []const u8, target: BoundKeyword }{
        .{ .name = "START1", .target = .start1 },
        .{ .name = "END1", .target = .end1 },
        .{ .name = "START2", .target = .start2 },
        .{ .name = "END2", .target = .end2 },
    };
    for (names) |entry| {
        if (key.equalsRaw(try ev.interner.internKeyword(entry.name))) return entry.target;
    }
    return Error.ProgramError;
}

/// NIL means "leave the default"; anything else must be an index in range.
fn boundValue(v: Value, limit: usize) Error!?usize {
    if (v.equalsRaw(value.NIL)) return null;
    if (!v.isFixnum() or v.toFixnum() < 0) return Error.TypeError;
    const n: usize = @intCast(v.toFixnum());
    if (n > limit) return Error.TypeError;
    return n;
}

/// Both operands of a string comparison, resolved through their
/// designators and clipped to the bounding indices.
const Operands = struct {
    bounds: Bounds = undefined,

    fn resolve(self: *Operands, ev: *Evaluator, args: []const Value) Error!void {
        if (args.len < 2) return Error.WrongArgCount;
        const a = try designatorText(ev, args[0]);
        const b = try designatorText(ev, args[1]);
        self.bounds = try Bounds.parse(ev, a, b, args[2..]);
    }
};

fn stringEqFn(p: *anyopaque, args: []const Value) Error!Value {
    var ops = Operands{};
    try ops.resolve(evaluator(p), args);
    return if (std.mem.eql(u32, ops.bounds.a, ops.bounds.b)) value.T else value.NIL;
}

fn stringEqualFn(p: *anyopaque, args: []const Value) Error!Value {
    var ops = Operands{};
    try ops.resolve(evaluator(p), args);
    const a = ops.bounds.a;
    const b = ops.bounds.b;
    if (a.len != b.len) return value.NIL;
    for (a, b) |ca, cb| {
        if (character.upcase(@intCast(ca)) != character.upcase(@intCast(cb))) return value.NIL;
    }
    return value.T;
}

/// `string<` returns the index of the first mismatch rather than T, so a
/// caller can see where the two diverged.
fn stringLessFn(p: *anyopaque, args: []const Value) Error!Value {
    var ops = Operands{};
    try ops.resolve(evaluator(p), args);
    const a = ops.bounds.a;
    const b = ops.bounds.b;
    const offset = ops.bounds.a_offset;
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        if (a[i] != b[i]) {
            return if (a[i] < b[i]) Value.fromFixnum(@intCast(offset + i)) else value.NIL;
        }
    }
    if (a.len < b.len) return Value.fromFixnum(@intCast(offset + i));
    return value.NIL;
}

// --- case conversion ---

/// The `:start` / `:end` region of one string, as an index pair into it.
const Region = struct {
    start: usize,
    end: usize,

    fn parse(ev: *Evaluator, len: usize, opts: []const Value) Error!Region {
        if (opts.len % 2 != 0) return Error.WrongArgCount;
        var region = Region{ .start = 0, .end = len };
        const start_kw = try ev.interner.internKeyword("START");
        const end_kw = try ev.interner.internKeyword("END");
        var i: usize = 0;
        while (i < opts.len) : (i += 2) {
            if (opts[i].equalsRaw(start_kw)) {
                region.start = (try boundValue(opts[i + 1], len)) orelse 0;
            } else if (opts[i].equalsRaw(end_kw)) {
                region.end = (try boundValue(opts[i + 1], len)) orelse len;
            } else return Error.ProgramError;
        }
        if (region.start > region.end) return Error.TypeError;
        return region;
    }
};

const CaseKind = enum { upcase, downcase, capitalize };

fn recased(c: u32, upward: bool) u32 {
    return if (upward) character.upcase(@intCast(c)) else character.downcase(@intCast(c));
}

/// Rewrite `chars[region]` in place. Capitalization uppercases the first
/// character of each alphanumeric run and lowercases the rest.
fn recase(chars: []u32, region: Region, kind: CaseKind) void {
    var in_word = false;
    for (chars[region.start..region.end]) |*c| {
        switch (kind) {
            .upcase => c.* = recased(c.*, true),
            .downcase => c.* = recased(c.*, false),
            .capitalize => {
                const alphanumeric = character.isAlphanumeric(@intCast(c.*));
                c.* = recased(c.*, alphanumeric and !in_word);
                in_word = alphanumeric;
            },
        }
    }
}

/// The non-destructive case functions take a string designator and return a
/// fresh string; the `n` variants take a string and rewrite it in place.
fn recasedString(ev: *Evaluator, args: []const Value, kind: CaseKind, in_place: bool) Error!Value {
    if (args.len < 1) return Error.WrongArgCount;
    var target = args[0];
    if (!in_place) {
        target = try ev.heap.allocStringFromChars(try designatorText(ev, args[0]));
    }
    const chars = try charsOf(target);
    recase(chars, try Region.parse(ev, chars.len, args[1..]), kind);
    return target;
}

fn stringUpcaseFn(p: *anyopaque, args: []const Value) Error!Value {
    return recasedString(evaluator(p), args, .upcase, false);
}

fn stringDowncaseFn(p: *anyopaque, args: []const Value) Error!Value {
    return recasedString(evaluator(p), args, .downcase, false);
}

fn stringCapitalizeFn(p: *anyopaque, args: []const Value) Error!Value {
    return recasedString(evaluator(p), args, .capitalize, false);
}

fn nstringUpcaseFn(p: *anyopaque, args: []const Value) Error!Value {
    return recasedString(evaluator(p), args, .upcase, true);
}

fn nstringDowncaseFn(p: *anyopaque, args: []const Value) Error!Value {
    return recasedString(evaluator(p), args, .downcase, true);
}

fn nstringCapitalizeFn(p: *anyopaque, args: []const Value) Error!Value {
    return recasedString(evaluator(p), args, .capitalize, true);
}

// --- trimming ---

const TrimSides = struct { left: bool, right: bool };

/// True when `c` is one of the characters in the bag, a sequence of
/// character designators given as a list or a string.
fn inBag(ev: *Evaluator, bag: Value, c: u32) Error!bool {
    if (heap.isString(bag)) {
        return std.mem.indexOfScalar(u32, heap.asString(bag).constSlice(), c) != null;
    }
    var rest = bag;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const text = try designatorText(ev, heap.car(rest));
        if (text.len == 1 and text[0] == c) return true;
    }
    if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
    return false;
}

fn trimmed(ev: *Evaluator, args: []const Value, sides: TrimSides) Error!Value {
    if (args.len != 2) return Error.WrongArgCount;
    const text = try designatorText(ev, args[1]);
    var start: usize = 0;
    var end: usize = text.len;
    if (sides.left) {
        while (start < end and try inBag(ev, args[0], text[start])) start += 1;
    }
    if (sides.right) {
        while (end > start and try inBag(ev, args[0], text[end - 1])) end -= 1;
    }
    return ev.heap.allocStringFromChars(text[start..end]);
}

fn stringTrimFn(p: *anyopaque, args: []const Value) Error!Value {
    return trimmed(evaluator(p), args, .{ .left = true, .right = true });
}

fn stringLeftTrimFn(p: *anyopaque, args: []const Value) Error!Value {
    return trimmed(evaluator(p), args, .{ .left = true, .right = false });
}

fn stringRightTrimFn(p: *anyopaque, args: []const Value) Error!Value {
    return trimmed(evaluator(p), args, .{ .left = false, .right = true });
}

// --- full Unicode case mapping ---

/// Where the standard's own case functions map one character to one,
/// these apply the full mappings, so a ligature or a sharp s expands and
/// a capital sigma picks its final form from context.
///
/// CLHS defines `string-upcase` in terms of `char-upcase`, which is a
/// one-to-one mapping, so these cannot replace it and are separate.
fn fullCaseFn(comptime kind: CaseKind) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len != 1) return Error.WrongArgCount;
            const text = try designatorText(ev, args[0]);

            var out: std.ArrayList(u32) = .empty;
            defer out.deinit(ev.allocator);
            var in_word = false;
            for (text, 0..) |code, i| {
                const c: u21 = @intCast(code);
                const upward = switch (kind) {
                    .upcase => true,
                    .downcase => false,
                    .capitalize => !in_word and character.isCased(c),
                };
                const expansion = if (upward)
                    character.fullUpcase(c)
                else
                    character.fullDowncase(c, isFinalPosition(text, i));
                for (expansion.slice()) |mapped| try out.append(ev.allocator, mapped);
                if (kind == .capitalize) in_word = character.isCased(c);
            }
            return ev.heap.allocStringFromChars(out.items);
        }
    }.f;
}

/// Unicode's Final_Sigma condition: the character is preceded by a cased
/// character and not followed by one.
fn isFinalPosition(text: []const u32, i: usize) bool {
    if (i == 0) return false;
    if (!character.isCased(@intCast(text[i - 1]))) return false;
    if (i + 1 >= text.len) return true;
    return !character.isCased(@intCast(text[i + 1]));
}
