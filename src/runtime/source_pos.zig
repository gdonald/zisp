//! Source-position side-table for cons cells.
//!
//! Cons cells are exactly 16 bytes (car + cdr) so per-cell metadata cannot
//! live inline. Instead the reader writes positions into this side-table
//! keyed on the cons's heap address. Macroexpansion carries positions
//! forward by copying entries when it builds new cons cells.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// Position of a token or cons in a source file. The file slice is
/// borrowed; callers keep the underlying buffer alive (interned filenames
/// will replace this later).
pub const SourcePosition = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const PositionTable = struct {
    map: std.AutoHashMap(u64, SourcePosition),

    pub fn init(allocator: std.mem.Allocator) PositionTable {
        return .{ .map = std.AutoHashMap(u64, SourcePosition).init(allocator) };
    }

    pub fn deinit(self: *PositionTable) void {
        self.map.deinit();
    }

    pub fn record(self: *PositionTable, v: Value, pos: SourcePosition) !void {
        if (!v.isCons()) return;
        try self.map.put(v.toConsAddr(), pos);
    }

    pub fn lookup(self: *const PositionTable, v: Value) ?SourcePosition {
        if (!v.isCons()) return null;
        return self.map.get(v.toConsAddr());
    }

    pub fn count(self: *const PositionTable) u32 {
        return self.map.count();
    }
};
