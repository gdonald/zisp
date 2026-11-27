//! The text a reader reads from, one character at a time.
//!
//! The source borrows its bytes, which are UTF-8. A byte that does not
//! start a well-formed sequence is taken as the Latin-1 character it
//! encodes, so no input is rejected here. The line and column of the next
//! character are kept for source positions and error reports.

const std = @import("std");

/// Source position. Lines and columns are 1-based; byte_offset is 0-based.
pub const Position = struct {
    line: u32 = 1,
    column: u32 = 1,
    byte_offset: u32 = 0,
};

pub const Source = struct {
    src: []const u8,
    /// Byte offset of the next character to read.
    idx: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    /// How many bytes the character `next` returned last took.
    last_width: usize = 1,

    pub fn init(src: []const u8) Source {
        return .{ .src = src };
    }

    pub fn pos(self: *const Source) Position {
        return .{ .line = self.line, .column = self.col, .byte_offset = @intCast(self.idx) };
    }

    /// The character at byte `at` and how many bytes it takes.
    fn decodeAt(self: *const Source, at: usize) struct { code: u21, width: usize } {
        const byte = self.src[at];
        if (byte < 0x80) return .{ .code = byte, .width = 1 };
        const width = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .code = byte, .width = 1 };
        if (at + width > self.src.len) return .{ .code = byte, .width = 1 };
        const code = std.unicode.utf8Decode(self.src[at .. at + width]) catch return .{ .code = byte, .width = 1 };
        return .{ .code = code, .width = width };
    }

    pub fn peek(self: *const Source) ?u21 {
        if (self.idx >= self.src.len) return null;
        return self.decodeAt(self.idx).code;
    }

    pub fn next(self: *Source) ?u21 {
        if (self.idx >= self.src.len) return null;
        const decoded = self.decodeAt(self.idx);
        self.idx += decoded.width;
        self.last_width = decoded.width;
        if (decoded.code == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return decoded.code;
    }

    /// Step back over `code`, the character `next` returned last.
    pub fn back(self: *Source, code: u21) void {
        const target = self.idx - @min(self.last_width, self.idx);
        if (code == '\n') return self.seek(target);
        self.idx = target;
        self.col -|= 1;
    }

    /// Move to byte `target`, counting the lines and columns on the way.
    pub fn seek(self: *Source, target: usize) void {
        const to = @min(target, self.src.len);
        if (to < self.idx) {
            self.idx = 0;
            self.line = 1;
            self.col = 1;
        }
        while (self.idx < to) _ = self.next();
    }
};
