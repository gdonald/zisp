//! Root scanning and the collection cycle.
//!
//! A collection runs at a safe point: `(gc)`, or the top of the loop that
//! reads and evaluates one top-level form at a time. Nowhere else is it
//! safe yet, because a native builtin part-way through its work holds
//! values in Zig locals that nothing here can see.

const std = @import("std");
const value = @import("../runtime/value.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const mark_mod = @import("../runtime/mark.zig");
const eval_mod = @import("eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;

/// Mark everything reachable, then reclaim the rest.
pub fn collect(ev: *Evaluator) !void {
    var marker = mark_mod.Marker.init(ev.allocator, ev.heap);
    defer marker.deinit();
    try pushRoots(&marker, ev);
    try marker.run();

    // Source positions are keyed on a cons address, so an entry for a
    // dead cons has to go before that address is handed out again.
    if (ev.positions) |table| {
        var it = table.map.iterator();
        var stale: std.ArrayListUnmanaged(u64) = .empty;
        defer stale.deinit(ev.allocator);
        while (it.next()) |entry| {
            if (!ev.heap.objects.isMarked(entry.key_ptr.*)) {
                try stale.append(ev.allocator, entry.key_ptr.*);
            }
        }
        for (stale.items) |key| _ = table.map.remove(key);
    }

    ev.heap.sweep();
    ev.gc_count += 1;
    ev.gc_requested = false;
}

/// How much may be handed out between collections.
pub const TRIGGER_VARIABLE = "*GC-TRIGGER*";
/// Whether each collection reports what it reclaimed.
pub const VERBOSE_VARIABLE = "*GC-VERBOSE*";

/// Collect if `gc` asked for it, or if enough has been allocated since
/// the last cycle.
pub fn maybeCollect(ev: *Evaluator) !void {
    applyTrigger(ev);
    if (!ev.gc_requested and !ev.heap.objects.collectionDue()) return;

    const before = ev.heap.objects.stats.live_bytes;
    try collect(ev);
    if (!verbose(ev)) return;
    const out = ev.out orelse return;
    try out.print(
        ";; GC: {d} bytes live, {d} reclaimed\n",
        .{ ev.heap.objects.stats.live_bytes, before - ev.heap.objects.stats.live_bytes },
    );
    ev.output_column = 0;
}

fn specialValue(ev: *Evaluator, name: []const u8) ?Value {
    const found = ev.interner.cl.findPresent(name) orelse return null;
    return symbol_mod.symbol(found.sym).value_cell;
}

fn applyTrigger(ev: *Evaluator) void {
    const setting = specialValue(ev, TRIGGER_VARIABLE) orelse return;
    if (!setting.isFixnum()) return;
    const bytes = setting.toFixnum();
    if (bytes < 0) return;
    ev.heap.objects.collect_threshold = @intCast(bytes);
}

fn verbose(ev: *Evaluator) bool {
    const setting = specialValue(ev, VERBOSE_VARIABLE) orelse return false;
    return !setting.equalsRaw(value.NIL);
}

pub fn pushRoots(marker: *mark_mod.Marker, ev: *Evaluator) !void {
    mark_mod.Marker.source = "the symbol table";
    try pushSymbols(marker, ev);
    mark_mod.Marker.source = "the environment";
    try pushEnvironment(marker, ev);
    try pushEvaluatorState(marker, ev);
    mark_mod.Marker.source = "reachable structure";
}

/// Every symbol in every live package, whose value, function and property
/// cells the marker descends into. Symbols themselves are not collected:
/// they live in the interner's arena.
fn pushSymbols(marker: *mark_mod.Marker, ev: *Evaluator) !void {
    for (ev.interner.registry.list.items) |pkg| {
        for ([_]*const std.StringHashMapUnmanaged(Value){ &pkg.internal, &pkg.external }) |table| {
            var it = table.valueIterator();
            while (it.next()) |sym| try marker.push(sym.*);
        }
    }
}

/// The frames currently in scope. Their parents come with them, and a
/// frame some live closure captured is reached through that closure. The
/// environment's own list of every frame it has handed out is not a root:
/// it never shrinks, so scanning it would keep every binding a finished
/// call made alive forever.
fn pushEnvironment(marker: *mark_mod.Marker, ev: *Evaluator) !void {
    try marker.pushFrame(ev.env.top_value);
    try marker.pushFrame(ev.env.top_function);
    // The chains of the calls further up, which are set aside while the
    // call in flight runs.
    for (ev.env.saved_chains.items) |frame| try marker.pushFrame(frame);
}

fn pushEvaluatorState(marker: *mark_mod.Marker, ev: *Evaluator) !void {
    mark_mod.Marker.source = "the Lisp stack";
    var chunk: usize = 0;
    while (chunk < ev.heap.stack.chunkCount()) : (chunk += 1) {
        for (ev.heap.stack.live(chunk)) |v| try marker.push(v);
    }
    mark_mod.Marker.source = "the value channel";
    for (ev.values.items) |v| try marker.push(v);
    for (ev.transfer_values.items) |v| try marker.push(v);
    mark_mod.Marker.source = "the evaluator";
    for (ev.pinned.items) |v| try marker.push(v);
    for (ev.block_stack.items) |entry| try marker.push(entry.name);
    for (ev.tagbody_stack.items) |entry| try marker.push(entry.body);
    for (ev.catch_stack.items) |entry| try marker.push(entry.tag);
    for (ev.dynamic_stack.items) |entry| {
        try marker.push(entry.sym);
        try marker.push(entry.saved);
    }
    try marker.push(ev.current_form);
    try marker.push(ev.go_target);
    try marker.push(ev.error_symbol);

    var hosts = ev.logical_hosts.valueIterator();
    while (hosts.next()) |translations| try marker.push(translations.*);
}
