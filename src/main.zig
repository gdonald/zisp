const std = @import("std");
const zisp = @import("zisp");
const cli = @import("cli");

pub fn main(init: std.process.Init) !u8 {
    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iter.deinit();

    _ = iter.next(); // program name

    var buf: [64][]const u8 = undefined;
    var n: usize = 0;
    while (iter.next()) |arg| : (n += 1) {
        if (n >= buf.len) {
            cli.write("zisp: too many arguments (max {d})\n", .{buf.len});
            return @intFromEnum(cli.ExitCode.user_error);
        }
        buf[n] = arg;
    }

    return switch (cli.parseArgs(buf[0..n])) {
        .print_version => blk: {
            cli.write("zisp {s}\n", .{cli.VERSION});
            break :blk @intFromEnum(cli.ExitCode.success);
        },
        .print_help => blk: {
            cli.write("{s}", .{cli.HELP_TEXT});
            break :blk @intFromEnum(cli.ExitCode.success);
        },
        .user_error => |msg| blk: {
            cli.write("zisp: unknown option '{s}'\nTry 'zisp --help' for usage.\n", .{msg});
            break :blk @intFromEnum(cli.ExitCode.user_error);
        },
        .read_only => |path| readOnlyMode(init.gpa, init.io, path),
        .repl => blk: {
            cli.write("zisp {s}\n(REPL not implemented yet)\n", .{cli.VERSION});
            break :blk @intFromEnum(cli.ExitCode.success);
        },
    };
}

/// Reads `path`, hands the bytes to `zisp.read_all.parseAll`, and prints
/// a one-line summary tailored for
/// `tests/run-ansi.sh`'s grep aggregation. The parsing logic itself
/// lives in `read_all.zig` so the test binary can exercise it directly.
fn readOnlyMode(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        cli.write("FAIL {s}: {s}\n", .{ path, @errorName(e) });
        return @intFromEnum(cli.ExitCode.user_error);
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var source_list: std.ArrayList(u8) = .empty;
    defer source_list.deinit(gpa);
    file_reader.interface.appendRemainingUnlimited(gpa, &source_list) catch |e| {
        cli.write("FAIL {s}: {s}\n", .{ path, @errorName(e) });
        return @intFromEnum(cli.ExitCode.internal_error);
    };

    const outcome = try zisp.read_all.parseAll(gpa, source_list.items, path);
    switch (outcome) {
        .ok => |forms| {
            cli.write("OK {s} forms={d}\n", .{ path, forms });
            return @intFromEnum(cli.ExitCode.success);
        },
        .fail => |info| {
            cli.write(
                "FAIL {s}:{d}:{d} {s} after {d} forms\n",
                .{ path, info.pos.line, info.pos.column, @errorName(info.err), info.forms },
            );
            return @intFromEnum(cli.ExitCode.test_failure);
        },
    }
}
