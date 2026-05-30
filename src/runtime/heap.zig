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

/// String: header + length-prefixed UTF-8 byte slice. The codepoint count
/// (CL `length`) waits until strings can be indexed; for now the reader
/// only needs to round-trip the bytes.
pub const HeapString = extern struct {
    header: HeapHeader,
    len: u64,
    // bytes follow inline starting at `data()`
    pub fn data(self: *HeapString) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + @sizeOf(HeapString);
    }
    pub fn slice(self: *HeapString) []u8 {
        return self.data()[0..self.len];
    }
    pub fn constSlice(self: *const HeapString) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return (base + @sizeOf(HeapString))[0..self.len];
    }
};

/// Single-precision float box. The fixed `_pad` keeps `value` 8-byte
/// aligned so the GC can scan headers uniformly.
pub const HeapSingleFloat = extern struct {
    header: HeapHeader,
    value: f32,
    _pad: u32 = 0,
};

pub const HeapDoubleFloat = extern struct {
    header: HeapHeader,
    value: f64,
};

/// Exact ratio of two fixnums — for now this only stores the lexeme's
/// literal numerator/denominator. Arithmetic will normalize and promote
/// to bignum when needed.
pub const HeapRatio = extern struct {
    header: HeapHeader,
    numerator: i64,
    denominator: i64,
};

/// Stub vector — flat `Value` array. Specialized element types
/// (`(simple-array (unsigned-byte 8) ...)`, etc.) come later; the reader only needs the
/// general T-vector path for `#(...)` literals.
pub const HeapVector = extern struct {
    header: HeapHeader,
    len: u64,
    pub fn data(self: *HeapVector) [*]Value {
        const base: [*]u8 = @ptrCast(self);
        const offset = @sizeOf(HeapVector);
        return @ptrCast(@alignCast(base + offset));
    }
    pub fn slice(self: *HeapVector) []Value {
        return self.data()[0..self.len];
    }
    pub fn constSlice(self: *const HeapVector) []const Value {
        const base: [*]const u8 = @ptrCast(self);
        const offset = @sizeOf(HeapVector);
        const ptr: [*]const Value = @ptrCast(@alignCast(base + offset));
        return ptr[0..self.len];
    }
};

/// All allocation flows through this. For now a bump arena is supplied from
/// outside; a real GC heap will replace the underlying allocator later.
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

    pub fn allocString(self: *Heap, bytes: []const u8) !Value {
        const total = @sizeOf(HeapString) + bytes.len;
        const buf = try self.allocator.alignedAlloc(u8, .of(HeapString), total);
        const obj: *HeapString = @ptrCast(buf.ptr);
        obj.* = .{
            .header = .{ .type_tag = .string, .size = @intCast(total) },
            .len = bytes.len,
        };
        if (bytes.len != 0) @memcpy(obj.data()[0..bytes.len], bytes);
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocSingleFloat(self: *Heap, x: f32) !Value {
        const obj = try self.allocator.create(HeapSingleFloat);
        obj.* = .{
            .header = .{ .type_tag = .single_float, .size = @sizeOf(HeapSingleFloat) },
            .value = x,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocDoubleFloat(self: *Heap, x: f64) !Value {
        const obj = try self.allocator.create(HeapDoubleFloat);
        obj.* = .{
            .header = .{ .type_tag = .double_float, .size = @sizeOf(HeapDoubleFloat) },
            .value = x,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocRatio(self: *Heap, num: i64, den: i64) !Value {
        std.debug.assert(den != 0);
        const obj = try self.allocator.create(HeapRatio);
        obj.* = .{
            .header = .{ .type_tag = .ratio, .size = @sizeOf(HeapRatio) },
            .numerator = num,
            .denominator = den,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocVector(self: *Heap, elements: []const Value) !Value {
        const total = @sizeOf(HeapVector) + elements.len * @sizeOf(Value);
        const buf = try self.allocator.alignedAlloc(u8, .of(HeapVector), total);
        const obj: *HeapVector = @ptrCast(buf.ptr);
        obj.* = .{
            .header = .{ .type_tag = .vector, .size = @intCast(total) },
            .len = elements.len,
        };
        if (elements.len != 0) @memcpy(obj.slice(), elements);
        return Value.fromHeapAddr(@intFromPtr(obj));
    }
};

/// Inspect the type tag of a heap-allocated value.
pub fn heapType(v: Value) HeapType {
    const obj: *const HeapObject = @ptrFromInt(v.toHeapAddr());
    return obj.header.type_tag;
}

pub fn asString(v: Value) *HeapString {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asSingleFloat(v: Value) *HeapSingleFloat {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asDoubleFloat(v: Value) *HeapDoubleFloat {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asRatio(v: Value) *HeapRatio {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asVector(v: Value) *HeapVector {
    return @ptrFromInt(v.toHeapAddr());
}

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
