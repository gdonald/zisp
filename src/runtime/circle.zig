//! Labeling for `*print-circle*`.
//!
//! An object reachable more than once from the form being printed gets a
//! `#n=` label at its first appearance and `#n#` afterwards, which is what
//! lets a circular or shared structure print and read back.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");

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

/// Objects with identity, which are the only ones a label can name.
fn addressOf(v: Value) ?u64 {
    if (v.isCons()) return v.toConsAddr();
    if (v.tag() != .heap) return null;
    return switch (heap.heapType(v)) {
        .vector, .structure => v.toHeapAddr(),
        else => null,
    };
}

/// Walk `v`, recording every object reached more than once. The walk
/// stops descending into an object it has already seen, so a cycle
/// terminates.
pub fn scan(allocator: std.mem.Allocator, v: Value) !State {
    var state = State{};
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);
    try visit(allocator, v, &state, &seen);
    return state;
}

fn visit(
    allocator: std.mem.Allocator,
    v: Value,
    state: *State,
    seen: *std.AutoHashMapUnmanaged(u64, void),
) !void {
    const address = addressOf(v) orelse return;
    if (seen.contains(address)) {
        try state.labels.put(allocator, address, .{});
        return;
    }
    try seen.put(allocator, address, {});

    if (v.isCons()) {
        try visit(allocator, heap.car(v), state, seen);
        try visit(allocator, heap.cdr(v), state, seen);
        return;
    }
    switch (heap.heapType(v)) {
        .vector => for (heap.arrayActive(v)) |element| {
            try visit(allocator, element, state, seen);
        },
        .structure => for (heap.asStructure(v).slice()) |slot| {
            try visit(allocator, slot, state, seen);
        },
        else => {},
    }
}
