const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const source_pos = @import("../runtime/source_pos.zig");
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
    Throw,
    ProgramError,
    DivisionByZero,
    FileError,
    NoOutputStream,
    Quit,
    NoSuchPackage,
    PackageError,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Closure = struct {
    params: Value,
    body: Value,
    captured_env: ?*env_mod.Frame,
    captured_fenv: ?*env_mod.Frame,
    // Macro expander closure. Called with the two-argument macro-function
    // protocol (form env), where the lambda list destructures the form's cdr.
    is_macro: bool = false,
    // Position of the defining form. Macroexpansion stamps synthesized
    // conses with it when a position table is bound.
    def_pos: ?source_pos.SourcePosition = null,
};

pub const HeapFunction = struct {
    header: heap.HeapHeader,
    kind: Kind,
    name: ?[]const u8,
    // Natives are normally single-valued: the dispatcher collapses the
    // values channel to the returned value. Pass-through natives (funcall,
    // apply, eval, gethash) set this to keep the channel they produced.
    preserves_values: bool = false,
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

pub fn allocMacro(
    allocator: std.mem.Allocator,
    name: ?[]const u8,
    params: Value,
    body: Value,
    captured_env: ?*env_mod.Frame,
    captured_fenv: ?*env_mod.Frame,
    def_pos: ?source_pos.SourcePosition,
) !Value {
    const v = try allocClosure(allocator, name, params, body, captured_env, captured_fenv);
    asFunction(v).payload.closure.is_macro = true;
    asFunction(v).payload.closure.def_pos = def_pos;
    return v;
}

pub fn isMacro(v: Value) bool {
    if (!isFunction(v)) return false;
    const f = asFunction(v);
    return f.kind == .closure and f.payload.closure.is_macro;
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
