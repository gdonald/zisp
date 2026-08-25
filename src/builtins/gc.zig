//! `gc` and `room`.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const format = @import("format.zig");
const collect_mod = @import("../eval/collect.zig");
const gc = @import("../runtime/gc.zig");
const symbol_mod = @import("../runtime/symbol.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerGc(ev: *Evaluator) !void {
    _ = try ev.defineNative("GC", &gcFn);
    _ = try ev.defineNative("ROOM", &roomFn);
    _ = try ev.defineNative("GET-INTERNAL-REAL-TIME", &internalRealTimeFn);
    try defineExtension(ev, "MAKE-WEAK-POINTER", &makeWeakPointerFn);
    try defineExtension(ev, "WEAK-POINTER-VALUE", &weakPointerValueFn);
    try defineExtension(ev, "WEAK-POINTERP", &weakPointerPFn);
    try defineExtension(ev, "FINALIZE", &finalizeFn);
    try defineExtension(ev, "CANCEL-FINALIZATION", &cancelFinalizationFn);
    function.asFunction(symbol_mod.symbol(
        try ev.interner.internExtension("WEAK-POINTER-VALUE"),
    ).function_cell).preserves_values = true;

    const units = try ev.interner.intern("INTERNAL-TIME-UNITS-PER-SECOND");
    symbol_mod.symbol(units).constant = true;
    symbol_mod.symbol(units).value_cell = Value.fromFixnum(INTERNAL_TIME_UNITS);

    const trigger = try ev.interner.intern(collect_mod.TRIGGER_VARIABLE);
    symbol_mod.symbol(trigger).special = true;
    symbol_mod.symbol(trigger).value_cell =
        Value.fromFixnum(@intCast(ev.heap.objects.collect_threshold));

    const floor = try ev.interner.intern(collect_mod.MAJOR_FLOOR_VARIABLE);
    symbol_mod.symbol(floor).special = true;
    symbol_mod.symbol(floor).value_cell = Value.fromFixnum(@intCast(ev.major_floor));

    const verbose = try ev.interner.intern(collect_mod.VERBOSE_VARIABLE);
    symbol_mod.symbol(verbose).special = true;
    symbol_mod.symbol(verbose).value_cell = value.NIL;
}

/// Ask for a collection. It runs once the evaluator is back at a top
/// level form, which is the only point where every live value is known
/// to a root scan.
fn gcFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    ev.gc_requested = true;
    return value.T;
}

/// Define a native under a name this implementation adds to the
/// standard rather than one the standard names.
fn defineExtension(ev: *Evaluator, name: []const u8, native: function.NativeFn) !void {
    const sym = try ev.interner.internExtension(name);
    symbol_mod.symbol(sym).function_cell =
        try function.allocNative(ev.heap.allocator, name, native);
}

/// A reference that does not keep what it refers to alive.
fn makeWeakPointerFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return ev.heap.allocWeakPointer(args[0]);
}

/// What the pointer refers to and whether it still refers to anything.
/// A collection that reclaimed the referent leaves `(values nil nil)`.
fn weakPointerValueFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!heap.isWeakPointer(args[0])) return Error.TypeError;
    const referent = heap.asWeakPointer(args[0]).referent;
    if (referent.equalsRaw(value.BROKEN)) {
        return ev.setValues(&.{ value.NIL, value.NIL });
    }
    return ev.setValues(&.{ referent, value.T });
}

fn weakPointerPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return if (heap.isWeakPointer(args[0])) value.T else value.NIL;
}

/// Arrange for `action` to be called once `object` has been reclaimed.
///
/// The registration holds the object weakly, so it is not what keeps the
/// object alive. An action that refers to the object would be, which is
/// why one is written to close over what it needs rather than over the
/// object itself.
fn finalizeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!function.isFunction(args[1])) return Error.TypeError;
    const weak = try ev.heap.allocWeakPointer(args[0]);
    try ev.finalizers.append(ev.allocator, .{ .object = weak, .action = args[1] });
    return args[0];
}

/// Drop every finalizer registered for `object`, and say whether there
/// was one.
fn cancelFinalizationFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var found = false;
    var index: usize = 0;
    while (index < ev.finalizers.items.len) {
        const referent = heap.asWeakPointer(ev.finalizers.items[index].object).referent;
        if (!referent.equalsRaw(args[0])) {
            index += 1;
            continue;
        }
        _ = ev.finalizers.orderedRemove(index);
        found = true;
    }
    return if (found) value.T else value.NIL;
}

/// What `get-internal-real-time` counts in. Microseconds: fine enough
/// to time a collection, coarse enough that a long run stays well inside
/// a fixnum.
pub const INTERNAL_TIME_UNITS: i64 = std.time.us_per_s;

/// Elapsed time on a clock that only ever moves forward, counted from
/// whatever point the host started it at.
fn internalRealTimeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 0) return Error.WrongArgCount;
    const io = ev.io orelse return Error.ProgramError;
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    return Value.fromFixnum(@intCast(@divFloor(now, std.time.ns_per_us)));
}

/// Heap figures as a property list. `(room t)` also prints them.
fn roomFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    const stats = ev.heap.objects.stats;

    const entries = [_]struct { name: []const u8, count: usize }{
        .{ .name = "LIVE-BYTES", .count = stats.live_bytes },
        .{ .name = "NURSERY-BYTES", .count = stats.nursery_bytes },
        .{ .name = "NURSERY-CAPACITY", .count = ev.heap.objects.nursery_capacity },
        .{ .name = "PROMOTED", .count = stats.promoted },
        .{ .name = "REGION-BYTES", .count = stats.region_bytes },
        .{ .name = "REGIONS", .count = ev.heap.objects.regionCount() },
        .{ .name = "FREE-BLOCKS", .count = stats.free_blocks },
        .{ .name = "FREE-BYTES", .count = stats.free_bytes },
        .{ .name = "FREE-CONSES", .count = stats.free_conses },
        .{ .name = "BYTES-SINCE-COLLECTION", .count = stats.bytes_since_collection },
        .{ .name = "ALLOCATIONS", .count = stats.generation },
        .{ .name = "COLLECTIONS", .count = ev.gc_count },
        .{ .name = "MAJOR-COLLECTIONS", .count = ev.major_count },
        .{ .name = "GC-TIME-NS", .count = stats.gc_time_ns },
        .{ .name = "GC-PAUSE-MAX-NS", .count = stats.gc_pause_max_ns },
    };

    if (args.len == 1 and !args[0].equalsRaw(value.NIL)) {
        const out = ev.out orelse return Error.NoOutputStream;
        for (entries) |entry| {
            try out.print("{s}: {d}\n", .{ entry.name, entry.count });
        }
        try out.print("GC-PAUSES:", .{});
        for (stats.pauses) |count| try out.print(" {d}", .{count});
        try out.print("\n", .{});
        ev.output_column = 0;
    }

    var builder = ev.heap.listBuilder();
    for (entries) |entry| {
        try builder.append(try ev.interner.internKeyword(entry.name));
        try builder.append(Value.fromFixnum(@intCast(entry.count)));
    }
    try builder.append(try ev.interner.internKeyword("GC-PAUSES"));
    try builder.append(try pauseHistogram(ev, stats.pauses));
    return builder.finish();
}

/// How many collections fell in each pause bucket, longest bucket last.
fn pauseHistogram(ev: *Evaluator, counts: [gc.PAUSE_BUCKETS]u32) Error!Value {
    var builder = ev.heap.listBuilder();
    for (counts) |count| try builder.append(Value.fromFixnum(count));
    return builder.finish();
}
