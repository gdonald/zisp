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
        .repl => blk: {
            _ = zisp;
            cli.write("zisp {s}\n(REPL not implemented yet — Phase 2)\n", .{cli.VERSION});
            break :blk @intFromEnum(cli.ExitCode.success);
        },
    };
}
