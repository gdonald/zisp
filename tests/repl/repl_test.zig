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

const TYPE_ERROR_BANNER =
    ";; Debugger entered on TYPE-ERROR:\n" ++
    ";;   An argument is not of the type the function needs.\n" ++
    ";; Restarts:\n" ++
    ";;   0: [ABORT] Return to the top level.\n";

test "an evaluation error enters the debugger and restart 0 aborts" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) 0 (+ 1 2)");
    try testing.expectEqualStrings(TYPE_ERROR_BANNER ++ "Debug> ;; Aborted.\n3\n", h.output());
}

test "the debugger evaluates forms and aborts at the end of the input" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (+ 10 20)");
    try testing.expectEqualStrings(TYPE_ERROR_BANNER ++ "Debug> 30\nDebug> ;; Aborted.\n", h.output());
}

test "a failure in a debugger form enters a debugger one level in" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (cdr 6) 0 0");
    try testing.expectEqualStrings(
        TYPE_ERROR_BANNER ++ "Debug> " ++
            ";; Debugger entered on TYPE-ERROR:\n" ++
            ";;   An argument is not of the type the function needs.\n" ++
            ";; Restarts:\n" ++
            ";;   0: [ABORT] Return to debug level 1.\n" ++
            ";;   1: [ABORT] Return to the top level.\n" ++
            "Debug[2]> Debug> ;; Aborted.\n",
        h.output(),
    );
}

test "the debugger names a restart number or name it does not have" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) 7 :r nothing :r abort (+ 3 3)");
    try testing.expectEqualStrings(
        TYPE_ERROR_BANNER ++ "Debug> ;; No restart numbered 7.\n" ++
            "Debug> ;; No restart named NOTHING.\n" ++
            "Debug> ;; Aborted.\n6\n",
        h.output(),
    );
}

test "reader error at top level is reported" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1");
    try testing.expect(std.mem.startsWith(u8, h.output(), ";; Reader:"));
}

test "input that does not read leaves the debugger" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (+ 1");
    try testing.expectEqualStrings(
        TYPE_ERROR_BANNER ++ "Debug> \n;; The input does not read.\n;; Aborted.\n",
        h.output(),
    );
}

test "quit at top level stops the loop without entering the debugger" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(+ 1 2) (quit 5) (+ 9 9)");
    try testing.expectEqualStrings("3\n", h.output());
    try testing.expectEqual(@as(?u8, 5), h.repl.ev.quit_code);
}

test "quit inside the debugger stops the loop" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 5) (quit 2) (+ 1 1)");
    try testing.expectEqual(@as(?u8, 2), h.repl.ev.quit_code);
    try testing.expectEqualStrings(TYPE_ERROR_BANNER ++ "Debug> ", h.output());
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

test "evalForms propagates an evaluation error instead of entering the debugger" {
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

test "abort at top level returns to the prompt without entering the debugger" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(progn (abort) 1) (+ 1 2)");
    try testing.expectEqualStrings(";; Aborted.\n3\n", h.output());
}

test "the top level offers an abort restart" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(mapcar #'restart-name (compute-restarts))");
    try testing.expectEqualStrings("(ABORT)\n", h.output());
}

test "abort inside the debugger returns to the debugger" {
    const h = try newHarness();
    defer h.deinit(testing.allocator);
    try h.run("(car 1) (abort) (+ 2 2)");
    try testing.expectEqualStrings(TYPE_ERROR_BANNER ++ "Debug> Debug> 4\nDebug> ;; Aborted.\n", h.output());
}
