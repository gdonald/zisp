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
    map: std.AutoHashMap(u64, Entry),

    /// Where a cons was read, or for one a macro built, where that macro
    /// was defined. `call_site` is set on the conses a macro built: it is
    /// where the call that the macro expanded was written.
    pub const Entry = struct {
        pos: SourcePosition,
        call_site: ?SourcePosition = null,
    };

    pub fn init(allocator: std.mem.Allocator) PositionTable {
        return .{ .map = std.AutoHashMap(u64, Entry).init(allocator) };
    }

    pub fn deinit(self: *PositionTable) void {
        self.map.deinit();
    }

    pub fn record(self: *PositionTable, v: Value, pos: SourcePosition) !void {
        if (!v.isCons()) return;
        try self.map.put(v.toConsAddr(), .{ .pos = pos });
    }

    /// Record `v` as a cons a macro built from a call written at
    /// `call_site`, in a macro defined at `pos`.
    pub fn recordExpansion(self: *PositionTable, v: Value, pos: SourcePosition, call_site: ?SourcePosition) !void {
        if (!v.isCons()) return;
        try self.map.put(v.toConsAddr(), .{ .pos = pos, .call_site = call_site });
    }

    pub fn lookup(self: *const PositionTable, v: Value) ?SourcePosition {
        if (!v.isCons()) return null;
        const entry = self.map.get(v.toConsAddr()) orelse return null;
        return entry.pos;
    }

    /// Where the person wrote the code `v` stands for: where it was read,
    /// or for a cons a macro built, where the macro's call was written.
    pub fn userPosition(self: *const PositionTable, v: Value) ?SourcePosition {
        if (!v.isCons()) return null;
        const entry = self.map.get(v.toConsAddr()) orelse return null;
        return entry.call_site orelse entry.pos;
    }

    pub fn count(self: *const PositionTable) u32 {
        return self.map.count();
    }
};
