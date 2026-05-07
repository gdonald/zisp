const std = @import("std");
const cli = @import("cli");

test "no args = repl" {
    const args: [0][]const u8 = .{};
    try std.testing.expect(cli.parseArgs(&args) == .repl);
}

test "--version returns print_version" {
    const args = [_][]const u8{"--version"};
    try std.testing.expect(cli.parseArgs(&args) == .print_version);
}

test "--help returns print_help" {
    const args = [_][]const u8{"--help"};
    try std.testing.expect(cli.parseArgs(&args) == .print_help);
}

test "-h returns print_help" {
    const args = [_][]const u8{"-h"};
    try std.testing.expect(cli.parseArgs(&args) == .print_help);
}

test "unknown option returns user_error" {
    const args = [_][]const u8{"--bogus"};
    const action = cli.parseArgs(&args);
    try std.testing.expect(action == .user_error);
    try std.testing.expectEqualStrings("--bogus", action.user_error);
}

test "non-option arg = repl (will become script in Phase 2)" {
    const args = [_][]const u8{"file.lisp"};
    try std.testing.expect(cli.parseArgs(&args) == .repl);
}

test "-- ends option processing" {
    const args = [_][]const u8{ "--", "--bogus" };
    // Past the `--`, the second arg is treated as a positional, not an option.
    try std.testing.expect(cli.parseArgs(&args) == .repl);
}

test "exit codes are stable integers" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(cli.ExitCode.success));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(cli.ExitCode.user_error));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(cli.ExitCode.internal_error));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(cli.ExitCode.test_failure));
}

test "--read-only requires a path" {
    const args = [_][]const u8{"--read-only"};
    const action = cli.parseArgs(&args);
    try std.testing.expect(action == .user_error);
}

test "--read-only PATH returns read_only action" {
    const args = [_][]const u8{ "--read-only", "vendor/ansi-test/reader/read.lsp" };
    const action = cli.parseArgs(&args);
    try std.testing.expect(action == .read_only);
    try std.testing.expectEqualStrings("vendor/ansi-test/reader/read.lsp", action.read_only);
}
