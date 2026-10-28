//! The natives the foreign function interface in `src/lisp/ffi.lisp` is
//! built on: looking up C symbols, calling C functions, and reading and
//! writing foreign memory. Addresses are integers here. The Lisp side
//! wraps them in `foreign-pointer`s.

const std = @import("std");
const build_options = @import("build_options");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const bignum = @import("../runtime/bignum.zig");
const equality = @import("../runtime/equality.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const function = @import("../eval/function.zig");
const eval_mod = @import("../eval/eval.zig");
const strings = @import("strings.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerFfi(ev: *Evaluator) !void {
    if (build_options.freestanding) return;
    _ = try ev.defineNative("%FOREIGN-SYMBOL-ADDRESS", &foreignSymbolAddressFn);
    _ = try ev.defineNative("%LOAD-FOREIGN-LIBRARY", &loadForeignLibraryFn);
    _ = try ev.defineNative("%FOREIGN-CALL", &foreignCallFn);
    _ = try ev.defineNative("%FOREIGN-ALLOC", &foreignAllocFn);
    _ = try ev.defineNative("%FOREIGN-FREE", &foreignFreeFn);
    _ = try ev.defineNative("%MEM-REF", &memRefFn);
    _ = try ev.defineNative("%MEM-SET", &memSetFn);
    _ = try ev.defineNative("%FOREIGN-STRING-TO-LISP", &foreignStringToLispFn);
    _ = try ev.defineNative("%LISP-STRING-TO-FOREIGN", &lispStringToForeignFn);
    _ = try ev.defineNative("%CALLBACK-ADDRESS", &callbackAddressFn);
}

/// A C type, named by the keyword the Lisp side canonicalizes aliases to.
pub const CType = enum {
    char,
    unsigned_char,
    short,
    unsigned_short,
    int,
    unsigned_int,
    long,
    unsigned_long,
    long_long,
    unsigned_long_long,
    pointer,
    string,
    float,
    double,
    void,

    fn fromKeyword(v: Value) Error!CType {
        if (!v.isSymbol()) return Error.TypeError;
        const name = symbol_mod.symbol(v).name;
        inline for (@typeInfo(CType).@"enum".field_names) |field| {
            if (keywordMatches(name, field)) return @field(CType, field);
        }
        return Error.TypeError;
    }

    fn keywordMatches(name: []const u8, field: []const u8) bool {
        if (name.len != field.len) return false;
        for (name, field) |n, f| {
            const want = if (f == '_') '-' else std.ascii.toUpper(f);
            if (n != want) return false;
        }
        return true;
    }

    /// The integers the type holds, for an integer type.
    fn bounds(self: CType) ?struct { lo: i128, hi: i128 } {
        return switch (self) {
            .char => .{ .lo = std.math.minInt(i8), .hi = std.math.maxInt(i8) },
            .unsigned_char => .{ .lo = 0, .hi = std.math.maxInt(u8) },
            .short => .{ .lo = std.math.minInt(c_short), .hi = std.math.maxInt(c_short) },
            .unsigned_short => .{ .lo = 0, .hi = std.math.maxInt(c_ushort) },
            .int => .{ .lo = std.math.minInt(c_int), .hi = std.math.maxInt(c_int) },
            .unsigned_int => .{ .lo = 0, .hi = std.math.maxInt(c_uint) },
            .long => .{ .lo = std.math.minInt(c_long), .hi = std.math.maxInt(c_long) },
            .unsigned_long => .{ .lo = 0, .hi = std.math.maxInt(c_ulong) },
            .long_long => .{ .lo = std.math.minInt(c_longlong), .hi = std.math.maxInt(c_longlong) },
            .unsigned_long_long, .pointer, .string => .{ .lo = 0, .hi = std.math.maxInt(c_ulonglong) },
            .float, .double, .void => null,
        };
    }

    fn isFloat(self: CType) bool {
        return self == .float or self == .double;
    }
};

/// How many arguments of each class a call passes. Both x86_64 and
/// aarch64 pass the integer and pointer arguments of a call that is not
/// variadic in integer registers in order, and the float arguments in
/// float registers in order, each class independently of the other, so
/// any such call is made through one function type. These are the
/// registers x86_64 has.
const INTEGER_ARGS = 6;
const FLOAT_ARGS = 8;

const IntegerResultFn = *const fn (u64, u64, u64, u64, u64, u64, f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) u64;
const FloatResultFn = *const fn (u64, u64, u64, u64, u64, u64, f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) f64;

fn integerOf(v: Value) Error!i128 {
    if (v.isFixnum()) return v.toFixnum();
    if (!heap.isBignum(v)) return Error.TypeError;
    var scratch: bignum.Scratch = .{};
    return scratch.view(v).toInt(i128) catch Error.TypeError;
}

fn addressOf(v: Value) Error!usize {
    if (v.equalsRaw(value.NIL)) return 0;
    const n = try integerOf(v);
    if (n < 0 or n > std.math.maxInt(usize)) return Error.TypeError;
    return @intCast(n);
}

fn integerValue(ev: *Evaluator, n: i128) Error!Value {
    return bignum.fromI128(ev.heap, n);
}

/// A NUL-terminated UTF-8 copy of a Lisp string, from `malloc`.
fn foreignString(v: Value) Error![*:0]u8 {
    const codes = try strings.charsOf(v);
    var length: usize = 0;
    for (codes) |code| length += std.unicode.utf8CodepointSequenceLength(@intCast(code)) catch return Error.TypeError;
    const bytes: [*]u8 = @ptrCast(std.c.malloc(length + 1) orelse return Error.OutOfMemory);
    var at: usize = 0;
    for (codes) |code| at += std.unicode.utf8Encode(@intCast(code), bytes[at..length]) catch unreachable;
    bytes[length] = 0;
    return bytes[0..length :0];
}

fn lispString(ev: *Evaluator, address: usize) Error!Value {
    if (address == 0) return value.NIL;
    const text: [*:0]const u8 = @ptrFromInt(address);
    return ev.heap.allocString(std.mem.span(text));
}

/// `(%foreign-symbol-address name)`: the address of the C symbol `name`
/// in the program or a library loaded so far, or NIL.
fn foreignSymbolAddressFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const name = try foreignString(args[0]);
    defer std.c.free(name);
    const program = std.c.dlopen(null, .{ .NOW = true }) orelse return value.NIL;
    const address = std.c.dlsym(program, name) orelse return value.NIL;
    return integerValue(ev, @intFromPtr(address));
}

/// `(%load-foreign-library path)`: T, or the text of the failure.
fn loadForeignLibraryFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const path = try foreignString(args[0]);
    defer std.c.free(path);
    if (std.c.dlopen(path, .{ .NOW = true, .GLOBAL = true }) != null) return value.T;
    const reason = std.c.dlerror() orelse return ev.heap.allocString("the library could not be loaded");
    return ev.heap.allocString(std.mem.span(reason));
}

/// `(%foreign-call address return-type arg-types args)`: call the C
/// function at `address`. An integer or pointer argument is an integer,
/// or NIL for a null pointer. A `:pointer` or `:string` argument can be a
/// string too, passed as a NUL-terminated UTF-8 copy that lasts for the
/// call.
fn foreignCallFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 4) return Error.WrongArgCount;
    const address = try addressOf(args[0]);
    if (address == 0) return Error.TypeError;
    const result_type = try CType.fromKeyword(args[1]);

    var integers: [INTEGER_ARGS]u64 = @splat(0);
    var floats: [FLOAT_ARGS]f64 = @splat(0);
    var integer_count: usize = 0;
    var float_count: usize = 0;
    var copies: [INTEGER_ARGS]?[*:0]u8 = @splat(null);
    defer for (copies) |copy| if (copy) |c| std.c.free(c);

    var types = args[2];
    var values = args[3];
    while (types.isCons()) : ({
        types = heap.cdr(types);
        values = heap.cdr(values);
    }) {
        if (!values.isCons()) return Error.WrongArgCount;
        const t = try CType.fromKeyword(heap.car(types));
        const arg = heap.car(values);
        if (t.isFloat()) {
            if (float_count == FLOAT_ARGS) return Error.WrongArgCount;
            if (!equality.isNumber(arg)) return Error.TypeError;
            const x = equality.toF64(arg);
            floats[float_count] = floatBits(t, x);
            float_count += 1;
            continue;
        }
        if (t == .void) return Error.TypeError;
        if (integer_count == INTEGER_ARGS) return Error.WrongArgCount;
        integers[integer_count] = try integerArgument(t, arg, &copies[integer_count]);
        integer_count += 1;
    }
    if (!values.equalsRaw(value.NIL)) return Error.WrongArgCount;

    callback_evaluator = ev;
    if (result_type.isFloat()) {
        const callee: FloatResultFn = @ptrFromInt(address);
        const x = callee(integers[0], integers[1], integers[2], integers[3], integers[4], integers[5], floats[0], floats[1], floats[2], floats[3], floats[4], floats[5], floats[6], floats[7]);
        try takePendingExit();
        return floatValue(ev, result_type, x);
    }
    const callee: IntegerResultFn = @ptrFromInt(address);
    const raw = callee(integers[0], integers[1], integers[2], integers[3], integers[4], integers[5], floats[0], floats[1], floats[2], floats[3], floats[4], floats[5], floats[6], floats[7]);
    try takePendingExit();
    return integerResult(ev, result_type, raw);
}

fn floatValue(ev: *Evaluator, t: CType, x: f64) Error!Value {
    if (t == .float) return Value.fromSingleFloat(@bitCast(@as(u32, @truncate(@as(u64, @bitCast(x))))));
    return ev.heap.allocDoubleFloat(x);
}

fn floatBits(t: CType, x: f64) f64 {
    if (t == .float) return @bitCast(@as(u64, @as(u32, @bitCast(@as(f32, @floatCast(x))))));
    return x;
}

// --- callbacks ---

/// How many callbacks of each result class can exist at once. Slots
/// below this return an integer and the rest a double.
const CALLBACK_SLOTS = 32;

/// The evaluator callbacks run Lisp in: the one that made the latest
/// foreign call.
var callback_evaluator: ?*Evaluator = null;

/// The exit a callback's Lisp function took, which cannot unwind through
/// the C frames under it and is taken when the foreign call returns.
var pending_exit: ?Error = null;

fn takePendingExit() Error!void {
    const exit = pending_exit orelse return;
    pending_exit = null;
    return exit;
}

fn CallbackEntry(comptime slot: usize, comptime R: type) type {
    return struct {
        fn entry(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, f0: f64, f1: f64, f2: f64, f3: f64, f4: f64, f5: f64, f6: f64, f7: f64) callconv(.c) R {
            const ev = callback_evaluator orelse return 0;
            const integers = [INTEGER_ARGS]u64{ a0, a1, a2, a3, a4, a5 };
            const floats = [FLOAT_ARGS]f64{ f0, f1, f2, f3, f4, f5, f6, f7 };
            return runCallback(R, ev, slot, &integers, &floats) catch |err| {
                if (pending_exit == null) pending_exit = err;
                return 0;
            };
        }
    };
}

const integer_callbacks: [CALLBACK_SLOTS]IntegerResultFn = blk: {
    var table: [CALLBACK_SLOTS]IntegerResultFn = undefined;
    for (0..CALLBACK_SLOTS) |slot| table[slot] = &CallbackEntry(slot, u64).entry;
    break :blk table;
};

const float_callbacks: [CALLBACK_SLOTS]FloatResultFn = blk: {
    var table: [CALLBACK_SLOTS]FloatResultFn = undefined;
    for (0..CALLBACK_SLOTS) |slot| table[slot] = &CallbackEntry(CALLBACK_SLOTS + slot, f64).entry;
    break :blk table;
};

/// `(%callback-address slot)`: the entry point of a slot in the pool.
fn callbackAddressFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isFixnum()) return Error.TypeError;
    const slot = args[0].toFixnum();
    if (slot < 0 or slot >= 2 * CALLBACK_SLOTS) return Error.TypeError;
    const index: usize = @intCast(slot);
    if (index < CALLBACK_SLOTS) return integerValue(ev, @intFromPtr(integer_callbacks[index]));
    return integerValue(ev, @intFromPtr(float_callbacks[index - CALLBACK_SLOTS]));
}

/// Run the Lisp function `*%callbacks*` holds for `slot` on the
/// arguments C passed, and give back its result as C wants it.
fn runCallback(comptime R: type, ev: *Evaluator, slot: usize, integers: *const [INTEGER_ARGS]u64, floats: *const [FLOAT_ARGS]f64) Error!R {
    const table = symbol_mod.symbol(try ev.interner.intern("*%CALLBACKS*")).value_cell;
    if (table.tag() != .heap or heap.heapType(table) != .vector) return Error.TypeError;
    const entry = heap.asArray(table).storage[slot];
    if (!entry.isCons()) return Error.UnboundFunction;
    const result_type = try CType.fromKeyword(heap.car(heap.cdr(entry)));

    var held = ev.heap.protect();
    defer held.close();
    try held.push(heap.car(entry));
    var integer_count: usize = 0;
    var float_count: usize = 0;
    var types = heap.cdr(heap.cdr(entry));
    while (types.isCons()) : (types = heap.cdr(types)) {
        const t = try CType.fromKeyword(heap.car(types));
        if (t.isFloat()) {
            try held.push(try floatValue(ev, t, floats[float_count]));
            float_count += 1;
        } else {
            try held.push(try integerResult(ev, t, integers[integer_count]));
            integer_count += 1;
        }
    }
    const result = try ev.callFunction(held.items()[0], held.items()[1..]);
    if (R == f64) {
        if (!equality.isNumber(result)) return Error.TypeError;
        return floatBits(result_type, equality.toF64(result));
    }
    if (result_type == .void) return 0;
    if (result_type == .string) return Error.TypeError;
    var unused: ?[*:0]u8 = null;
    if (heap.isString(result)) return Error.TypeError;
    return integerArgument(result_type, result, &unused);
}

fn integerArgument(t: CType, arg: Value, copy: *?[*:0]u8) Error!u64 {
    if ((t == .pointer or t == .string) and heap.isString(arg)) {
        const text = try foreignString(arg);
        copy.* = text;
        return @intFromPtr(text);
    }
    if (t == .pointer or t == .string) return addressOf(arg);
    const n: i128 = if ((t == .char or t == .unsigned_char) and arg.isChar()) arg.toChar() else try integerOf(arg);
    const range = t.bounds().?;
    if (n < range.lo or n > range.hi) return Error.TypeError;
    return @truncate(@as(u128, @bitCast(n)));
}

/// What a C function's integer result register holds, as the Lisp value
/// for `t`: the low bits the type has, extended by its sign.
fn integerResult(ev: *Evaluator, t: CType, raw: u64) Error!Value {
    return switch (t) {
        .void => value.NIL,
        .char => Value.fromFixnum(@as(i8, @truncate(@as(i64, @bitCast(raw))))),
        .unsigned_char => Value.fromFixnum(@as(u8, @truncate(raw))),
        .short => Value.fromFixnum(@as(c_short, @truncate(@as(i64, @bitCast(raw))))),
        .unsigned_short => Value.fromFixnum(@as(c_ushort, @truncate(raw))),
        .int => Value.fromFixnum(@as(c_int, @truncate(@as(i64, @bitCast(raw))))),
        .unsigned_int => Value.fromFixnum(@as(c_uint, @truncate(raw))),
        .long, .long_long => integerValue(ev, @as(i64, @bitCast(raw))),
        .unsigned_long, .unsigned_long_long, .pointer => integerValue(ev, raw),
        .string => lispString(ev, @intCast(raw)),
        .float, .double => unreachable,
    };
}

/// `(%foreign-alloc size)`: the address of `size` bytes from `malloc`.
fn foreignAllocFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const size = try integerOf(args[0]);
    if (size < 0 or size > std.math.maxInt(usize)) return Error.TypeError;
    const memory = std.c.malloc(@max(@as(usize, @intCast(size)), 1)) orelse return Error.OutOfMemory;
    return integerValue(ev, @intFromPtr(memory));
}

/// `(%foreign-free address)`.
fn foreignFreeFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    const address = try addressOf(args[0]);
    if (address != 0) std.c.free(@ptrFromInt(address));
    return value.NIL;
}

fn Pointee(comptime t: CType) type {
    return switch (t) {
        .char => i8,
        .unsigned_char => u8,
        .short => c_short,
        .unsigned_short => c_ushort,
        .int => c_int,
        .unsigned_int => c_uint,
        .long => c_long,
        .unsigned_long => c_ulong,
        .long_long => c_longlong,
        .unsigned_long_long => c_ulonglong,
        .pointer, .string => usize,
        .float => f32,
        .double => f64,
        .void => void,
    };
}

/// `(%mem-ref address type)`: the value of `type` stored at `address`.
fn memRefFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const address = try addressOf(args[0]);
    if (address == 0) return Error.TypeError;
    switch (try CType.fromKeyword(args[1])) {
        .void => return Error.TypeError,
        inline else => |t| {
            const stored = @as(*align(1) const Pointee(t), @ptrFromInt(address)).*;
            return switch (t) {
                .float => Value.fromSingleFloat(stored),
                .double => ev.heap.allocDoubleFloat(stored),
                .string => lispString(ev, stored),
                else => integerValue(ev, stored),
            };
        },
    }
}

/// `(%mem-set address type value)`: store `value` as a `type` at
/// `address`.
fn memSetFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 3) return Error.WrongArgCount;
    const address = try addressOf(args[0]);
    if (address == 0) return Error.TypeError;
    const new = args[2];
    switch (try CType.fromKeyword(args[1])) {
        .void, .string => return Error.TypeError,
        inline .float, .double => |t| {
            if (!equality.isNumber(new)) return Error.TypeError;
            @as(*align(1) Pointee(t), @ptrFromInt(address)).* = @floatCast(equality.toF64(new));
        },
        inline else => |t| {
            if (heap.isString(new)) return Error.TypeError;
            var unused: ?[*:0]u8 = null;
            const bits = try integerArgument(t, new, &unused);
            @as(*align(1) Pointee(t), @ptrFromInt(address)).* = @bitCast(@as(@Int(.unsigned, @bitSizeOf(Pointee(t))), @truncate(bits)));
        },
    }
    return new;
}

/// `(%foreign-string-to-lisp address)`: the NUL-terminated UTF-8 string
/// at `address`, or NIL for a null pointer.
fn foreignStringToLispFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return lispString(ev, try addressOf(args[0]));
}

/// `(%lisp-string-to-foreign string)`: the address of a NUL-terminated
/// UTF-8 copy of `string`, from `malloc`.
fn lispStringToForeignFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return integerValue(ev, @intFromPtr(try foreignString(args[0])));
}
