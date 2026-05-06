const std = @import("std");

pub fn main() !void {
    std.debug.print("zisp 0.0.0\n", .{});
}

test "stub" {
    try std.testing.expect(true);
}
