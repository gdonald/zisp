const std = @import("std");
const cli = @import("cli");

const testing = std.testing;

fn parse(args: []const []const u8) !cli.Action {
    return cli.parseArgs(testing.allocator, args);
}

test "no args = repl" {
    const args: [0][]const u8 = .{};
    try testing.expect(try parse(&args) == .repl);
}

test "--version returns print_version" {
    const args = [_][]const u8{"--version"};
    try testing.expect(try parse(&args) == .print_version);
}

test "--help returns print_help" {
    const args = [_][]const u8{"--help"};
    try testing.expect(try parse(&args) == .print_help);
}

test "-h returns print_help" {
    const args = [_][]const u8{"-h"};
    try testing.expect(try parse(&args) == .print_help);
}

test "--version wins even after other options" {
    const args = [_][]const u8{ "--quiet", "--version" };
    try testing.expect(try parse(&args) == .print_version);
}

test "--help wins even after other options" {
    const args = [_][]const u8{ "--batch", "--help" };
    try testing.expect(try parse(&args) == .print_help);
}

test "unknown option returns user_error" {
    const args = [_][]const u8{"--bogus"};
    const action = try parse(&args);
    try testing.expect(action == .user_error);
    try testing.expectEqualStrings("--bogus", action.user_error);
}

test "exit codes are stable integers" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(cli.ExitCode.success));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(cli.ExitCode.user_error));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(cli.ExitCode.internal_error));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(cli.ExitCode.test_failure));
}

test "--read-only requires a path" {
    const args = [_][]const u8{"--read-only"};
    const action = try parse(&args);
    try testing.expect(action == .user_error);
}

test "--read-only PATH returns read_only action" {
    const args = [_][]const u8{ "--read-only", "vendor/ansi-test/reader/read.lsp" };
    const action = try parse(&args);
    try testing.expect(action == .read_only);
    try testing.expectEqualStrings("vendor/ansi-test/reader/read.lsp", action.read_only);
}

test "--read-only takes precedence and frees pending ops" {
    const args = [_][]const u8{ "--eval", "(+ 1 2)", "--read-only", "f.lsp" };
    const action = try parse(&args);
    try testing.expect(action == .read_only);
}

test "--eval collects an op and returns run" {
    const args = [_][]const u8{ "--eval", "(+ 1 2)" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action == .run);
    try testing.expectEqual(@as(usize, 1), action.run.ops.len);
    try testing.expect(action.run.ops[0] == .eval);
    try testing.expectEqualStrings("(+ 1 2)", action.run.ops[0].eval);
}

test "-e is an alias for --eval" {
    const args = [_][]const u8{ "-e", "(quit)" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action.run.ops[0] == .eval);
}

test "--eval without an argument is a user error" {
    const args = [_][]const u8{"--eval"};
    const action = try parse(&args);
    try testing.expect(action == .user_error);
}

test "multiple ops keep command-line order" {
    const args = [_][]const u8{ "--load", "a.lisp", "--eval", "(foo)", "-l", "b.lisp" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), action.run.ops.len);
    try testing.expect(action.run.ops[0] == .load);
    try testing.expectEqualStrings("a.lisp", action.run.ops[0].load);
    try testing.expect(action.run.ops[1] == .eval);
    try testing.expectEqualStrings("(foo)", action.run.ops[1].eval);
    try testing.expect(action.run.ops[2] == .load);
    try testing.expectEqualStrings("b.lisp", action.run.ops[2].load);
}

test "--load without an argument is a user error" {
    const args = [_][]const u8{"--load"};
    const action = try parse(&args);
    try testing.expect(action == .user_error);
}

test "--batch sets the batch flag" {
    const args = [_][]const u8{ "--batch", "--eval", "(foo)" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action.run.batch);
}

test "--batch alone still produces a run plan" {
    const args = [_][]const u8{"--batch"};
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action == .run);
    try testing.expect(action.run.batch);
    try testing.expectEqual(@as(usize, 0), action.run.ops.len);
}

test "--quiet alone produces a run plan that will reach the repl" {
    const args = [_][]const u8{"--quiet"};
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action == .run);
    try testing.expect(action.run.quiet);
    try testing.expect(!action.run.batch);
    try testing.expect(action.run.script == null);
}

test "-q is an alias for --quiet" {
    const args = [_][]const u8{ "-q", "--batch" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action.run.quiet);
}

test "--script captures the script and its trailing args" {
    const args = [_][]const u8{ "--script", "run.lisp", "one", "two" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqualStrings("run.lisp", action.run.script.?);
    try testing.expectEqual(@as(usize, 2), action.run.script_args.len);
    try testing.expectEqualStrings("one", action.run.script_args[0]);
    try testing.expectEqualStrings("two", action.run.script_args[1]);
}

test "--script without an argument is a user error" {
    const args = [_][]const u8{"--script"};
    const action = try parse(&args);
    try testing.expect(action == .user_error);
}

test "a bare positional is treated as a script" {
    const args = [_][]const u8{ "file.lisp", "arg" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqualStrings("file.lisp", action.run.script.?);
    try testing.expectEqual(@as(usize, 1), action.run.script_args.len);
    try testing.expectEqualStrings("arg", action.run.script_args[0]);
}

test "-- ends option processing and treats the next arg as a script" {
    const args = [_][]const u8{ "--", "--bogus", "x" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqualStrings("--bogus", action.run.script.?);
    try testing.expectEqual(@as(usize, 1), action.run.script_args.len);
}

test "-- with nothing after it falls through to the repl" {
    const args = [_][]const u8{"--"};
    const action = try parse(&args);
    try testing.expect(action == .repl);
}

test "ops before a script are preserved" {
    const args = [_][]const u8{ "--eval", "(setup)", "main.lisp" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), action.run.ops.len);
    try testing.expectEqualStrings("main.lisp", action.run.script.?);
}

test "ops before -- and a script after are both kept" {
    const args = [_][]const u8{ "--load", "init.lisp", "--", "run.lisp", "a" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), action.run.ops.len);
    try testing.expect(action.run.ops[0] == .load);
    try testing.expectEqualStrings("init.lisp", action.run.ops[0].load);
    try testing.expectEqualStrings("run.lisp", action.run.script.?);
    try testing.expectEqual(@as(usize, 1), action.run.script_args.len);
    try testing.expectEqualStrings("a", action.run.script_args[0]);
}

test "--version wins after ops have been collected and frees them" {
    const args = [_][]const u8{ "--load", "x.lisp", "--version" };
    try testing.expect(try parse(&args) == .print_version);
}

test "--help wins after ops have been collected and frees them" {
    const args = [_][]const u8{ "--eval", "(x)", "-h" };
    try testing.expect(try parse(&args) == .print_help);
}

test "a single dash is treated as a script" {
    const args = [_][]const u8{"-"};
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action == .run);
    try testing.expectEqualStrings("-", action.run.script.?);
    try testing.expectEqual(@as(usize, 0), action.run.script_args.len);
}

test "a bare positional with no trailing args has an empty arg list" {
    const args = [_][]const u8{"solo.lisp"};
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expectEqualStrings("solo.lisp", action.run.script.?);
    try testing.expectEqual(@as(usize, 0), action.run.script_args.len);
}

test "a full combination of flags and ops parses correctly" {
    const args = [_][]const u8{ "--quiet", "--batch", "--eval", "(a)", "--load", "b.lisp" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(action == .run);
    try testing.expect(action.run.quiet);
    try testing.expect(action.run.batch);
    try testing.expect(action.run.script == null);
    try testing.expectEqual(@as(usize, 2), action.run.ops.len);
    try testing.expect(action.run.ops[0] == .eval);
    try testing.expect(action.run.ops[1] == .load);
}

test "--script ends option processing so a later flag is a script arg" {
    const args = [_][]const u8{ "--script", "s.lisp", "--batch" };
    const action = try parse(&args);
    defer action.run.deinit(testing.allocator);
    try testing.expect(!action.run.batch);
    try testing.expectEqualStrings("s.lisp", action.run.script.?);
    try testing.expectEqual(@as(usize, 1), action.run.script_args.len);
    try testing.expectEqualStrings("--batch", action.run.script_args[0]);
}

test "an unknown short option is a user error" {
    const args = [_][]const u8{"-z"};
    const action = try parse(&args);
    try testing.expect(action == .user_error);
    try testing.expectEqualStrings("-z", action.user_error);
}

test "an allocation failure while collecting ops is propagated" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const args = [_][]const u8{ "--eval", "(+ 1 2)" };
    try testing.expectError(error.OutOfMemory, cli.parseArgs(failing.allocator(), &args));
}
