//! The instruction set the compiler emits and the VM runs.

const std = @import("std");
const value = @import("../runtime/value.zig");

const Value = value.Value;

/// An instruction is one 32-bit word: the opcode in the low 8 bits and
/// operand A in the upper 24. An instruction with more operands takes
/// the words after it, one operand each.
pub const Op = enum(u8) {
    load_const,
    load_nil,
    load_t,
    load_fixnum,
    pop,
    drop,
    slide,
    dup,

    load_local,
    store_local,
    load_closed,
    make_cell,
    load_cell,
    store_cell,
    load_closed_cell,
    store_closed_cell,

    load_global,
    store_global,
    bind_special,
    unbind,
    save_dynamic,
    restore_dynamic,
    save_state,
    progv_bind,
    proclaim,
    jump_if_bound,

    load_function,
    store_function,
    make_closure,
    call,
    call_global,
    apply,
    call_counted,

    @"return",
    return_mv,
    to_mv,
    mv_primary,
    values,
    values_list,
    mv_list,
    mv_push,
    mv_spread,
    save_mv,
    restore_mv,

    jump,
    jump_if_nil,
    jump_if_true,

    enter_block,
    enter_tagbody,
    enter_catch,
    enter_cleanup,
    enter_errors,
    leave,
    unwind,
    return_from,
    go,
    throw,
    end_cleanup,
    errors_ok,

    optional_arg,
    rest_arg,
    key_arg,
    check_keys,
    pop_list,
    jump_if_atom,
    check_end,
    list_key,
    check_list_keys,

    add,
    sub,
    less,
    greater,
    less_equal,
    greater_equal,
    num_equal,
    inc,
    dec,
    eq,
    cons,
    car,
    cdr,
    not,

    interpret,

    /// How many operand words follow the instruction word.
    pub fn extraWords(op: Op) usize {
        return switch (op) {
            .enter_block, .enter_tagbody, .enter_errors, .key_arg, .check_list_keys, .call_global => 2,
            .make_closure, .call, .enter_catch, .enter_cleanup, .unwind => 1,
            .optional_arg, .check_keys, .jump_if_atom, .proclaim, .jump_if_bound => 1,
            .list_key => 3,
            else => 0,
        };
    }
};

/// What a call does with what the callee returns.
pub const Mode = enum(u2) {
    /// Push the primary value.
    single = 0,
    /// Leave every value in the values register.
    multiple = 1,
    /// Return from the calling function with whatever the callee returns.
    tail = 2,
};

pub const ARG_BITS = 20;
pub const MAX_OPERAND: u32 = (1 << 24) - 1;
/// An `unwind` that has no dynamic bindings to undo.
pub const NO_SLOT: u32 = MAX_OPERAND;

pub fn encode(op: Op, a: u32) u32 {
    std.debug.assert(a <= MAX_OPERAND);
    return @as(u32, @backingInt(op)) | (a << 8);
}

pub fn opOf(word: u32) Op {
    return @fromBackingInt(@intCast(@as(u8, @truncate(word))));
}

pub fn operandOf(word: u32) u32 {
    return word >> 8;
}

/// A call's argument count and mode, packed into one operand.
pub fn callOperand(argc: u32, mode: Mode) u32 {
    std.debug.assert(argc < (1 << ARG_BITS));
    return argc | (@as(u32, @backingInt(mode)) << ARG_BITS);
}

pub fn callArgc(operand: u32) u32 {
    return operand & ((1 << ARG_BITS) - 1);
}

pub fn callMode(operand: u32) Mode {
    return @fromBackingInt(@intCast(@as(u2, @truncate(operand >> ARG_BITS))));
}

/// `load_fixnum` holds its immediate in operand A as a signed 24-bit
/// number.
pub const FIXNUM_IMMEDIATE_MIN: i64 = -(1 << 23);
pub const FIXNUM_IMMEDIATE_MAX: i64 = (1 << 23) - 1;

pub fn fixnumOperand(n: i64) u32 {
    const narrow: i24 = @intCast(n);
    return @as(u24, @bitCast(narrow));
}

pub fn fixnumFromOperand(a: u32) i64 {
    const narrow: i24 = @bitCast(@as(u24, @truncate(a)));
    return narrow;
}

/// What an `enter_errors` handler hands back on a failure.
pub const ErrorsKind = enum(u32) {
    /// `(values nil condition)`, as `ignore-errors` wants.
    ignore = 0,
    /// The condition alone, as `handler-case` wants.
    catch_error = 1,
};

/// What one call site has seen it call. A site starts empty, calls one
/// function while monomorphic, up to `POLYMORPHIC_TARGETS` while
/// polymorphic, and past that is megamorphic and looks its callee up in
/// one table the whole machine shares.
pub const CallCache = struct {
    /// The epoch the entries were made in. Redefining a function starts
    /// a new one, which empties every cache.
    epoch: u32 = 0,
    state: CacheState = .empty,
    count: u8 = 0,
    targets: [POLYMORPHIC_TARGETS]Value = undefined,
    counters: CacheCounters = .{},

    /// The functions it holds, which are roots for as long as it does.
    pub fn live(self: *CallCache, epoch: u32) []Value {
        if (self.epoch != epoch) return &.{};
        return self.targets[0..self.count];
    }
};

/// How a call site's cache, or all of them, have fared.
pub const CacheCounters = struct {
    monomorphic: u64 = 0,
    polymorphic: u64 = 0,
    megamorphic: u64 = 0,
    misses: u64 = 0,
    to_polymorphic: u64 = 0,
    to_megamorphic: u64 = 0,
};

pub const CacheState = enum(u8) { empty, monomorphic, polymorphic, megamorphic };

pub const POLYMORPHIC_TARGETS = 4;

/// One compiled function body: the instructions, the constants they
/// refer to, and what a call to it binds.
pub const Code = struct {
    words: []const u32,
    constants: []Value,
    /// Instruction offsets a dynamic `go` lands on, one table per
    /// `tagbody` that is the target of one.
    jump_tables: []const []const u32,
    name: ?[]const u8,
    required: u32,
    optional: u32,
    /// Whether the lambda list has `&rest` or `&key`, so arguments past
    /// the positional ones are accepted.
    takes_extra: bool,
    /// Slots past the positional parameters.
    locals: u32,
    /// The most values the body keeps on the operand stack at once.
    max_stack: u32,
    /// The symbol each slot was bound for, or 0 for a slot the compiler
    /// made for itself.
    slot_names: []const Value,
    /// One cache for each `call` and `call_global`, numbered by the
    /// instruction's last operand.
    caches: []CallCache,

    pub fn positional(self: *const Code) u32 {
        return self.required + self.optional;
    }
};

/// The instruction's name as a listing shows it.
pub fn writeOpName(w: *std.Io.Writer, op: Op) std.Io.Writer.Error!void {
    for (@tagName(op)) |c| try w.writeByte(std.ascii.toUpper(c));
}
