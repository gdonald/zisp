//! Scripted debugger sessions.
//!
//! Each `tests/lisp/debugger-<name>.lisp` is input a person could type at
//! the REPL, and the REPL's output for it has to match
//! `tests/lisp/debugger-<name>.expected` byte for byte.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");

fn expectSession(input: []const u8, expected: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const repl = try zisp.repl.Repl.init(testing.allocator, &aw.writer, std.testing.io);
    defer repl.deinit();
    try repl.run(input);
    try testing.expectEqualStrings(expected, aw.written());
}

test "the banner reports the condition and lists its restarts" {
    try expectSession(@embedFile("../lisp/debugger-banner.lisp"), @embedFile("../lisp/debugger-banner.expected"));
}

test "an integer invokes the restart listed under it" {
    try expectSession(@embedFile("../lisp/debugger-restart-index.lisp"), @embedFile("../lisp/debugger-restart-index.expected"));
}

test "a form is evaluated where the condition was signaled" {
    try expectSession(@embedFile("../lisp/debugger-broken-environment.lisp"), @embedFile("../lisp/debugger-broken-environment.expected"));
}

test "a failure in a typed form opens a debugger one level in" {
    try expectSession(@embedFile("../lisp/debugger-nested.lisp"), @embedFile("../lisp/debugger-nested.expected"));
}

test "a restart is selected by name and asks for its arguments" {
    try expectSession(@embedFile("../lisp/debugger-restart-name.lisp"), @embedFile("../lisp/debugger-restart-name.expected"));
}

test "the top-level abort restart returns to the REPL" {
    try expectSession(@embedFile("../lisp/debugger-top-level-abort.lisp"), @embedFile("../lisp/debugger-top-level-abort.expected"));
}

test "with no restarts the debugger evaluates forms until the input ends" {
    try expectSession(@embedFile("../lisp/debugger-no-restarts.lisp"), @embedFile("../lisp/debugger-no-restarts.expected"));
}

test "break continues with nil and bypasses handlers" {
    try expectSession(@embedFile("../lisp/debugger-break.lisp"), @embedFile("../lisp/debugger-break.expected"));
}
