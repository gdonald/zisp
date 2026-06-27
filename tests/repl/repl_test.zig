const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");

const Harness = struct {
    aw: std.Io.Writer.Allocating,
    repl: *zisp.repl.Repl,

    fn init(allocator: std.mem.Allocator) !*Harness {
        const h = try allocator.create(Harness);
        h.aw = std.Io.Writer.Allocating.init(allocator);
        h.repl = try zisp.repl.Repl.init(allocator, &h.aw.writer, std.testing.io);
        return h;
    }

    fn deinit(self: *Harness, allocator: std.mem.Allocator) void {
        self.repl.deinit();
        self.aw.deinit();
        allocator.destroy(self);
    }

    fn run(self: *Harness, source: []const u8) !void {
        try self.repl.run(source);
    }

    fn output(self: *Harness) []const u8 {
        return self.aw.written();
    }
};

fn newHarness() !*Harness {
    return Harness.init(testing.allocator);
}

test "evaluates a single form and prints the value" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1 2)");
    try testing.expectEqualStrings("3\n", h.output());
}

test "evaluates several forms in sequence" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1 2) (* 3 4) (list 1 2)");
    try testing.expectEqualStrings("3\n12\n(1 2)\n", h.output());
}

test "empty input produces no output" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("   ");
    try testing.expectEqualStrings("", h.output());
}

test "state persists across run calls" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1 1)");
    try h.run("+");
    try testing.expectEqualStrings("2\n(+ 1 1)\n", h.output());
}

test "plus holds the last evaluated form" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(list 1) (list 2) +");
    try testing.expectEqualStrings("(1)\n(2)\n(LIST 2)\n", h.output());
}

test "plus-plus holds the second-to-last form" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(list 1) (list 2) (list 3) ++");
    try testing.expectEqualStrings("(1)\n(2)\n(3)\n(LIST 2)\n", h.output());
}

test "plus-plus-plus holds the third-to-last form" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(list 1) (list 2) (list 3) (list 4) +++");
    try testing.expectEqualStrings("(1)\n(2)\n(3)\n(4)\n(LIST 2)\n", h.output());
}

test "star holds the last result" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(list 1) (list 2) *");
    try testing.expectEqualStrings("(1)\n(2)\n(2)\n", h.output());
}

test "star-star holds the second-to-last result" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(list 1) (list 2) (list 3) **");
    try testing.expectEqualStrings("(1)\n(2)\n(3)\n(2)\n", h.output());
}

test "star-star-star holds the third-to-last result" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(list 1) (list 2) (list 3) (list 4) ***");
    try testing.expectEqualStrings("(1)\n(2)\n(3)\n(4)\n(2)\n", h.output());
}

test "evaluation error enters break loop and aborts" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) :abort (+ 1 2)");
    try testing.expectEqualStrings(
        ";; Error: TypeError\n" ++
            ";; Entering break loop. :abort or :continue to resume.\n" ++
            ";; Resuming top level.\n" ++
            "3\n",
        h.output(),
    );
}

test "break loop resumes on continue" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) :continue");
    try testing.expectEqualStrings(
        ";; Error: TypeError\n" ++
            ";; Entering break loop. :abort or :continue to resume.\n" ++
            ";; Resuming top level.\n",
        h.output(),
    );
}

test "break loop evaluates forms then resumes at end of input" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (+ 10 20)");
    try testing.expectEqualStrings(
        ";; Error: TypeError\n" ++
            ";; Entering break loop. :abort or :continue to resume.\n" ++
            "30\n",
        h.output(),
    );
}

test "break loop reports nested errors and keeps reading" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (cdr 6) :abort");
    try testing.expectEqualStrings(
        ";; Error: TypeError\n" ++
            ";; Entering break loop. :abort or :continue to resume.\n" ++
            ";; Error: TypeError\n" ++
            ";; Resuming top level.\n",
        h.output(),
    );
}

test "break loop ignores non-resume symbols and evaluates them" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) :foo :abort");
    try testing.expectEqualStrings(
        ";; Error: TypeError\n" ++
            ";; Entering break loop. :abort or :continue to resume.\n" ++
            ":FOO\n" ++
            ";; Resuming top level.\n",
        h.output(),
    );
}

test "reader error at top level is reported" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1");
    try testing.expect(std.mem.startsWith(u8, h.output(), ";; Reader:"));
}

test "reader error inside break loop is reported" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (+ 1");
    const out = h.output();
    try testing.expect(std.mem.indexOf(u8, out, ";; Entering break loop") != null);
    try testing.expect(std.mem.indexOf(u8, out, ";; Reader:") != null);
}

test "quit at top level stops the loop without entering a break loop" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1 2) (quit 5) (+ 9 9)");
    try testing.expectEqualStrings("3\n", h.output());
    try testing.expectEqual(@as(?u8, 5), h.repl.ev.quit_code);
}

test "quit inside a break loop stops the loop" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (quit 2) (+ 1 1)");
    try testing.expectEqual(@as(?u8, 2), h.repl.ev.quit_code);
    try testing.expect(std.mem.indexOf(u8, h.output(), "Entering break loop") != null);
    try testing.expect(std.mem.indexOf(u8, h.output(), "1\n") == null);
}

test "evalForms with print echoes each value" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.repl.evalForms("(+ 1 2) (* 2 3)", true);
    try testing.expectEqualStrings("3\n6\n", h.output());
}

test "evalForms without print is silent but still evaluates" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.repl.evalForms("(setq saved 42)", false);
    try testing.expectEqualStrings("", h.output());
    try h.repl.evalForms("saved", true);
    try testing.expectEqualStrings("42\n", h.output());
}

test "evalForms propagates an evaluation error instead of a break loop" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try testing.expectError(error.TypeError, h.repl.evalForms("(car 5)", true));
}

test "evalForms propagates a reader error as a program error" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try testing.expectError(error.ProgramError, h.repl.evalForms("(+ 1", false));
}

test "quit with no status at top level sets exit code zero" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(quit)");
    try testing.expectEqual(@as(?u8, 0), h.repl.ev.quit_code);
    try testing.expectEqualStrings("", h.output());
}

test "quit in a break loop with no trailing form ends without a resume message" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (quit 4)");
    try testing.expectEqual(@as(?u8, 4), h.repl.ev.quit_code);
    const out = h.output();
    try testing.expect(std.mem.indexOf(u8, out, "Entering break loop") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Resuming top level") == null);
}

test "evalForms on empty input does nothing" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.repl.evalForms("", true);
    try testing.expectEqualStrings("", h.output());
}

test "evalForms on whitespace only does nothing" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.repl.evalForms("   \n  ", false);
    try testing.expectEqualStrings("", h.output());
}

test "loadFile reads and evaluates a file" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "r.lisp", .data = "(setq from-file 8)" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/r.lisp", .{tmp.sub_path});
    defer testing.allocator.free(path);

    try h.repl.loadFile(path);
    try h.repl.evalForms("from-file", true);
    try testing.expectEqualStrings("8\n", h.output());
}

test "loadFile on a missing file is a file error" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try testing.expectError(error.FileError, h.repl.loadFile("no-such-file-zzz.lisp"));
}

test "init frees the repl when a later allocation fails" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    // The Repl object allocates first; failing the next allocation drives the
    // errdefer that destroys it.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, zisp.repl.Repl.init(failing.allocator(), &aw.writer, null));
}
