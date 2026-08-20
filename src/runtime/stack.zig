//! The Lisp value stack.
//!
//! Call arguments and any value a native holds across an allocation live
//! here rather than only in Zig locals, so a collection can see them.
//!
//! The stack is a chain of chunks rather than one array that grows in
//! place: a slice handed to a native has to stay valid while the call it
//! belongs to runs, and reallocating one array would move it.

const std = @import("std");
const value = @import("value.zig");
const gc = @import("gc.zig");
const Value = value.Value;

/// Abort when a value being held has already been reclaimed, which
/// points at whoever produced it without rooting it.
fn checkLive(v: Value) void {
    if (!gc.checked) return;
    const address = if (v.isCons())
        v.toConsAddr()
    else if (v.tag() == .heap)
        v.toHeapAddr()
    else
        return;
    if (gc.isPoisoned(address)) {
        std.debug.panic("holding a reclaimed object at 0x{x}", .{address});
    }
}

/// Slots in a chunk. One chunk holds the arguments of many calls.
pub const CHUNK_SLOTS: usize = 4096;

/// A point to unwind back to.
pub const Mark = struct { chunk: usize, top: usize };

pub const Stack = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged([]Value) = .empty,
    /// How much of each chunk below `chunk` is in use.
    heights: std.ArrayListUnmanaged(usize) = .empty,
    /// The chunk being filled, and how far into it.
    chunk: usize = 0,
    top: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stack) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        self.heights.deinit(self.allocator);
    }

    pub fn mark(self: *const Stack) Mark {
        return .{ .chunk = self.chunk, .top = self.top };
    }

    pub fn release(self: *Stack, to: Mark) void {
        self.chunk = to.chunk;
        self.top = to.top;
    }

    /// Everything in use, chunk by chunk. This is what a root scan walks.
    pub fn live(self: *const Stack, index: usize) []const Value {
        if (index >= self.chunks.items.len) return &.{};
        if (index > self.chunk) return &.{};
        const used = if (index == self.chunk) self.top else self.heights.items[index];
        return self.chunks.items[index][0..used];
    }

    pub fn chunkCount(self: *const Stack) usize {
        return self.chunks.items.len;
    }

    fn addChunk(self: *Stack, slots: usize) !void {
        const chunk = try self.allocator.alloc(Value, slots);
        @memset(chunk, value.NIL);
        try self.chunks.append(self.allocator, chunk);
        try self.heights.append(self.allocator, 0);
    }

    /// Start a run of values at the top of the stack.
    pub fn open(self: *Stack) Region {
        return .{
            .stack = self,
            .chunk = self.chunk,
            .start = self.top,
            .origin_chunk = self.chunk,
            .origin_top = self.top,
        };
    }
};

/// A contiguous run of values being built at the top of the stack. The
/// run stays contiguous across chunk boundaries: filling a chunk moves
/// what has been pushed so far into a fresh one.
pub const Region = struct {
    stack: *Stack,
    chunk: usize,
    start: usize,
    /// Where the run began, before any move into a fresh chunk. Giving
    /// the slots back returns the stack here rather than to wherever the
    /// run ended up, so a run opened afterwards starts where this one did.
    origin_chunk: usize,
    origin_top: usize,
    len: usize = 0,

    pub fn push(self: *Region, v: Value) !void {
        checkLive(v);
        const stack = self.stack;
        // Only the topmost run may grow. Filling a run below another one
        // would write over the run above it.
        std.debug.assert(stack.chunk == self.chunk and stack.top == self.start + self.len);
        if (stack.chunks.items.len == 0) try stack.addChunk(CHUNK_SLOTS);
        if (self.start + self.len == stack.chunks.items[self.chunk].len) try self.migrate();
        stack.chunks.items[self.chunk][self.start + self.len] = v;
        self.len += 1;
        stack.top = self.start + self.len;
    }

    /// Move the run into a chunk with room for it and more.
    fn migrate(self: *Region) !void {
        const stack = self.stack;
        const wanted = @max(CHUNK_SLOTS, self.len * 2);
        const next = self.chunk + 1;
        if (next == stack.chunks.items.len or stack.chunks.items[next].len < wanted) {
            try stack.addChunk(wanted);
            // A chunk the run cannot use is left where it is; the new one
            // goes on the end and the run moves there.
            const landed = stack.chunks.items.len - 1;
            @memcpy(
                stack.chunks.items[landed][0..self.len],
                stack.chunks.items[self.chunk][self.start..][0..self.len],
            );
            stack.heights.items[self.chunk] = self.start;
            self.chunk = landed;
        } else {
            @memcpy(
                stack.chunks.items[next][0..self.len],
                stack.chunks.items[self.chunk][self.start..][0..self.len],
            );
            stack.heights.items[self.chunk] = self.start;
            self.chunk = next;
        }
        self.start = 0;
        stack.chunk = self.chunk;
        stack.top = self.len;
    }

    /// Replace a slot already pushed. A holder whose value changes as it
    /// builds keeps the run in step this way rather than by holding a
    /// pointer, which a move into a fresh chunk would invalidate.
    pub fn setItem(self: *Region, index: usize, v: Value) void {
        checkLive(v);
        self.stack.chunks.items[self.chunk][self.start + index] = v;
    }

    /// Drop the last value pushed and hand it back.
    pub fn pop(self: *Region) ?Value {
        if (self.len == 0) return null;
        const v = self.items()[self.len - 1];
        self.len -= 1;
        self.stack.top = self.start + self.len;
        return v;
    }

    pub fn items(self: *const Region) []Value {
        if (self.len == 0) return &.{};
        return self.stack.chunks.items[self.chunk][self.start..][0..self.len];
    }

    pub fn clear(self: *Region) void {
        self.len = 0;
        self.chunk = self.origin_chunk;
        self.start = self.origin_top;
        self.stack.chunk = self.chunk;
        self.stack.top = self.start;
    }

    /// Give the run's slots back.
    pub fn close(self: *Region) void {
        self.stack.chunk = self.origin_chunk;
        self.stack.top = self.origin_top;
    }
};
