const std = @import("std");

pub const TAG_BITS: u6 = 3;
pub const TAG_MASK: u64 = 0b111;

pub const Tag = enum(u3) {
    fixnum = 0b000,
    cons = 0b001,
    symbol = 0b010,
    heap = 0b011,
    char = 0b100,
    special = 0b101,
    _reserved6 = 0b110,
    _reserved7 = 0b111,
};

pub const FIXNUM_MIN: i64 = -(@as(i64, 1) << 60);
pub const FIXNUM_MAX: i64 = (@as(i64, 1) << 60) - 1;

pub const Value = extern struct {
    raw: u64,

    pub fn tag(self: Value) Tag {
        return @enumFromInt(@as(u3, @truncate(self.raw)));
    }

    pub fn equalsRaw(self: Value, other: Value) bool {
        return self.raw == other.raw;
    }

    // --- fixnum ---

    pub fn fromFixnum(n: i64) Value {
        std.debug.assert(n >= FIXNUM_MIN and n <= FIXNUM_MAX);
        const shifted: i64 = n << TAG_BITS;
        return .{ .raw = @bitCast(shifted) };
    }

    pub fn toFixnum(self: Value) i64 {
        std.debug.assert(self.tag() == .fixnum);
        const signed: i64 = @bitCast(self.raw);
        return signed >> TAG_BITS;
    }

    pub fn isFixnum(self: Value) bool {
        return self.tag() == .fixnum;
    }

    // --- cons pointer ---

    pub fn fromConsAddr(addr: u64) Value {
        std.debug.assert((addr & TAG_MASK) == 0);
        return .{ .raw = addr | @intFromEnum(Tag.cons) };
    }

    pub fn toConsAddr(self: Value) u64 {
        std.debug.assert(self.tag() == .cons);
        return self.raw & ~TAG_MASK;
    }

    pub fn isCons(self: Value) bool {
        return self.tag() == .cons;
    }

    // --- symbol pointer ---

    pub fn fromSymbolAddr(addr: u64) Value {
        std.debug.assert((addr & TAG_MASK) == 0);
        return .{ .raw = addr | @intFromEnum(Tag.symbol) };
    }

    pub fn toSymbolAddr(self: Value) u64 {
        std.debug.assert(self.tag() == .symbol);
        return self.raw & ~TAG_MASK;
    }

    pub fn isSymbol(self: Value) bool {
        return self.tag() == .symbol;
    }

    // --- heap object pointer ---

    pub fn fromHeapAddr(addr: u64) Value {
        std.debug.assert((addr & TAG_MASK) == 0);
        return .{ .raw = addr | @intFromEnum(Tag.heap) };
    }

    pub fn toHeapAddr(self: Value) u64 {
        std.debug.assert(self.tag() == .heap);
        return self.raw & ~TAG_MASK;
    }

    pub fn isHeap(self: Value) bool {
        return self.tag() == .heap;
    }

    // --- character ---

    pub fn fromChar(codepoint: u21) Value {
        return .{ .raw = (@as(u64, codepoint) << TAG_BITS) | @intFromEnum(Tag.char) };
    }

    pub fn toChar(self: Value) u21 {
        std.debug.assert(self.tag() == .char);
        return @truncate(self.raw >> TAG_BITS);
    }

    pub fn isChar(self: Value) bool {
        return self.tag() == .char;
    }

    // --- special immediates ---

    pub fn fromSpecial(index: u8) Value {
        return .{ .raw = (@as(u64, index) << TAG_BITS) | @intFromEnum(Tag.special) };
    }

    pub fn toSpecialIndex(self: Value) u8 {
        std.debug.assert(self.tag() == .special);
        return @truncate(self.raw >> TAG_BITS);
    }

    pub fn isSpecial(self: Value) bool {
        return self.tag() == .special;
    }
};

pub const SPECIAL_UNBOUND: Value = Value.fromSpecial(0);
pub const SPECIAL_EOF: Value = Value.fromSpecial(1);

// NIL and T are populated when the symbol table is initialized.
// Their canonical Value forms are exposed so identity checks can use raw equality.
pub var NIL: Value = .{ .raw = 0 };
pub var T: Value = .{ .raw = 0 };
