//! Character builtins: codes and names, the two comparison families, case
//! conversion, and the classification predicates.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const character = @import("../runtime/character.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerCharacters(ev: *Evaluator) !void {
    _ = try ev.defineNative("CHARACTERP", &characterpFn);
    _ = try ev.defineNative("CHAR-CODE", &charCodeFn);
    _ = try ev.defineNative("CHAR-INT", &charCodeFn);
    _ = try ev.defineNative("CODE-CHAR", &codeCharFn);
    _ = try ev.defineNative("CHAR-NAME", &charNameFn);
    _ = try ev.defineNative("NAME-CHAR", &nameCharFn);
    _ = try ev.defineNative("CHAR-UPCASE", caseFn(.up));
    _ = try ev.defineNative("CHAR-DOWNCASE", caseFn(.down));
    _ = try ev.defineNative("DIGIT-CHAR", &digitCharFn);
    _ = try ev.defineNative("DIGIT-CHAR-P", &digitCharPFn);

    _ = try ev.defineNative("CHAR=", compareFn(.eq, .exact));
    _ = try ev.defineNative("CHAR/=", compareFn(.ne, .exact));
    _ = try ev.defineNative("CHAR<", compareFn(.lt, .exact));
    _ = try ev.defineNative("CHAR>", compareFn(.gt, .exact));
    _ = try ev.defineNative("CHAR<=", compareFn(.le, .exact));
    _ = try ev.defineNative("CHAR>=", compareFn(.ge, .exact));
    _ = try ev.defineNative("CHAR-EQUAL", compareFn(.eq, .folded));
    _ = try ev.defineNative("CHAR-NOT-EQUAL", compareFn(.ne, .folded));
    _ = try ev.defineNative("CHAR-LESSP", compareFn(.lt, .folded));
    _ = try ev.defineNative("CHAR-GREATERP", compareFn(.gt, .folded));
    _ = try ev.defineNative("CHAR-NOT-GREATERP", compareFn(.le, .folded));
    _ = try ev.defineNative("CHAR-NOT-LESSP", compareFn(.ge, .folded));

    _ = try ev.defineNative("ALPHA-CHAR-P", classifyFn(.alpha));
    _ = try ev.defineNative("ALPHANUMERICP", classifyFn(.alphanumeric));
    _ = try ev.defineNative("UPPER-CASE-P", classifyFn(.upper));
    _ = try ev.defineNative("LOWER-CASE-P", classifyFn(.lower));
    _ = try ev.defineNative("BOTH-CASE-P", classifyFn(.both_case));
    _ = try ev.defineNative("GRAPHIC-CHAR-P", classifyFn(.graphic));
    _ = try ev.defineNative("STANDARD-CHAR-P", classifyFn(.standard));

    const limit = try ev.interner.intern("CHAR-CODE-LIMIT");
    symbol_mod.symbol(limit).value_cell = Value.fromFixnum(character.CODE_LIMIT);
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

fn expectChar(v: Value) Error!u21 {
    if (v.tag() != .char) return Error.TypeError;
    return v.toChar();
}

fn oneChar(args: []const Value) Error!u21 {
    if (args.len != 1) return Error.WrongArgCount;
    return expectChar(args[0]);
}

fn characterpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].tag() == .char);
}

// --- codes and names ---

fn charCodeFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    return Value.fromFixnum(@intCast(try oneChar(args)));
}

fn codeCharFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isFixnum() or args[0].toFixnum() < 0) return Error.TypeError;
    const code = args[0].toFixnum();
    if (code >= character.CODE_LIMIT) return value.NIL;
    // The surrogate range holds no characters of its own.
    if (code >= 0xD800 and code <= 0xDFFF) return value.NIL;
    return Value.fromChar(@intCast(code));
}

fn charNameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    const c = try oneChar(args);
    const name = character.nameForCode(c) orelse return value.NIL;
    return ev.heap.allocString(name);
}

fn nameCharFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!heap.isString(args[0])) return Error.TypeError;
    const text = try heap.stringUtf8Alloc(ev.allocator, args[0]);
    defer ev.allocator.free(text);
    const code = character.codeForName(text) orelse return value.NIL;
    return Value.fromChar(code);
}

// --- case ---

const CaseKind = enum { up, down };

fn caseFn(comptime kind: CaseKind) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            const c = try oneChar(args);
            return Value.fromChar(switch (kind) {
                .up => character.upcase(c),
                .down => character.downcase(c),
            });
        }
    }.f;
}

// --- comparison ---

const CompareOp = enum { eq, ne, lt, gt, le, ge };
const CompareCase = enum { exact, folded };

/// The two families differ only in whether case is folded away first.
fn keyOf(kind: CompareCase, c: u21) u21 {
    return switch (kind) {
        .exact => c,
        .folded => character.upcase(c),
    };
}

fn compareFn(comptime op: CompareOp, comptime kind: CompareCase) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len == 0) return Error.WrongArgCount;
            for (args) |a| _ = try expectChar(a);
            if (op == .ne) {
                // `char/=` holds only when every pair differs, so it is not
                // a chain of neighbours like the others.
                for (args, 0..) |a, i| {
                    for (args[i + 1 ..]) |b| {
                        if (keyOf(kind, a.toChar()) == keyOf(kind, b.toChar())) return value.NIL;
                    }
                }
                return value.T;
            }
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const x = keyOf(kind, args[i - 1].toChar());
                const y = keyOf(kind, args[i].toChar());
                const ok = switch (op) {
                    .eq => x == y,
                    .lt => x < y,
                    .gt => x > y,
                    .le => x <= y,
                    .ge => x >= y,
                    .ne => unreachable,
                };
                if (!ok) return value.NIL;
            }
            return value.T;
        }
    }.f;
}

// --- classification ---

const Classification = enum { alpha, alphanumeric, upper, lower, both_case, graphic, standard };

fn classifyFn(comptime kind: Classification) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            const c = try oneChar(args);
            return boolv(switch (kind) {
                .alpha => character.isAlpha(c),
                .alphanumeric => character.isAlphanumeric(c),
                .upper => character.isUpper(c),
                .lower => character.isLower(c),
                .both_case => character.isBothCase(c),
                .graphic => character.isGraphic(c),
                .standard => character.isStandard(c),
            });
        }
    }.f;
}

/// The radix argument shared by `digit-char` and `digit-char-p`.
fn radixOf(args: []const Value, index: usize) Error!u8 {
    if (args.len <= index) return 10;
    if (!args[index].isFixnum()) return Error.TypeError;
    const n = args[index].toFixnum();
    if (n < 2 or n > 36) return Error.TypeError;
    return @intCast(n);
}

fn digitCharPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const c = try expectChar(args[0]);
    const radix = try radixOf(args, 1);
    const weight = character.digitWeight(c, radix) orelse return value.NIL;
    return Value.fromFixnum(weight);
}

fn digitCharFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    if (!args[0].isFixnum() or args[0].toFixnum() < 0) return Error.TypeError;
    const radix = try radixOf(args, 1);
    if (args[0].toFixnum() > std.math.maxInt(u8)) return value.NIL;
    const c = character.digitChar(@intCast(args[0].toFixnum()), radix) orelse return value.NIL;
    return Value.fromChar(c);
}
