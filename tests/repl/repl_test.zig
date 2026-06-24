const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");

const Harness = struct {
    aw: std.Io.Writer.Allocating,
    repl: *zisp.repl.Repl,

    fn init(allocator: std.mem.Allocator) !*Harness {
        const h = try allocator.create(Harness);
        h.aw = std.Io.Writer.Allocating.init(allocator);
        h.repl = try zisp.repl.Repl.init(allocator, &h.aw.writer);
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
