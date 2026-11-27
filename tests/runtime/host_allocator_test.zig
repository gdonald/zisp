const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");

const HostAllocator = zisp.HostAllocator;

/// A host heap that hands out at most `limit` bytes at a time, backed by
/// the testing allocator so a wrong length on free or a leak fails.
const CountingHeap = struct {
    limit: usize = std.math.maxInt(usize),
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,

    fn alloc(context: ?*anyopaque, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const self: *CountingHeap = @ptrCast(@alignCast(context.?));
        if (self.live_bytes + len > self.limit) return null;
        const memory = testing.allocator.rawAlloc(len, alignment, @returnAddress()) orelse return null;
        self.live_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        self.allocations += 1;
        return memory;
    }

    fn free(context: ?*anyopaque, memory: []u8, alignment: std.mem.Alignment) void {
        const self: *CountingHeap = @ptrCast(@alignCast(context.?));
        testing.allocator.rawFree(memory, alignment, @returnAddress());
        self.live_bytes -= memory.len;
        self.frees += 1;
    }

    fn host(self: *CountingHeap) HostAllocator {
        return .{ .context = self, .alloc = alloc, .free = free };
    }
};

fn evaluate(gpa: std.mem.Allocator, source: []const u8, output: *std.Io.Writer.Allocating) !void {
    const repl = try zisp.repl.Repl.init(gpa, &output.writer, null);
    defer repl.deinit();
    try repl.run(source);
}

test "a session runs on memory from the host allocator and returns all of it" {
    var counting: CountingHeap = .{};
    const host = counting.host();
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    try evaluate(host.allocator(), "(+ 1 2) (length (make-list 1000))", &output);

    try testing.expectEqualStrings("3\n1000\n", output.written());
    try testing.expect(counting.allocations > 0);
    try testing.expectEqual(counting.allocations, counting.frees);
    try testing.expectEqual(@as(usize, 0), counting.live_bytes);
}

test "a host allocator that grows a buffer is asked for new memory each time" {
    var counting: CountingHeap = .{};
    const host = counting.host();
    const gpa = host.allocator();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendNTimes(gpa, 'a', 10);
    try list.appendNTimes(gpa, 'b', 1000);

    try testing.expectEqual(@as(usize, 1010), list.items.len);
    try testing.expectEqual('b', list.items[1009]);
    try testing.expectEqual(@as(usize, 2), counting.allocations);
    try testing.expectEqual(@as(usize, 1), counting.frees);
}

test "a host allocator that runs out at any point in booting fails the session and gets all its memory back" {
    // What a booted session holds at once, which every limit below has
    // too little for. The peak is larger, and a collection that finds no
    // memory for its work is skipped rather than failing the session.
    var unlimited: CountingHeap = .{};
    const unlimited_host = unlimited.host();
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    const repl = try zisp.repl.Repl.init(unlimited_host.allocator(), &output.writer, null);
    try repl.run("(+ 1 2)");
    const held_bytes = unlimited.live_bytes;
    repl.deinit();

    var eighths: usize = 0;
    while (eighths < 8) : (eighths += 1) {
        var counting: CountingHeap = .{ .limit = held_bytes * eighths / 8 };
        const host = counting.host();
        try testing.expectError(error.OutOfMemory, evaluate(host.allocator(), "(+ 1 2)", &output));
        try testing.expectEqual(@as(usize, 0), counting.live_bytes);
    }
}
