//! `gc` and `room`.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const format = @import("format.zig");
const collect_mod = @import("../eval/collect.zig");
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

    const trigger = try ev.interner.intern(collect_mod.TRIGGER_VARIABLE);
    symbol_mod.symbol(trigger).special = true;
    symbol_mod.symbol(trigger).value_cell =
        Value.fromFixnum(@intCast(ev.heap.objects.collect_threshold));

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
    };

    if (args.len == 1 and !args[0].equalsRaw(value.NIL)) {
        const out = ev.out orelse return Error.NoOutputStream;
        for (entries) |entry| {
            try out.print("{s}: {d}\n", .{ entry.name, entry.count });
        }
        ev.output_column = 0;
    }

    var builder = ev.heap.listBuilder();
    for (entries) |entry| {
        try builder.append(try ev.interner.internKeyword(entry.name));
        try builder.append(Value.fromFixnum(@intCast(entry.count)));
    }
    return builder.finish();
}
