const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const env_mod = @import("env.zig");
const Value = value.Value;

pub const Kind = enum(u8) {
    native = 0,
    closure = 1,
};

pub const NativeFn = *const fn (
    ev_opaque: *anyopaque,
    args: []const Value,
) NativeError!Value;

pub const NativeError = error{
    UnboundVariable,
    UnboundFunction,
    NotCallable,
    BadArgList,
    NoSpecialFormHandler,
    WrongArgCount,
    TypeError,
    ControlError,
    BlockReturn,
    Go,
} || std.mem.Allocator.Error;

pub const Closure = struct {
    params: Value,
    body: Value,
    captured_env: ?*env_mod.Frame,
    captured_fenv: ?*env_mod.Frame,
};

pub const HeapFunction = struct {
    header: heap.HeapHeader,
    kind: Kind,
    name: ?[]const u8,
    payload: union {
        native: NativeFn,
        closure: Closure,
    },
};

pub fn allocNative(
    allocator: std.mem.Allocator,
    name: ?[]const u8,
    native: NativeFn,
) !Value {
    const obj = try allocator.create(HeapFunction);
    obj.* = .{
        .header = .{
            .type_tag = .function,
            .size = @sizeOf(HeapFunction),
        },
        .kind = .native,
        .name = name,
        .payload = .{ .native = native },
    };
    return Value.fromHeapAddr(@intFromPtr(obj));
}

pub fn allocClosure(
    allocator: std.mem.Allocator,
    name: ?[]const u8,
    params: Value,
    body: Value,
    captured_env: ?*env_mod.Frame,
    captured_fenv: ?*env_mod.Frame,
) !Value {
    const obj = try allocator.create(HeapFunction);
    obj.* = .{
        .header = .{
            .type_tag = .function,
            .size = @sizeOf(HeapFunction),
        },
        .kind = .closure,
        .name = name,
        .payload = .{ .closure = .{
            .params = params,
            .body = body,
            .captured_env = captured_env,
            .captured_fenv = captured_fenv,
        } },
    };
    return Value.fromHeapAddr(@intFromPtr(obj));
}

pub fn asFunction(v: Value) *HeapFunction {
    std.debug.assert(v.tag() == .heap);
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isFunction(v: Value) bool {
    if (v.tag() != .heap) return false;
    const obj: *const heap.HeapObject = @ptrFromInt(v.toHeapAddr());
    return obj.header.type_tag == .function;
}
