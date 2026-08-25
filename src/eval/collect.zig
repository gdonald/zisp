//! Root scanning and the collection cycle.
//!
//! A collection that moves runs at a safe point: `(gc)`, or the top of
//! the loop that reads and evaluates one top-level form at a time.
//! Nowhere else is moving safe yet, because a native builtin part-way
//! through its work holds values in Zig locals that nothing here can
//! write back into.
//!
//! One that only reclaims runs from inside an allocation as well, which
//! is what keeps a form that allocates for a long time from spilling
//! everything it makes into the tenured space.

const std = @import("std");
const value = @import("../runtime/value.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const mark_mod = @import("../runtime/mark.zig");
const evacuate_mod = @import("../runtime/evacuate.zig");
const gc_mod = @import("../runtime/gc.zig");
const heap_mod = @import("../runtime/heap.zig");
const env_mod = @import("env.zig");
const eval_mod = @import("eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;

/// What one collection covers.
///
/// A minor one is about the nursery: it reaches the young objects
/// through the roots and the dirty cards, leaves the tenured space
/// alone, and costs what the program has just made. A major one marks
/// and sweeps everything, which is what reclaims the tenured space.
pub const Scope = enum { minor, major };

/// How much the tenured space may grow before a major collection is due.
const MAJOR_GROWTH: usize = 4;

fn majorDue(ev: *const Evaluator) bool {
    const live = ev.heap.objects.stats.live_bytes;
    if (live < ev.major_floor) return false;
    return live > ev.live_after_major *| MAJOR_GROWTH;
}

/// Reclaim the nursery, and the tenured space too when a major is due.
///
/// A collection someone asked for walks everything: `gc` means reclaim
/// what you can, not reclaim what is cheapest.
pub fn collect(ev: *Evaluator) !void {
    const scope: Scope = if (ev.gc_requested or majorDue(ev)) .major else .minor;
    return collectScoped(ev, scope);
}

pub fn collectScoped(ev: *Evaluator, scope: Scope) !void {
    // The mutator is stopped for the whole cycle, so what this measures
    // is the pause a program sees rather than the work the collector
    // did. An evaluator with no clock records no pauses.
    const started: ?std.Io.Timestamp = if (ev.io) |io| .now(io, .awake) else null;
    defer if (started) |begin| recordPause(ev, begin);

    // Cached expansions are keyed on a cons address and are reachable only
    // from the cache, so they go before anything moves or is marked.
    ev.macro_cache.clearRetainingCapacity();

    // A collection from inside an allocation runs where Zig locals hold
    // values the root scan can see on the protect stack but cannot write
    // back into the local. Marking copes with that and moving does not,
    // so nothing is copied: both generations are marked and swept where
    // they stand.
    if (!ev.heap.collecting) try evacuateNursery(ev);

    // A moving collection has emptied the nursery by now, so a minor one
    // that got that far has nothing left to mark or sweep.
    if (scope == .minor and !ev.heap.collecting) {
        try harvestFinalizers(ev);
        ev.gc_count += 1;
        ev.gc_requested = false;
        return;
    }

    var marker = mark_mod.Marker.init(ev.allocator, ev.heap);
    marker.reach = if (scope == .minor) .young else .everything;
    defer marker.deinit();
    if (scope == .minor) try pushCardRoots(&marker, ev);
    try pushRoots(&marker, ev);
    try marker.run();
    marker.breakDeadWeakPointers();

    // Source positions are keyed on a cons address, so an entry for a
    // dead cons has to go before that address is handed out again. Both
    // generations carry mark bits, and the copy takes an entry with the
    // cons it moved, so what is left unmarked here is what died.
    if (ev.positions) |table| {
        var it = table.map.iterator();
        var stale: std.ArrayListUnmanaged(u64) = .empty;
        defer stale.deinit(ev.allocator);
        while (it.next()) |entry| {
            const address = entry.key_ptr.*;
            if (!ev.heap.objects.owns(address)) continue;
            // A minor collection marked the nursery alone, so a tenured
            // address carries no mark either way and is left as it is.
            if (scope == .minor and !ev.heap.objects.inNursery(address)) continue;
            if (!ev.heap.objects.isMarked(address)) {
                try stale.append(ev.allocator, address);
            }
        }
        for (stale.items) |key| _ = table.map.remove(key);
    }

    ev.heap.sweep(if (scope == .minor) .nursery else .everything);
    try harvestFinalizers(ev);
    if (scope == .major) {
        ev.live_after_major = ev.heap.objects.stats.live_bytes;
        ev.major_count += 1;
    }
    ev.gc_count += 1;
    ev.gc_requested = false;
}

/// Move the finalizers whose object has gone onto the pending queue.
///
/// This only shuffles values between two lists, so it is safe where
/// running one would not be. What runs them is whatever was evaluating
/// when the collection happened.
fn harvestFinalizers(ev: *Evaluator) !void {
    var index: usize = 0;
    while (index < ev.finalizers.items.len) {
        const entry = ev.finalizers.items[index];
        if (!heap_mod.asWeakPointer(entry.object).referent.equalsRaw(value.BROKEN)) {
            index += 1;
            continue;
        }
        try ev.pending.append(ev.allocator, entry.action);
        _ = ev.finalizers.orderedRemove(index);
    }
}

/// Run what the last collection left pending.
///
/// A finalizer may allocate, and so set off a collection of its own.
/// What that collection finds goes on the back of the queue and waits
/// for the next pass: only the entries the pass started with are run,
/// and a pass never starts inside another.
pub fn runFinalizers(ev: *Evaluator) !void {
    if (ev.draining) return;
    if (ev.pending.items.len == 0) return;
    ev.draining = true;
    defer ev.draining = false;

    var remaining = ev.pending.items.len;
    while (remaining > 0) : (remaining -= 1) {
        const action = ev.pending.orderedRemove(0);
        var held = ev.protect();
        defer held.close();
        try held.push(action);
        _ = try ev.callFunction(action, &.{});
    }
}

/// The slots of every dirty card, as roots. What a tenured object refers
/// to in the nursery is reachable no other way once the walk stops at
/// the tenured space.
fn pushCardRoots(marker: *mark_mod.Marker, ev: *Evaluator) std.mem.Allocator.Error!void {
    mark_mod.Marker.source = "a dirty card";
    ev.heap.objects.scanConses(.dirty_cards, marker, pushCell) catch |e| return narrow(e);
    ev.heap.objects.scanObjects(.dirty_cards, marker, pushObject) catch |e| return narrow(e);
}

/// The scanners hand back whatever the callback failed with, and the
/// callbacks here fail only the one way.
fn narrow(e: anyerror) std.mem.Allocator.Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn pushCell(marker: *mark_mod.Marker, cell: [*]align(gc_mod.ALIGNMENT) u8) anyerror!void {
    try marker.pushSlots(Value.fromConsAddr(@intFromPtr(cell)));
}

fn pushObject(marker: *mark_mod.Marker, payload: [*]align(gc_mod.ALIGNMENT) u8) anyerror!void {
    try marker.pushSlots(Value.fromHeapAddr(@intFromPtr(payload)));
}

/// How long the collection that began at `started` took, on the
/// evaluator's own clock.
fn recordPause(ev: *Evaluator, started: std.Io.Timestamp) void {
    const io = ev.io orelse return;
    const elapsed = started.durationTo(.now(io, .awake)).nanoseconds;
    // A clock coarse enough to report nothing still counts the pause,
    // so the buckets account for every collection.
    ev.heap.objects.recordPause(if (elapsed > 0) @intCast(elapsed) else 0);
}

/// Copy the nursery's survivors into the tenured space and hand the
/// nursery back to its bump pointer. Every reference to a copied object
/// is rewritten on the way, so nothing points into the nursery after
/// this returns.
fn evacuateNursery(ev: *Evaluator) !void {
    var e = evacuate_mod.Evacuator.init(ev.allocator, ev.heap);
    defer e.deinit();

    // The cards go first: a tenured object that was made to point at a
    // young one is not reachable from the roots, and the walk no longer
    // descends into the tenured space to find it.
    try e.scanCards();
    try updateRoots(&e, ev);
    try e.drain();
    e.resolveWeakPointers();
    try e.rebuildTables();
    try repositionMoved(&e, ev);

    // Nothing points into the nursery any more, so nothing is recorded
    // against the tenured space either.
    ev.heap.objects.clearCards();
    ev.heap.objects.resetNursery();
    ev.heap.objects.stats.promoted = e.copied;
}

/// Every slot a collection may find a value in that nothing else points
/// at: the symbol table, the environment, and the evaluator's own state.
fn updateRoots(e: *evacuate_mod.Evacuator, ev: *Evaluator) !void {
    for (ev.interner.registry.list.items) |pkg| {
        for ([_]*const std.StringHashMapUnmanaged(Value){ &pkg.internal, &pkg.external }) |table| {
            var it = table.valueIterator();
            // A symbol never moves; its three cells are what get updated.
            while (it.next()) |sym| {
                var held = sym.*;
                try e.update(&held);
            }
        }
    }

    try e.pushFrame(ev.env.top_value);
    try e.pushFrame(ev.env.top_function);
    for (ev.env.saved_chains.items) |frame| try e.pushFrame(frame);

    var chunk: usize = 0;
    while (chunk < ev.heap.stack.chunkCount()) : (chunk += 1) {
        for (ev.heap.stack.liveMut(chunk)) |*v| try e.update(v);
    }
    for (ev.values.items) |*v| try e.update(v);
    for (ev.transfer_values.items) |*v| try e.update(v);
    for (ev.pinned.items) |*v| try e.update(v);
    for (ev.finalizers.items) |*entry| {
        try e.update(&entry.object);
        try e.update(&entry.action);
    }
    for (ev.pending.items) |*v| try e.update(v);
    for (ev.block_stack.items) |*entry| try e.update(&entry.name);
    for (ev.tagbody_stack.items) |*entry| try e.update(&entry.body);
    for (ev.catch_stack.items) |*entry| try e.update(&entry.tag);
    for (ev.dynamic_stack.items) |*entry| {
        try e.update(&entry.sym);
        try e.update(&entry.saved);
    }
    try e.update(&ev.current_form);
    try e.update(&ev.go_target);
    var hosts = ev.logical_hosts.valueIterator();
    while (hosts.next()) |v| try e.update(v);
}

/// Source positions are keyed on a cons address, so a cons that moved
/// takes its entry with it and one the copy left behind loses it: after
/// this the nursery holds nothing anybody can name.
fn repositionMoved(e: *evacuate_mod.Evacuator, ev: *Evaluator) !void {
    const table = ev.positions orelse return;

    var young: std.ArrayListUnmanaged(u64) = .empty;
    defer young.deinit(ev.allocator);
    var it = table.map.iterator();
    while (it.next()) |entry| {
        if (ev.heap.objects.inNursery(entry.key_ptr.*)) {
            try young.append(ev.allocator, entry.key_ptr.*);
        }
    }

    for (young.items) |address| {
        const pos = table.map.get(address).?;
        _ = table.map.remove(address);
        const moved = e.movedCons(address) orelse continue;
        try table.record(moved, pos);
    }
}

/// How much may be handed out between collections.
pub const TRIGGER_VARIABLE = "*GC-TRIGGER*";
/// The smallest tenured space a major collection is asked to walk.
pub const MAJOR_FLOOR_VARIABLE = "*GC-MAJOR-FLOOR*";
/// Whether each collection reports what it reclaimed.
pub const VERBOSE_VARIABLE = "*GC-VERBOSE*";

/// Collect if `gc` asked for it, or if enough has been allocated since
/// the last cycle.
pub fn maybeCollect(ev: *Evaluator) !void {
    applyTrigger(ev);
    if (ev.gc_requested or ev.heap.objects.collectionDue()) {
        const before = ev.heap.objects.stats.live_bytes;
        try collect(ev);
        if (verbose(ev)) {
            if (ev.out) |out| {
                try out.print(
                    ";; GC: {d} bytes live, {d} reclaimed\n",
                    .{ ev.heap.objects.stats.live_bytes, before - ev.heap.objects.stats.live_bytes },
                );
                ev.output_column = 0;
            }
        }
    }
    // A collection from inside an allocation harvests but cannot run
    // what it finds, so the queue is drained here whether one ran now
    // or not.
    try runFinalizers(ev);
}

fn specialValue(ev: *Evaluator, name: []const u8) ?Value {
    const found = ev.interner.cl.findPresent(name) orelse return null;
    return symbol_mod.symbol(found.sym).value_cell;
}

fn applyTrigger(ev: *Evaluator) void {
    if (byteSetting(ev, TRIGGER_VARIABLE)) |bytes| {
        ev.heap.objects.collect_threshold = bytes;
    }
    if (byteSetting(ev, MAJOR_FLOOR_VARIABLE)) |bytes| {
        ev.major_floor = bytes;
    }
}

fn byteSetting(ev: *Evaluator, name: []const u8) ?usize {
    const setting = specialValue(ev, name) orelse return null;
    if (!setting.isFixnum()) return null;
    const bytes = setting.toFixnum();
    if (bytes < 0) return null;
    return @intCast(bytes);
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
    // The weak pointer is pushed, not what it refers to: registering a
    // finalizer must not be what keeps the object alive.
    for (ev.finalizers.items) |entry| {
        try marker.push(entry.object);
        try marker.push(entry.action);
    }
    for (ev.pending.items) |v| try marker.push(v);
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
