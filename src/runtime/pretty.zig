//! The pretty printer's layout engine.
//!
//! Output is recorded as a token stream rather than written straight out,
//! because whether a conditional newline breaks depends on what follows
//! it. Once the outermost block closes, the tokens are laid out against
//! the right margin following CLHS 22.2.1.1: each conditional newline
//! sits in sections delimited by the newlines around it, and its kind
//! says which of them has to fit for it to stay unbroken.

const std = @import("std");

pub const NewlineKind = enum { linear, fill, miser, mandatory };
pub const IndentKind = enum { block, current };
pub const TabKind = enum { line, section, line_relative, section_relative };

pub const Token = union(enum) {
    text: []const u8,
    newline: NewlineKind,
    indent: struct { kind: IndentKind, amount: i64 },
    tab: struct { kind: TabKind, colnum: usize, colinc: usize },
    block_start: Block,
    block_end,
};

pub const Block = struct {
    prefix: []const u8,
    per_line: []const u8,
    suffix: []const u8,
};

pub const Options = struct {
    /// Column the output must not run past.
    right_margin: usize = 80,
    /// A block that starts within this many columns of the margin lays
    /// out in miser style.
    miser_width: ?usize = null,
    /// `*print-lines*`: how many lines to print before ending with ` ..`.
    lines: ?usize = null,
    /// Column the underlying stream is already sitting at.
    start_column: usize = 0,
};

/// One open block during layout.
const Frame = struct {
    /// Column the block began at, before its prefix.
    origin: usize,
    /// Column after the prefix, which `:block` indentation counts from.
    start: usize,
    /// Column a broken line inside this block starts at.
    indent: usize,
    per_line: []const u8,
    suffix: []const u8,
    miser: bool,
    /// Index of the token that opened the block.
    opened_at: usize,
};

const Layout = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    options: Options,
    out: std.ArrayListUnmanaged(u8) = .empty,
    column: usize,
    /// Where in `out` the current line begins, so trailing blanks are
    /// trimmed only from it.
    line_start: usize = 0,
    lines: usize = 1,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    /// How many blocks are open at each token.
    level: []usize,
    /// The column each token started at.
    column_at: []usize,
    /// Index of the last newline that broke, if any did.
    last_break: ?usize = null,
    /// Column of the start of the section the current position is in,
    /// which `:section` tabs count from.
    section_column: usize,

    fn deinit(self: *Layout) void {
        self.frames.deinit(self.allocator);
        self.allocator.free(self.level);
        self.allocator.free(self.column_at);
    }

    fn margin(self: *const Layout) usize {
        return self.options.right_margin;
    }

    fn write(self: *Layout, text: []const u8) !void {
        try self.out.appendSlice(self.allocator, text);
        self.column = advance(self.column, text);
    }

    fn spaces(self: *Layout, n: usize) !void {
        try self.out.appendNTimes(self.allocator, ' ', n);
        self.column += n;
    }

    fn frame(self: *const Layout) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    // --- measuring --------------------------------------------------

    /// The column `tokens[from..to]` ends at when printed with no breaks
    /// from `column`, or null when a mandatory newline among them means
    /// they cannot share one line.
    fn flatEnd(self: *const Layout, from: usize, to: usize, column: usize) ?usize {
        var col = column;
        var section = column;
        for (self.tokens[from..to]) |token| {
            switch (token) {
                .text => |text| {
                    if (std.mem.indexOfScalar(u8, text, '\n') != null) return null;
                    col += textWidth(text);
                },
                .block_start => |block| col += textWidth(block.prefix),
                .newline => |kind| {
                    if (kind == .mandatory) return null;
                    section = col;
                },
                .tab => |tab| col += tabWidth(tab.kind, tab.colnum, tab.colinc, col, section),
                .block_end, .indent => {},
            }
        }
        return col;
    }

    fn fits(self: *const Layout, from: usize, to: usize, column: usize) bool {
        const end = self.flatEnd(from, to, column) orelse return false;
        return end <= self.margin();
    }

    /// The token after the newline that ends the section following
    /// newline `i`: the next newline in the same block or an outer one.
    fn sectionEnd(self: *const Layout, i: usize) usize {
        const level = self.level[i];
        var j = i + 1;
        while (j < self.tokens.len) : (j += 1) {
            if (self.tokens[j] == .newline and self.level[j] <= level) return j;
        }
        return self.tokens.len;
    }

    /// The section immediately containing newline `i`, as token bounds:
    /// from just after the previous newline of an outer block to the next
    /// one.
    fn containingSection(self: *const Layout, i: usize) struct { from: usize, to: usize } {
        const level = self.level[i];
        var from: usize = 0;
        var k = i;
        while (k > 0) {
            k -= 1;
            if (self.tokens[k] == .newline and self.level[k] < level) {
                from = k + 1;
                break;
            }
        }
        var to = self.tokens.len;
        var j = i + 1;
        while (j < self.tokens.len) : (j += 1) {
            if (self.tokens[j] == .newline and self.level[j] < level) {
                to = j;
                break;
            }
        }
        return .{ .from = from, .to = to };
    }

    /// Whether the section from token `from` to `to` goes out on one
    /// line: nothing in it broke, and printed flat it fits.
    fn onOneLine(self: *const Layout, from: usize, to: usize) bool {
        if (self.last_break) |at| {
            if (at >= from and at < to) return false;
        }
        const start = if (from < self.column_at.len) self.column_at[from] else self.column;
        return self.fits(from, to, start);
    }

    /// Where the section before newline `i` starts: after the previous
    /// newline of the same block, or at the block's own start.
    fn sectionBefore(self: *const Layout, i: usize) usize {
        const level = self.level[i];
        const block_start = if (self.frames.items.len > 0) self.frame().opened_at + 1 else 0;
        var k = i;
        while (k > block_start) {
            k -= 1;
            if (self.tokens[k] == .newline and self.level[k] <= level) return k + 1;
        }
        return block_start;
    }

    fn breaks(self: *Layout, i: usize, kind: NewlineKind) bool {
        const miser = self.frames.items.len > 1 and self.frame().miser;
        switch (kind) {
            .mandatory => return true,
            .linear => {
                const section = self.containingSection(i);
                return !self.onOneLine(section.from, section.to);
            },
            .miser => {
                if (!miser) return false;
                const section = self.containingSection(i);
                return !self.onOneLine(section.from, section.to);
            },
            .fill => {
                if (!self.fits(i + 1, self.sectionEnd(i), self.column)) return true;
                if (self.last_break) |at| {
                    if (at >= self.sectionBefore(i) and at < i) return true;
                }
                if (miser) {
                    const section = self.containingSection(i);
                    return !self.onOneLine(section.from, section.to);
                }
                return false;
            },
        }
    }

    // --- writing ----------------------------------------------------

    /// End the line and start the next one inside the open blocks: their
    /// per-line prefixes, each where it stood on the first line, then
    /// blanks out to the innermost block's indentation. False once
    /// `*print-lines*` lines are out, which ends the output.
    fn newLine(self: *Layout) !bool {
        if (self.options.lines) |most| {
            if (self.lines >= most) {
                try self.write(" ..");
                var n = self.frames.items.len;
                while (n > 1) {
                    n -= 1;
                    try self.write(self.frames.items[n].suffix);
                }
                return false;
            }
        }
        // A break drops the blanks that were about to end the line.
        while (self.out.items.len > self.line_start and self.out.items[self.out.items.len - 1] == ' ') {
            _ = self.out.pop();
        }
        try self.out.append(self.allocator, '\n');
        self.lines += 1;
        self.line_start = self.out.items.len;
        self.column = 0;
        for (self.frames.items) |f| {
            if (f.per_line.len == 0) continue;
            if (f.origin > self.column) try self.spaces(f.origin - self.column);
            try self.write(f.per_line);
        }
        const indent = self.frame().indent;
        if (indent > self.column) try self.spaces(indent - self.column);
        return true;
    }

    /// A newline written as text: a new line holding the per-line
    /// prefixes but none of the blocks' indentation.
    fn newLineUnindented(self: *Layout) !bool {
        const f = self.frame();
        const indent = f.indent;
        f.indent = 0;
        defer f.indent = indent;
        return self.newLine();
    }

    fn run(self: *Layout) !void {
        var i: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            self.column_at[i] = self.column;
            switch (self.tokens[i]) {
                .text => |text| {
                    var rest = text;
                    while (std.mem.indexOfScalar(u8, rest, '\n')) |at| {
                        try self.write(rest[0..at]);
                        self.last_break = i;
                        if (!try self.newLineUnindented()) return;
                        self.section_column = self.column;
                        rest = rest[at + 1 ..];
                    }
                    try self.write(rest);
                },
                .block_start => |block| {
                    const origin = self.column;
                    try self.write(block.prefix);
                    // Miser style is measured from where the block's own
                    // text starts, after its prefix.
                    const room = self.margin() -| self.column;
                    const miser = if (self.options.miser_width) |width| room <= width else false;
                    try self.frames.append(self.allocator, .{
                        .origin = origin,
                        .start = self.column,
                        .indent = self.column,
                        .per_line = block.per_line,
                        .suffix = block.suffix,
                        .miser = miser,
                        .opened_at = i,
                    });
                    self.section_column = self.column;
                },
                .block_end => {
                    if (self.frames.items.len > 1) _ = self.frames.pop();
                },
                .indent => |request| {
                    const f = self.frame();
                    if (f.miser) continue;
                    const from: i64 = @intCast(switch (request.kind) {
                        .block => f.start,
                        .current => self.column,
                    });
                    f.indent = @intCast(@max(from + request.amount, 0));
                },
                .tab => |tab| try self.spaces(tabWidth(tab.kind, tab.colnum, tab.colinc, self.column, self.section_column)),
                .newline => |kind| {
                    if (!self.breaks(i, kind)) {
                        self.section_column = self.column;
                        continue;
                    }
                    self.last_break = i;
                    if (!try self.newLine()) return;
                    self.section_column = self.column;
                },
            }
        }
    }
};

/// Lay the tokens out and return the text. The caller owns it.
pub fn layout(allocator: std.mem.Allocator, tokens: []const Token, options: Options) ![]u8 {
    const level = try allocator.alloc(usize, tokens.len);
    const column_at = try allocator.alloc(usize, tokens.len);
    var depth: usize = 0;
    for (tokens, level) |token, *l| {
        if (token == .block_end and depth > 0) depth -= 1;
        l.* = depth;
        if (token == .block_start) depth += 1;
    }
    var state: Layout = .{
        .allocator = allocator,
        .tokens = tokens,
        .options = options,
        .column = options.start_column,
        .level = level,
        .column_at = column_at,
        .section_column = options.start_column,
    };
    defer state.deinit();
    errdefer state.out.deinit(allocator);
    try state.frames.append(allocator, .{
        .origin = options.start_column,
        .start = options.start_column,
        .indent = options.start_column,
        .per_line = "",
        .suffix = "",
        .miser = false,
        .opened_at = 0,
    });
    try state.run();
    return state.out.toOwnedSlice(allocator);
}

/// How many blanks a tab writes at `column`, CLHS 22.3.6.1 and
/// `pprint-tab`: an absolute tab goes to `colnum`, or past it by a
/// multiple of `colinc`; a relative one moves `colnum` and then on to a
/// multiple of `colinc`. A section tab counts from `section`.
pub fn tabWidth(kind: TabKind, colnum: usize, colinc: usize, column: usize, section: usize) usize {
    const origin: usize = switch (kind) {
        .line, .line_relative => 0,
        .section, .section_relative => section,
    };
    const at = column -| origin;
    switch (kind) {
        .line, .section => {
            if (at < colnum) return colnum - at;
            if (colinc == 0) return 0;
            return colinc - ((at - colnum) % colinc);
        },
        .line_relative, .section_relative => {
            const moved = at + colnum;
            if (colinc <= 1) return colnum;
            const over = moved % colinc;
            return colnum + if (over == 0) 0 else colinc - over;
        },
    }
}

/// The column after writing `text`, which a newline inside it resets.
fn advance(column: usize, text: []const u8) usize {
    if (std.mem.lastIndexOfScalar(u8, text, '\n')) |last| {
        return textWidth(text[last + 1 ..]);
    }
    return column + textWidth(text);
}

/// Characters in a UTF-8 slice, which is what a column counts.
fn textWidth(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}
