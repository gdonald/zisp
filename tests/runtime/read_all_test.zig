//! ROADMAP Phase 1.5.3 helper coverage.
//!
//! Drives `zisp.read_all.parseAll` against synthetic sources. The
//! `--read-only` CLI flag wraps this helper with file I/O; here we test
//! the pure parsing path so coverage doesn't drop when the executable
//! adds the I/O wrapper.

const std = @import("std");
const zisp = @import("zisp");

test "1.5.3 parseAll counts forms in a clean source" {
    const a = std.testing.allocator;
    const outcome = try zisp.read_all.parseAll(a, "1 2 3 (a b)", "test");
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(u32, 4), outcome.ok);
}

test "1.5.3 parseAll handles empty source" {
    const a = std.testing.allocator;
    const outcome = try zisp.read_all.parseAll(a, "", "test");
    try std.testing.expectEqual(@as(u32, 0), outcome.ok);
}

test "1.5.3 parseAll reports first failure with position" {
    const a = std.testing.allocator;
    // Two valid forms, then unbalanced rparen on a fresh line.
    const outcome = try zisp.read_all.parseAll(a, "1 2\n)", "src.lisp");
    try std.testing.expect(outcome == .fail);
    const info = outcome.fail;
    try std.testing.expectEqual(@as(u32, 2), info.forms);
    try std.testing.expectEqual(@as(u32, 2), info.pos.line);
    try std.testing.expectEqual(@as(u32, 1), info.pos.column);
    try std.testing.expectEqualStrings("src.lisp", info.pos.file);
}

test "1.5.3 parseAll fail position propagates from deep error site" {
    const a = std.testing.allocator;
    const outcome = try zisp.read_all.parseAll(a, "(1 . 2 3)", "f");
    try std.testing.expect(outcome == .fail);
    try std.testing.expectEqual(@as(u32, 0), outcome.fail.forms);
}
