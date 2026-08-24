//! Copying the nursery.
//!
//! Everything is allocated in the nursery, so a collection starts by
//! copying what is still reachable from there into the tenured space and
//! leaving a forwarding pointer behind. Once that is done the nursery
//! holds nothing anyone can reach and its bump pointer goes back to zero.
//!
//! Every reference has to be rewritten, which is why this walks slots
//! (`*Value`) rather than values: a root, a slot inside a copied object,
//! or a binding in an environment frame.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const symbol_mod = @import("symbol.zig");
const gc = @import("gc.zig");
const equality = @import("equality.zig");
const function = @import("../eval/function.zig");
const env_mod = @import("../eval/env.zig");

const Value = value.Value;
const Heap = heap.Heap;

/// What a copy can fail with: running out of room for the tenured copy
/// or for the evacuator's own bookkeeping.
pub const Error = std.mem.Allocator.Error;

pub const Evacuator = struct {
    allocator: std.mem.Allocator,
    heap: *Heap,
    /// Objects already copied, waiting to have their own slots updated.
    worklist: std.ArrayListUnmanaged(Value) = .empty,
    frames: std.ArrayListUnmanaged(*env_mod.Frame) = .empty,
    visited_frames: std.AutoHashMapUnmanaged(usize, void) = .empty,
    visited_symbols: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Hash tables whose keys the copy moved, so their buckets no longer
    /// match the addresses they were built from.
    rehash: std.ArrayListUnmanaged(Value) = .empty,
    /// Conses that moved, as old-address to new value. The source
    /// position table is keyed on the old addresses.
    moved_conses: std.AutoHashMapUnmanaged(usize, Value) = .empty,
    /// Objects that stayed put and have already been queued. A copied
    /// object needs no entry: its forwarding pointer says it was seen.
    visited: std.AutoHashMapUnmanaged(usize, void) = .empty,
    copied: usize = 0,

    pub fn init(allocator: std.mem.Allocator, h: *Heap) Evacuator {
        return .{ .allocator = allocator, .heap = h };
    }

    pub fn deinit(self: *Evacuator) void {
        self.worklist.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.visited_frames.deinit(self.allocator);
        self.visited_symbols.deinit(self.allocator);
        self.rehash.deinit(self.allocator);
        self.moved_conses.deinit(self.allocator);
        self.visited.deinit(self.allocator);
    }

    /// Rewrite one slot, copying what it points at when that is still in
    /// the nursery.
    ///
    /// An object that is already tenured is followed rather than copied:
    /// its own slots may still point into the nursery. That makes an
    /// evacuation a full traversal for now. The card table records which
    /// tenured objects hold a young pointer, and once it does the walk
    /// can start from the roots and those cards alone.
    pub fn update(self: *Evacuator, slot: *Value) Error!void {
        const v = slot.*;
        if (v.isSymbol()) return self.visitSymbol(v);
        const address = if (v.isCons())
            v.toConsAddr()
        else if (v.tag() == .heap)
            v.toHeapAddr()
        else
            return;

        if (self.heap.objects.inNursery(address)) {
            slot.* = if (v.isCons())
                try self.copyCons(address)
            else
                try self.copyObject(address);
            return;
        }
        if (try self.wasVisited(address)) return;
        try self.worklist.append(self.allocator, v);
    }

    fn wasVisited(self: *Evacuator, address: usize) Error!bool {
        const slot = try self.visited.getOrPut(self.allocator, address);
        return slot.found_existing;
    }

    fn copyCons(self: *Evacuator, address: usize) Error!Value {
        const cell: *heap.Cons = @ptrFromInt(address);
        if (cell.car.equalsRaw(value.FORWARDED)) return cell.cdr;

        const bytes = try self.heap.objects.allocTenuredCons();
        const fresh: *heap.Cons = @ptrCast(@alignCast(bytes.ptr));
        fresh.* = .{ .car = cell.car, .cdr = cell.cdr };
        const moved = Value.fromConsAddr(@intFromPtr(fresh));

        cell.car = value.FORWARDED;
        cell.cdr = moved;
        self.copied += 1;
        try self.moved_conses.put(self.allocator, address, moved);
        try self.worklist.append(self.allocator, moved);
        return moved;
    }

    fn copyObject(self: *Evacuator, address: usize) Error!Value {
        const header: *heap.HeapHeader = @ptrFromInt(address);
        if (header.forwarded) {
            const words: [*]const Value = @ptrFromInt(address);
            return words[1];
        }

        const size: usize = @intCast(header.size);
        const bytes = try self.heap.objects.allocTenured(size);
        @memcpy(bytes[0..size], @as([*]const u8, @ptrFromInt(address))[0..size]);
        const moved = Value.fromHeapAddr(@intFromPtr(bytes.ptr));

        header.forwarded = true;
        const words: [*]Value = @ptrFromInt(address);
        words[1] = moved;
        self.copied += 1;
        try self.worklist.append(self.allocator, moved);
        return moved;
    }

    pub fn pushFrame(self: *Evacuator, frame: ?*env_mod.Frame) Error!void {
        const f = frame orelse return;
        try self.frames.append(self.allocator, f);
    }

    /// Copy everything reachable from what has been handed in so far.
    pub fn drain(self: *Evacuator) !void {
        while (self.worklist.items.len > 0 or self.frames.items.len > 0) {
            while (self.worklist.pop()) |v| try self.scan(v);
            while (self.frames.pop()) |frame| try self.scanFrame(frame);
        }
    }

    fn scanFrame(self: *Evacuator, frame: *env_mod.Frame) Error!void {
        const slot = try self.visited_frames.getOrPut(self.allocator, @intFromPtr(frame));
        if (slot.found_existing) return;
        for (frame.values.items) |*v| try self.update(v);
        if (frame.map) |*map| {
            var it = map.valueIterator();
            while (it.next()) |v| try self.update(v);
        }
        try self.pushFrame(frame.parent);
    }

    fn visitSymbol(self: *Evacuator, v: Value) Error!void {
        const slot = try self.visited_symbols.getOrPut(self.allocator, v.raw);
        if (slot.found_existing) return;
        const sym = symbol_mod.symbol(v);
        try self.update(&sym.value_cell);
        try self.update(&sym.function_cell);
        try self.update(&sym.plist);
    }

    /// Update the slots of one already-copied object.
    fn scan(self: *Evacuator, v: Value) Error!void {
        if (v.isCons()) {
            const cell: *heap.Cons = @ptrFromInt(v.toConsAddr());
            try self.update(&cell.car);
            try self.update(&cell.cdr);
            return;
        }
        switch (heap.heapType(v)) {
            // Nothing inside these points at another object.
            .bignum, .single_float, .double_float, .random_state, .package, .readtable => {},
            .string => {
                const text = heap.asString(v);
                if (text.isDisplaced()) {
                    const before = text.displaced_to;
                    try self.update(&text.displaced_to);
                    // The characters are the target's, so the borrowed
                    // pointer follows it.
                    if (!before.equalsRaw(text.displaced_to)) {
                        const source = heap.asString(text.displaced_to);
                        const offset = text.codes - heap.asString(before).codes;
                        text.codes = source.codes + offset;
                    }
                }
            },
            .ratio => {
                const r = heap.asRatio(v);
                try self.update(&r.numerator);
                try self.update(&r.denominator);
            },
            .complex => {
                const z = heap.asComplex(v);
                try self.update(&z.realpart);
                try self.update(&z.imagpart);
            },
            .pathname => {
                const p = heap.asPathname(v);
                for ([_]*Value{ &p.host, &p.device, &p.directory, &p.name, &p.type_, &p.version }) |slot| {
                    try self.update(slot);
                }
            },
            .vector => {
                const a = heap.asArray(v);
                try self.update(&a.displaced_to);
                if (a.displaced_to.equalsRaw(value.NIL)) {
                    for (a.storage[0..a.storage_len]) |*element| try self.update(element);
                }
            },
            .structure => {
                const s = heap.asStructure(v);
                try self.update(&s.name);
                for (s.slice()) |*element| try self.update(element);
            },
            .hash_table => try self.scanHashTable(v),
            .stream => {
                const s = heap.asStream(v);
                try self.update(&s.path);
                try self.update(&s.target);
                try self.update(&s.delete_on_close);
            },
            .function, .closure => {
                const f = function.asFunction(v);
                if (f.kind != .closure) return;
                try self.update(&f.payload.closure.params);
                try self.update(&f.payload.closure.body);
                try self.pushFrame(f.payload.closure.captured_env);
                try self.pushFrame(f.payload.closure.captured_fenv);
            },
            else => {},
        }
    }

    /// A table's buckets are built from its keys' hashes, and for an
    /// `eq` or `eql` table that hash is the key's address, so a key the
    /// copy moved needs its bucket rebuilt.
    fn scanHashTable(self: *Evacuator, v: Value) Error!void {
        const table = heap.asHashTable(v);
        var moved = false;
        for (table.entries.items) |*entry| {
            const before = entry.key;
            try self.update(&entry.key);
            try self.update(&entry.value);
            if (!before.equalsRaw(entry.key)) moved = true;
        }
        if (moved) try self.rehash.append(self.allocator, v);
    }

    /// Rebuild the buckets of every table whose keys moved.
    pub fn rebuildTables(self: *Evacuator) !void {
        for (self.rehash.items) |v| {
            const table = heap.asHashTable(v);
            var buckets = table.buckets.valueIterator();
            while (buckets.next()) |bucket| bucket.deinit(self.heap.allocator);
            table.buckets.clearRetainingCapacity();
            for (table.entries.items, 0..) |entry, index| {
                if (!entry.live) continue;
                const slot = try table.buckets.getOrPut(
                    self.heap.allocator,
                    equality.hash(table.hash_test, entry.key),
                );
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(self.heap.allocator, @intCast(index));
            }
        }
    }

    /// Where a cons that moved ended up, for anything keyed on its old
    /// address.
    pub fn movedCons(self: *const Evacuator, address: usize) ?Value {
        return self.moved_conses.get(address);
    }
};
