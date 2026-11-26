//! The allocator a host with no Zig standard heap gives zisp: one
//! function that returns memory and one that takes it back. A
//! microcontroller's C heap or a pool over a static buffer fits it.
//! `allocator` turns it into the `std.mem.Allocator` that `Repl.init`
//! and `Heap.init` take.

const std = @import("std");

pub const HostAllocator = struct {
    context: ?*anyopaque,
    /// `len` bytes aligned to `alignment`, or null when there are none.
    alloc: *const fn (context: ?*anyopaque, len: usize, alignment: std.mem.Alignment) ?[*]u8,
    /// Memory `alloc` returned, with the length and alignment it was asked for.
    free: *const fn (context: ?*anyopaque, memory: []u8, alignment: std.mem.Alignment) void,

    pub fn allocator(self: *const HostAllocator) std.mem.Allocator {
        return .{ .ptr = @constCast(self), .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = freeFn,
    };

    fn allocFn(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *const HostAllocator = @ptrCast(@alignCast(ptr));
        return self.alloc(self.context, len, alignment);
    }

    fn freeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        const self: *const HostAllocator = @ptrCast(@alignCast(ptr));
        self.free(self.context, memory, alignment);
    }
};
