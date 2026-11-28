//! Labeling for `*print-circle*`.
//!
//! An object reachable more than once from the form being printed gets a
//! `#n=` label at its first appearance and `#n#` afterwards, which is what
//! lets a circular or shared structure print and read back.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const symbol = @import("symbol.zig");

const Value = value.Value;

pub const Label = struct {
    /// Assigned on first print, so the numbers run in printing order.
    id: u32 = 0,
    printed: bool = false,
};

/// Which objects need labels, and the state of each while printing.
pub const State = struct {
    labels: std.AutoHashMapUnmanaged(u64, Label) = .empty,
    next_id: u32 = 1,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.labels.deinit(allocator);
    }

    /// The label for `v`, or null when it needs none.
    pub fn get(self: *State, v: Value) ?*Label {
        return self.labels.getPtr(addressOf(v) orelse return null);
    }

    pub fn assign(self: *State, label: *Label) u32 {
        if (label.id == 0) {
            label.id = self.next_id;
            self.next_id += 1;
        }
        return label.id;
    }
};

/// Objects with identity, which are the only ones a label can name. An
/// uninterned symbol is one: two `#:g` read back as two symbols.
fn addressOf(v: Value) ?u64 {
    if (v.isCons()) return v.toConsAddr();
    if (v.isSymbol()) return if (symbol.homePackage(v) == null) v.toSymbolAddr() else null;
    if (v.tag() != .heap) return null;
    return switch (heap.heapType(v)) {
        .vector, .structure => v.toHeapAddr(),
        else => null,
    };
}

/// How much of an object printing will show, which is all a label can
/// be needed for: `*print-length*` elements of each list or vector, and
/// `*print-level*` levels down.
pub const Limits = struct {
    length: ?usize = null,
    level: ?usize = null,
};

/// Walk `v`, recording every object reached more than once. The walk
/// stops descending into an object it has already seen, so a cycle
/// terminates.
pub fn scan(allocator: std.mem.Allocator, v: Value) !State {
    return scanLimited(allocator, v, .{});
}

/// `scan` over only the part of `v` that printing within `limits` shows.
pub fn scanLimited(allocator: std.mem.Allocator, v: Value, limits: Limits) std.mem.Allocator.Error!State {
    var state = State{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);
    var walk: Walk = .{ .allocator = allocator, .state = &state, .seen = &seen, .limits = limits };
    try walk.visit(v, 0);
    return state;
}

const Walk = struct {
    allocator: std.mem.Allocator,
    state: *State,
    seen: *std.AutoHashMapUnmanaged(u64, void),
    limits: Limits,

    /// Record `v`, and say whether it was new.
    fn record(self: *Walk, v: Value) std.mem.Allocator.Error!bool {
        const address = addressOf(v) orelse return false;
        if (self.seen.contains(address)) {
            try self.state.labels.put(self.allocator, address, .{});
            return false;
        }
        try self.seen.put(self.allocator, address, {});
        return true;
    }

    fn pastLevel(self: *const Walk, depth: usize) bool {
        const level = self.limits.level orelse return false;
        return depth >= level;
    }

    fn pastLength(self: *const Walk, index: usize) bool {
        const length = self.limits.length orelse return false;
        return index >= length;
    }

    fn visit(self: *Walk, v: Value, depth: usize) std.mem.Allocator.Error!void {
        if (addressOf(v) == null) return;
        if (v.isSymbol()) {
            _ = try self.record(v);
            return;
        }
        if (self.pastLevel(depth)) return;
        if (!try self.record(v)) return;
        if (v.isCons()) return self.visitList(v, depth);
        switch (heap.heapType(v)) {
            .vector => for (heap.arrayActive(v), 0..) |element, index| {
                if (self.pastLength(index)) break;
                try self.visit(element, depth + 1);
            },
            .structure => for (heap.asStructure(v).slice(), 0..) |slot, index| {
                if (self.pastLength(index)) break;
                try self.visit(slot, depth + 1);
            },
            else => {},
        }
    }

    /// A list's elements, as far as the length shows, and a tail that is
    /// not a list or is shared, which prints after a dot.
    fn visitList(self: *Walk, list: Value, depth: usize) std.mem.Allocator.Error!void {
        var cell = list;
        var index: usize = 0;
        while (true) {
            if (self.pastLength(index)) return;
            try self.visit(heap.car(cell), depth + 1);
            index += 1;
            const tail = heap.cdr(cell);
            if (!tail.isCons()) return self.visit(tail, depth + 1);
            if (self.pastLength(index)) return;
            if (!try self.record(tail)) return;
            cell = tail;
        }
    }
};
