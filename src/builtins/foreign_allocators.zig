//! The natives under the Lisp allocators in `src/lisp/ffi.lisp`. Each
//! Lisp allocator is a `Record` named by its address. The C heap's record
//! hands out `malloc` memory, and an arena's takes its chunks from its
//! parent's allocator, so the parent counts them until the arena is
//! released.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const bignum = @import("../runtime/bignum.zig");
const function = @import("../eval/function.zig");
const eval_mod = @import("../eval/eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

const Record = struct {
    arena: ?std.heap.ArenaAllocator,
    live_bytes: usize = 0,

    fn backing(self: *Record) std.mem.Allocator {
        return if (self.arena) |*arena| arena.allocator() else std.heap.c_allocator;
    }

    /// `backing`, counting the bytes it has handed out and not had back.
    fn allocator(self: *Record) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &counting_vtable };
    }

    const counting_vtable: std.mem.Allocator.VTable = .{
        .alloc = countingAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = countingFree,
    };

    fn countingAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Record = @ptrCast(@alignCast(ptr));
        const memory = self.backing().rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        return memory;
    }

    fn countingFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Record = @ptrCast(@alignCast(ptr));
        self.backing().rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
    }
};

var c_heap: Record = .{ .arena = null };

pub fn register(ev: *Evaluator) !void {
    _ = try ev.defineNative("%C-ALLOCATOR", &cAllocatorFn);
    _ = try ev.defineNative("%MAKE-ARENA", &makeArenaFn);
    _ = try ev.defineNative("%RELEASE-ARENA", &releaseArenaFn);
    _ = try ev.defineNative("%ALLOCATOR-ALLOC", &allocatorAllocFn);
    _ = try ev.defineNative("%ALLOCATOR-FREE", &allocatorFreeFn);
    _ = try ev.defineNative("%ALLOCATOR-LIVE-BYTES", &allocatorLiveBytesFn);
}

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

fn unsignedOf(v: Value) Error!usize {
    if (v.isFixnum()) {
        const n = v.toFixnum();
        if (n < 0) return Error.TypeError;
        return @intCast(n);
    }
    if (!heap.isBignum(v)) return Error.TypeError;
    var scratch: bignum.Scratch = .{};
    return scratch.view(v).toInt(usize) catch Error.TypeError;
}

fn recordOf(v: Value) Error!*Record {
    return @ptrFromInt(try unsignedOf(v));
}

fn alignmentOf(v: Value) Error!std.mem.Alignment {
    const bytes = try unsignedOf(v);
    if (!std.math.isPowerOfTwo(bytes)) return Error.TypeError;
    return .fromByteUnits(bytes);
}

fn addressValue(ev: *Evaluator, address: usize) Error!Value {
    return bignum.fromI128(ev.heap, address);
}

/// `(%c-allocator)`: the C heap's record.
fn cAllocatorFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 0) return Error.WrongArgCount;
    return addressValue(evaluator(p), @intFromPtr(&c_heap));
}

/// `(%make-arena parent)`: a new arena over the parent record, or NIL when
/// there is no memory for it.
fn makeArenaFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 1) return Error.WrongArgCount;
    const parent = try recordOf(args[0]);
    const record = parent.allocator().create(Record) catch return value.NIL;
    record.* = .{ .arena = .init(parent.allocator()) };
    return addressValue(evaluator(p), @intFromPtr(record));
}

/// `(%release-arena arena parent)`: free everything the arena handed out,
/// and the arena itself, back to the parent.
fn releaseArenaFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const record = try recordOf(args[0]);
    const parent = try recordOf(args[1]);
    record.arena.?.deinit();
    parent.allocator().destroy(record);
    return value.T;
}

/// `(%allocator-alloc record size alignment)`: the address of `size`
/// bytes, or NIL when the allocator has none.
fn allocatorAllocFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 3) return Error.WrongArgCount;
    const record = try recordOf(args[0]);
    const size = try unsignedOf(args[1]);
    const alignment = try alignmentOf(args[2]);
    const memory = record.allocator().rawAlloc(@max(size, 1), alignment, @returnAddress()) orelse return value.NIL;
    return addressValue(evaluator(p), @intFromPtr(memory));
}

/// `(%allocator-free record address size alignment)`.
fn allocatorFreeFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 4) return Error.WrongArgCount;
    const record = try recordOf(args[0]);
    const address = try unsignedOf(args[1]);
    if (address == 0) return Error.TypeError;
    const size = try unsignedOf(args[2]);
    const alignment = try alignmentOf(args[3]);
    const memory: [*]u8 = @ptrFromInt(address);
    record.allocator().rawFree(memory[0..@max(size, 1)], alignment, @returnAddress());
    return value.NIL;
}

/// `(%allocator-live-bytes record)`.
fn allocatorLiveBytesFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 1) return Error.WrongArgCount;
    return addressValue(evaluator(p), (try recordOf(args[0])).live_bytes);
}
