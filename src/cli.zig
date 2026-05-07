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
    /// `--read-only FILE` — parse every form in FILE, report a one-line
    /// summary, exit non-zero on any parse failure. Used by Phase 1.5.3
    /// (reader-only ansi-test sweep) to measure parse-rate before the
    /// evaluator exists.
    read_only: []const u8,
};

/// Parses argv (minus the program name) into an Action. Phase 0 understands
/// `--version` and `--help`; Phase 1.5.3 adds `--read-only`. Phase 2 will
/// expand this with `--eval`/`--load`/`--batch`.
pub fn parseArgs(args: []const []const u8) Action {
    if (args.len == 0) return .repl;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) return .print_version;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .print_help;
        if (std.mem.eql(u8, arg, "--read-only")) {
            if (i + 1 >= args.len) return .{ .user_error = "--read-only requires a path" };
            return .{ .read_only = args[i + 1] };
        }
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
    \\    --read-only FILE    Parse FILE without evaluating; report parse-rate
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
