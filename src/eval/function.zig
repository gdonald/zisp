const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const source_pos = @import("../runtime/source_pos.zig");
const env_mod = @import("env.zig");
const bytecode = @import("../compiler/bytecode.zig");
const Value = value.Value;

pub const Kind = enum(u8) {
    native = 0,
    closure = 1,
    funcallable = 2,
    compiled = 3,
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
    ArithmeticError,
    FileError,
    NoOutputStream,
    Quit,
    NoSuchPackage,
    PackageError,
    StackExhausted,
    FaslVersion,
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

/// A function the compiler made. The values it closed over follow the
/// function object in the same block.
pub const Compiled = struct {
    code: *const bytecode.Code,
    env_len: u32,
};

/// An instance of a funcallable class, such as a generic function. It
/// carries a class and slots the way any instance does, and a call to it
/// is a call to `function`.
pub const Funcallable = struct {
    class: Value,
    slots: Value,
    wrapper: Value,
    function: Value,
};

pub const HeapFunction = struct {
    header: heap.HeapHeader,
    kind: Kind,
    name: ?[]const u8,
    // Natives are normally single-valued: the dispatcher collapses the
    // values channel to the returned value. Pass-through natives (funcall,
    // apply, eval, gethash) set this to keep the channel they produced.
    preserves_values: bool = false,
    // A call to it in tail position still keeps the calling frame, so a
    // backtrace and the debugger see where it was called from. Set on the
    // functions that signal conditions.
    keeps_caller: bool = false,
    payload: union {
        native: NativeFn,
        closure: Closure,
        funcallable: Funcallable,
        compiled: Compiled,
    },

    /// What a compiled function closed over.
    pub fn closedOver(self: *HeapFunction) []Value {
        std.debug.assert(self.kind == .compiled);
        const after: [*]u8 = @as([*]u8, @ptrCast(self)) + compiled_prefix;
        const values: [*]Value = @ptrCast(@alignCast(after));
        return values[0..self.payload.compiled.env_len];
    }
};

/// Where a compiled function's closed-over values start.
pub const compiled_prefix = std.mem.alignForward(usize, @sizeOf(HeapFunction), @alignOf(Value));

/// A compiled function in the collected heap, closing over `env`.
pub fn allocCompiled(h: *heap.Heap, code: *const bytecode.Code, env: []const Value) !Value {
    var held = h.protect();
    defer held.close();
    for (env) |v| try held.push(v);
    const total = compiled_prefix + env.len * @sizeOf(Value);
    const bytes = try h.allocObject(total);
    const obj: *HeapFunction = @ptrCast(bytes.ptr);
    obj.* = .{
        .header = .{ .type_tag = .function, .size = @intCast(total) },
        .kind = .compiled,
        .name = code.name,
        .payload = .{ .compiled = .{ .code = code, .env_len = @intCast(env.len) } },
    };
    @memcpy(obj.closedOver(), held.items());
    return Value.fromHeapAddr(@intFromPtr(obj));
}

/// Bumped whenever what a global function name refers to may have
/// changed. A call cache made in an older epoch is empty.
pub var call_cache_epoch: u32 = 1;

pub fn invalidateCallCaches() void {
    call_cache_epoch +%= 1;
    if (call_cache_epoch == 0) call_cache_epoch = 1;
}

/// Whether `v` is a `compiled-function`: anything callable but a closure
/// the interpreter runs.
pub fn isCompiledFunction(v: Value) bool {
    return isFunction(v) and asFunction(v).kind != .closure;
}

pub fn isCompiled(v: Value) bool {
    return isFunction(v) and asFunction(v).kind == .compiled;
}

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

pub fn allocFuncallable(
    allocator: std.mem.Allocator,
    class: Value,
    slots: Value,
    wrapper: Value,
) !Value {
    const obj = try allocator.create(HeapFunction);
    obj.* = .{
        .header = .{
            .type_tag = .function,
            .size = @sizeOf(HeapFunction),
        },
        .kind = .funcallable,
        .name = null,
        .payload = .{ .funcallable = .{
            .class = class,
            .slots = slots,
            .wrapper = wrapper,
            .function = value.NIL,
        } },
    };
    return Value.fromHeapAddr(@intFromPtr(obj));
}

pub fn isFuncallable(v: Value) bool {
    return isFunction(v) and asFunction(v).kind == .funcallable;
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
