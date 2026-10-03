//! Test runner for the unit suite. It differs from Zig's default runner in
//! one setting: the testing allocator records no stack trace per allocation.
//! Capturing one walks DWARF unwind tables, which made the suite take minutes
//! in Debug and far longer under kcov.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
            .stack_trace_frames = 0,
        });
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() != 0) leaks += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        if (test_fn.func()) |_| {
            ok_count += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    if (ok_count == test_fn_list.len) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (log_err_count != 0) std.debug.print("{d} errors were logged.\n", .{log_err_count});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) std.process.exit(1);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

/// `std.testing.fuzz` calls this. The unit suite runs each fuzz test's corpus
/// and an empty input once. `zig build fuzz-reader` does the fuzzing.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
