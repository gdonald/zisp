const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const symbol = @import("symbol.zig");
const Value = value.Value;

const MAX_DEPTH: u32 = 1024;

const PrintCtx = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(u64, void),
};

const PrintError = std.Io.Writer.Error || std.mem.Allocator.Error;

/// Minimal printer for Phase 0 — enough to inspect values from tests and the
/// REPL. Cycle-safe via a `seen` set of cons addresses. Not yet ANSI-compliant;
/// full `*print-readably*` / `*print-circle*` machinery is Phase 1.3 / 4.10.
///
/// Note: shared substructure (the same cons appearing twice in disjoint
/// positions) prints the second occurrence as `#<cycle>` because we never
/// remove from `seen`. This is documented Phase-0 behavior, not a bug.
pub fn print(allocator: std.mem.Allocator, writer: *std.Io.Writer, v: Value) PrintError!void {
    var ctx: PrintCtx = .{ .writer = writer, .allocator = allocator, .seen = .{} };
    defer ctx.seen.deinit(allocator);
    try printValue(&ctx, v, 0);
}

fn printValue(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    if (depth > MAX_DEPTH) {
        try ctx.writer.writeAll("#<deep>");
        return;
    }
    if (v.equalsRaw(value.NIL)) {
        try ctx.writer.writeAll("NIL");
        return;
    }
    switch (v.tag()) {
        .fixnum => try ctx.writer.print("{d}", .{v.toFixnum()}),
        .cons => try printCons(ctx, v, depth),
        .symbol => try ctx.writer.writeAll(symbol.name(v)),
        .heap => try ctx.writer.print("#<heap-object {x}>", .{v.toHeapAddr()}),
        .char => try printChar(ctx, v.toChar()),
        .special => try printSpecial(ctx, v),
        else => try ctx.writer.writeAll("#<?>"),
    }
}

fn printCons(ctx: *PrintCtx, v: Value, depth: u32) PrintError!void {
    if (ctx.seen.contains(v.toConsAddr())) {
        try ctx.writer.writeAll("#<cycle>");
        return;
    }

    try ctx.writer.writeByte('(');
    var cur = v;
    var first = true;
    while (cur.isCons()) {
        const cur_addr = cur.toConsAddr();
        if (!first and ctx.seen.contains(cur_addr)) {
            try ctx.writer.writeAll(" . #<cycle>");
            break;
        }
        try ctx.seen.put(ctx.allocator, cur_addr, {});

        if (!first) try ctx.writer.writeByte(' ');
        try printValue(ctx, heap.car(cur), depth + 1);
        first = false;

        const tail = heap.cdr(cur);
        if (tail.equalsRaw(value.NIL)) break;
        if (!tail.isCons()) {
            try ctx.writer.writeAll(" . ");
            try printValue(ctx, tail, depth + 1);
            break;
        }
        cur = tail;
    }
    try ctx.writer.writeByte(')');
}

fn printChar(ctx: *PrintCtx, c: u21) !void {
    try ctx.writer.writeAll("#\\");
    switch (c) {
        ' ' => try ctx.writer.writeAll("Space"),
        '\n' => try ctx.writer.writeAll("Newline"),
        '\t' => try ctx.writer.writeAll("Tab"),
        '\r' => try ctx.writer.writeAll("Return"),
        0 => try ctx.writer.writeAll("Null"),
        else => {
            if (c < 0x80) {
                try ctx.writer.writeByte(@intCast(c));
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch {
                    try ctx.writer.print("U+{X}", .{c});
                    return;
                };
                try ctx.writer.writeAll(buf[0..n]);
            }
        },
    }
}

fn printSpecial(ctx: *PrintCtx, v: Value) !void {
    switch (v.toSpecialIndex()) {
        0 => try ctx.writer.writeAll("#<unbound>"),
        1 => try ctx.writer.writeAll("#<eof>"),
        else => |idx| try ctx.writer.print("#<special:{d}>", .{idx}),
    }
}

/// Convenience: prints to a buffer and returns the owned slice.
pub fn printToOwnedSlice(allocator: std.mem.Allocator, v: Value) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try print(allocator, &aw.writer, v);
    return aw.toOwnedSlice();
}
