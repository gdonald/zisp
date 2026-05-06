const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

pub const Cons = extern struct {
    car: Value,
    cdr: Value,
};

comptime {
    std.debug.assert(@sizeOf(Cons) == 16);
    std.debug.assert(@alignOf(Cons) >= 8);
}

pub const HeapType = enum(u8) {
    string = 0,
    vector = 1,
    hash_table = 2,
    function = 3,
    bignum = 4,
    package = 5,
    pathname = 6,
    stream = 7,
    ratio = 8,
    complex = 9,
    single_float = 10,
    double_float = 11,
    weak_pointer = 12,
    closure = 13,
    _,
};

pub const HeapHeader = packed struct(u64) {
    type_tag: HeapType,
    mark: bool = false,
    forwarded: bool = false,
    pinned: bool = false,
    _reserved: u5 = 0,
    size: u48,
};

comptime {
    std.debug.assert(@sizeOf(HeapHeader) == 8);
}

pub const HeapObject = extern struct {
    header: HeapHeader,
};

/// All allocation flows through this. Phase 0 uses a bump arena from outside;
/// Phase 5 swaps the underlying allocator for a real GC heap.
pub const Heap = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    pub fn allocCons(self: *Heap, car_v: Value, cdr_v: Value) !Value {
        const cell = try self.allocator.create(Cons);
        cell.* = .{ .car = car_v, .cdr = cdr_v };
        return Value.fromConsAddr(@intFromPtr(cell));
    }
};

pub fn car(v: Value) Value {
    const cell: *const Cons = @ptrFromInt(v.toConsAddr());
    return cell.car;
}

pub fn cdr(v: Value) Value {
    const cell: *const Cons = @ptrFromInt(v.toConsAddr());
    return cell.cdr;
}

pub fn setCar(v: Value, new_car: Value) void {
    const cell: *Cons = @ptrFromInt(v.toConsAddr());
    cell.car = new_car;
}

pub fn setCdr(v: Value, new_cdr: Value) void {
    const cell: *Cons = @ptrFromInt(v.toConsAddr());
    cell.cdr = new_cdr;
}
