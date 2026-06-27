const std = @import("std");

pub const VERSION = "0.0.0";

pub const ExitCode = enum(u8) {
    success = 0,
    user_error = 1,
    internal_error = 2,
    test_failure = 3,
};

/// One unit of batch work, in command-line order.
pub const Op = union(enum) {
    /// `--eval EXPR` — read, evaluate, and print EXPR.
    eval: []const u8,
    /// `--load FILE` — load FILE without printing its forms' values.
    load: []const u8,
};

/// A batch run assembled from the command line.
pub const Plan = struct {
    /// `--eval` / `--load` units, in order. Allocated; free with `deinit`.
    ops: []const Op = &.{},
    /// `--batch` — do not enter the REPL after processing ops/script.
    batch: bool = false,
    /// `--quiet` — suppress the startup banner.
    quiet: bool = false,
    /// `--script FILE` or a bare positional FILE.
    script: ?[]const u8 = null,
    /// Arguments following the script, bound to `*command-line-arguments*`.
    script_args: []const []const u8 = &.{},

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.ops);
    }
};

pub const Action = union(enum) {
    repl: void,
    print_version: void,
    print_help: void,
    user_error: []const u8, // message
    /// `--read-only FILE` — parse every form in FILE, report a one-line
    /// summary, exit non-zero on any parse failure. Used by the reader-only
    /// ansi-test sweep to measure parse-rate.
    read_only: []const u8,
    /// A batch run: `--eval` / `--load` / `--script`, optionally followed by
    /// the REPL unless `--batch` was given.
    run: Plan,
};

/// Parse argv (minus the program name) into an Action. The `run` variant owns
/// an allocated `ops` slice; the caller frees it via `Plan.deinit`.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Action {
    if (args.len == 0) return .repl;

    var ops: std.ArrayList(Op) = .empty;
    errdefer ops.deinit(allocator);

    var batch = false;
    var quiet = false;
    var script: ?[]const u8 = null;
    var script_args: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            ops.deinit(allocator);
            return .print_version;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            ops.deinit(allocator);
            return .print_help;
        }
        if (std.mem.eql(u8, arg, "--read-only")) {
            ops.deinit(allocator);
            if (i + 1 >= args.len) return .{ .user_error = "--read-only requires a path" };
            return .{ .read_only = args[i + 1] };
        }
        if (std.mem.eql(u8, arg, "--eval") or std.mem.eql(u8, arg, "-e")) {
            if (i + 1 >= args.len) {
                ops.deinit(allocator);
                return .{ .user_error = "--eval requires an expression" };
            }
            try ops.append(allocator, .{ .eval = args[i + 1] });
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--load") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 >= args.len) {
                ops.deinit(allocator);
                return .{ .user_error = "--load requires a path" };
            }
            try ops.append(allocator, .{ .load = args[i + 1] });
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--batch")) {
            batch = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--script")) {
            if (i + 1 >= args.len) {
                ops.deinit(allocator);
                return .{ .user_error = "--script requires a path" };
            }
            script = args[i + 1];
            script_args = args[i + 2 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "--")) {
            const rest = args[i + 1 ..];
            if (rest.len > 0) {
                script = rest[0];
                script_args = rest[1..];
            }
            break;
        }
        if (arg.len > 1 and arg[0] == '-') {
            ops.deinit(allocator);
            return .{ .user_error = arg };
        }
        // A bare positional is the script; everything after it is its args.
        script = arg;
        script_args = args[i + 1 ..];
        break;
    }

    const ops_slice = try ops.toOwnedSlice(allocator);
    if (ops_slice.len == 0 and script == null and !batch and !quiet) {
        allocator.free(ops_slice);
        return .repl;
    }
    return .{ .run = .{
        .ops = ops_slice,
        .batch = batch,
        .quiet = quiet,
        .script = script,
        .script_args = script_args,
    } };
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
    \\    --eval EXPR, -e     Read, evaluate, and print EXPR (repeatable)
    \\    --load FILE, -l     Load FILE (repeatable)
    \\    --script FILE       Run FILE as a script; remaining args bound to
    \\                        *command-line-arguments*
    \\    --batch             Process options and exit; no REPL
    \\    --quiet, -q         Suppress the startup banner
    \\    --read-only FILE    Parse FILE without evaluating; report parse-rate
    \\    --                  End of options
    \\
    \\See docs/cli.md for the full reference.
    \\
;

/// Writes a plain message to stderr without involving the I/O writer machinery.
/// Used by main() before there's any Lisp state to manage.
pub fn write(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
