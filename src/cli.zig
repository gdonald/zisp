const std = @import("std");

pub const VERSION = "0.0.0";

pub const ExitCode = enum(u8) {
    success = 0,
    user_error = 1,
    internal_error = 2,
    test_failure = 3,
};

pub const Action = union(enum) {
    repl: void,
    print_version: void,
    print_help: void,
    user_error: []const u8, // message
};

/// Parses argv (minus the program name) into an Action. Phase 0 understands
/// `--version` and `--help` only; Phase 2 expands this with `--eval`/`--load`/
/// `--batch`/etc.
pub fn parseArgs(args: []const []const u8) Action {
    if (args.len == 0) return .repl;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .print_version;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .print_help;
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.startsWith(u8, arg, "-")) {
            return .{ .user_error = arg };
        }
    }
    return .repl;
}

pub const HELP_TEXT =
    \\zisp — Common Lisp implementation in Zig
    \\
    \\USAGE:
    \\    zisp [OPTIONS] [FILE [ARGS...]]
    \\
    \\OPTIONS:
    \\    --version           Print version and exit
    \\    --help, -h          Print this message and exit
    \\
    \\Coming in Phase 2:
    \\    --eval EXPR, -e     Evaluate EXPR
    \\    --load FILE, -l     Load FILE
    \\    --batch             Process options and exit
    \\    --quiet, -q         Suppress banner
    \\
    \\See docs/cli.md for the full reference.
    \\
;

/// Writes a plain message to stderr without involving the I/O writer machinery.
/// Used by main() before there's any Lisp state to manage.
pub fn write(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
