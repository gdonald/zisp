//! The pretty printer's layout engine.
//!
//! Output is recorded as a token stream rather than written straight out,
//! because whether a conditional newline breaks depends on how wide the
//! block it sits in turns out to be. Once the outermost block closes, the
//! tokens are laid out against the right margin.

const std = @import("std");

pub const NewlineKind = enum { linear, fill, miser, mandatory };
pub const IndentKind = enum { block, current };

pub const Token = union(enum) {
    text: []const u8,
    newline: NewlineKind,
    indent: struct { kind: IndentKind, amount: i64 },
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
    /// A block with no more than this much room left lays out in miser
    /// style, where a fill newline behaves as a linear one.
    miser_width: ?usize = null,
    /// Column the underlying stream is already sitting at.
    start_column: usize = 0,
};

pub const State = struct {
    tokens: std.ArrayListUnmanaged(Token) = .empty,
    /// How many blocks are open, so the outermost one knows when to lay
    /// itself out.
    depth: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.tokens.deinit(allocator);
    }
};

/// One open block during layout.
const Frame = struct {
    /// Column the block began at, before its prefix went out.
    origin: usize,
    /// Where a broken line in this block starts by default, which is also
    /// what a `:block` indent is measured from.
    base: usize,
    /// Column a broken line inside this block starts at.
    indent: usize,
    per_line: []const u8,
    miser: bool,
    /// Set once a linear newline in this block has broken. The rest then
    /// break with it, so a block that does not fit puts every part on its
    /// own line rather than wrapping only where it has to.
    broken: bool = false,
};

/// Lay the tokens out and return the text. The caller owns it.
pub fn layout(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    options: Options,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var column = options.start_column;
    var frames: std.ArrayListUnmanaged(Frame) = .empty;
    defer frames.deinit(allocator);
    try frames.append(allocator, .{
        .origin = column,
        .base = column,
        .indent = column,
        .per_line = "",
        .miser = false,
    });

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i]) {
            .text => |text| {
                try out.appendSlice(allocator, text);
                column = advance(column, text);
            },
            .block_start => |block| {
                const origin = column;
                try out.appendSlice(allocator, block.prefix);
                column = advance(column, block.prefix);
                // Miser style applies when the room left for the block is
                // no wider than the miser width.
                const available = options.right_margin -| origin;
                const miser = if (options.miser_width) |width| available <= width else false;
                // A per-line prefix is written again after every break, so
                // the indent stops short of it rather than counting its
                // width twice.
                const base = if (block.per_line.len == 0) column else origin;
                try frames.append(allocator, .{
                    .origin = origin,
                    .base = base,
                    .indent = base,
                    .per_line = block.per_line,
                    .miser = miser,
                });
            },
            .block_end => {
                if (frames.items.len > 1) _ = frames.pop();
            },
            .indent => |request| {
                const frame = &frames.items[frames.items.len - 1];
                const from: i64 = @intCast(switch (request.kind) {
                    .block => frame.base,
                    .current => column,
                });
                frame.indent = @intCast(@max(from + request.amount, 0));
            },
            .newline => |kind| {
                const frame = &frames.items[frames.items.len - 1];
                if (!breaks(kind, frame, tokens[i + 1 ..], column, options)) continue;
                // A break discards the blanks that were about to end the
                // line, so a separator space never trails a wrapped line.
                while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
                    _ = out.pop();
                }
                try out.append(allocator, '\n');
                column = frame.indent;
                try out.appendNTimes(allocator, ' ', frame.indent);
                try out.appendSlice(allocator, frame.per_line);
                column += textWidth(frame.per_line);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Whether a conditional newline of this kind breaks here.
fn breaks(
    kind: NewlineKind,
    frame: *Frame,
    rest: []const Token,
    column: usize,
    options: Options,
) bool {
    if (kind == .mandatory) return true;
    // In miser style a fill newline behaves as a linear one, so a block
    // that does not fit puts each part on its own line rather than
    // wrapping only where it must.
    const effective: NewlineKind = if (frame.miser and kind == .fill) .linear else kind;
    if (effective == .fill) return column + nextChunkWidth(rest) > options.right_margin;
    if (effective == .miser and !frame.miser) return false;

    // Linear newlines in one block break together, so the first break
    // settles the rest.
    if (frame.broken) return true;
    if (fitsRemainingBlock(rest, column, options.right_margin)) return false;
    frame.broken = true;
    return true;
}

/// Whether what is left of this line fits before the margin.
///
/// The measure runs past the end of the block the newline sits in and
/// through the suffixes of the blocks around it, because those land on
/// the same line. Only a mandatory newline stops it.
fn fitsRemainingBlock(rest: []const Token, column: usize, margin: usize) bool {
    var width: usize = 0;
    for (rest) |token| {
        switch (token) {
            .text => |text| width += textWidth(text),
            .block_start => |block| width += textWidth(block.prefix),
            .block_end => {},
            // Conditional newlines are passed over: the ones in this
            // block break together with this one, and the ones in a
            // nested block would only break if that block did not fit.
            // A mandatory newline really does end the line.
            .newline => |kind| {
                if (kind == .mandatory) return column + width <= margin;
            },
            .indent => {},
        }
        if (column + width > margin) return false;
    }
    return column + width <= margin;
}

/// Width of the text up to the next place a break could happen.
fn nextChunkWidth(rest: []const Token) usize {
    var width: usize = 0;
    for (rest) |token| {
        switch (token) {
            .text => |text| width += textWidth(text),
            .block_start => |block| width += textWidth(block.prefix),
            .newline => return width,
            .block_end => return width,
            .indent => {},
        }
    }
    return width;
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
