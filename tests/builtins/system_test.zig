const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Value = value.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    aw: std.Io.Writer.Allocating,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        fx.ev.io = std.testing.io;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        try zisp.builtins.registerSystem(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn evalStr(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        const form = (try rd.read()) orelse return error.NoForm;
        return self.ev.eval(form);
    }

    fn console(self: *Fixture) []const u8 {
        return self.aw.written();
    }

    fn symValue(self: *Fixture, name: []const u8) Value {
        const sym = self.interner.lookup(name).?;
        return symbol_mod.symbol(sym).value_cell;
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- format ---

test "format to console with ~A prints the value unescaped" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~A\" \"hi\")");
    try testing.expectEqualStrings("hi", fx.console());
}

test "format ~S prints readably" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~S\" \"hi\")");
    try testing.expectEqualStrings("\"hi\"", fx.console());
}

test "format ~D prints a decimal integer" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~D\" 42)");
    try testing.expectEqualStrings("42", fx.console());
}

test "format ~% emits a newline and ~~ a tilde" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"a~%b~~c\")");
    try testing.expectEqualStrings("a\nb~c", fx.console());
}

test "format ~& emits a newline" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"x~&y\")");
    try testing.expectEqualStrings("x\ny", fx.console());
}

test "format mixes literal text and several directives" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~A = ~D~%\" 'x 7)");
    try testing.expectEqualStrings("X = 7\n", fx.console());
}

test "format directives are case-insensitive" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~a~d\" 'q 3)");
    try testing.expectEqualStrings("Q3", fx.console());
}

test "format to nil returns a fresh string and writes nothing to console" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const result = try fx.evalStr("(format nil \"~A!\" 99)");
    try testing.expect(result.tag() == .heap and heap_mod.heapType(result) == .string);
    const printed = try heap_mod.stringUtf8Alloc(testing.allocator, result);
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings("99!", printed);
    try testing.expectEqualStrings("", fx.console());
}

test "format writes to the value of *standard-output*" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format *standard-output* \"~D\" 5)");
    try testing.expectEqualStrings("5", fx.console());
}

test "format with too few arguments is a program error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ProgramError, fx.evalStr("(format t \"~A~A\" 1)"));
}

test "format with an unknown directive is a program error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ProgramError, fx.evalStr("(format t \"~Q\")"));
}

test "format with a trailing tilde is a program error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ProgramError, fx.evalStr("(format t \"abc~\")"));
}

test "format ~D on a non-integer prints it as if by ~A" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~D\" \"x\")");
    try testing.expectEqualStrings("x", fx.console());
}

test "format with a non-string control is a type error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.evalStr("(format t 5)"));
}

test "format with too few arguments overall is a wrong-arg-count error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.evalStr("(format t)"));
}

test "format to console errors when no output stream is wired" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    fx.ev.out = null;
    try testing.expectError(error.NoOutputStream, fx.evalStr("(format t \"hi\")"));
}

// --- quit / exit ---

test "quit with no argument sets exit code zero" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.Quit, fx.evalStr("(quit)"));
    try testing.expectEqual(@as(?u8, 0), fx.ev.quit_code);
}

test "quit with a status sets that exit code" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.Quit, fx.evalStr("(quit 7)"));
    try testing.expectEqual(@as(?u8, 7), fx.ev.quit_code);
}

test "exit is an alias for quit" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.Quit, fx.evalStr("(exit 3)"));
    try testing.expectEqual(@as(?u8, 3), fx.ev.quit_code);
}

test "quit with too many arguments is a wrong-arg-count error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.evalStr("(quit 1 2)"));
}

test "quit with a non-integer status is a type error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.evalStr("(quit 'x)"));
}

test "quit with an out-of-range status is a type error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.evalStr("(quit 300)"));
}

test "quit with a negative status is a type error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.evalStr("(quit -1)"));
}

// --- *features* ---

test "features holds zisp and ansi-cl keywords" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const features = fx.symValue("*FEATURES*");
    var saw_zisp = false;
    var saw_ansi = false;
    var cur = features;
    while (cur.isCons()) : (cur = heap_mod.cdr(cur)) {
        const name = symbol_mod.name(heap_mod.car(cur));
        if (std.mem.eql(u8, name, "ZISP")) saw_zisp = true;
        if (std.mem.eql(u8, name, "ANSI-CL")) saw_ansi = true;
    }
    try testing.expect(saw_zisp);
    try testing.expect(saw_ansi);
}

test "the standard streams are bound to console streams" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "*STANDARD-OUTPUT*", "*ERROR-OUTPUT*", "*TRACE-OUTPUT*",
        "*QUERY-IO*",        "*TERMINAL-IO*",  "*DEBUG-IO*",
        "*STANDARD-INPUT*",
    }) |name| {
        try testing.expect(heap_mod.isStream(fx.symValue(name)));
    }
}

// --- load ---

test "load reads and evaluates every form in a file" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "prog.lisp",
        .data = "(setq loaded-a 11) (setq loaded-b (+ loaded-a 1))",
    });

    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/prog.lisp",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(path);

    try zisp.builtins.system.loadPath(&fx.ev, path);
    try testing.expectEqual(@as(i64, 11), fx.symValue("LOADED-A").toFixnum());
    try testing.expectEqual(@as(i64, 12), fx.symValue("LOADED-B").toFixnum());
}

test "load of a missing file is a file error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.FileError, fx.evalStr("(load \"does-not-exist-zzz.lisp\")"));
}

test "load requires a string argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.evalStr("(load 5)"));
}

test "load requires exactly one argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.evalStr("(load)"));
}

test "load returns t on success" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok.lisp", .data = "(setq x 1)" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/ok.lisp", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const string = try fx.heap.allocString(path);
    const load_sym = fx.interner.lookup("LOAD").?;
    const fn_v = symbol_mod.symbol(load_sym).function_cell;
    const result = try fx.ev.callFunction(fn_v, &.{string});
    try testing.expect(result.equalsRaw(value.T));
}

test "loadPath errors when no io is wired" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    fx.ev.io = null;
    try testing.expectError(error.FileError, zisp.builtins.system.loadPath(&fx.ev, "whatever.lisp"));
}

test "evalSource on malformed input is a program error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ProgramError, zisp.builtins.system.evalSource(&fx.ev, "(+ 1"));
}

test "evalSource evaluates each form" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try zisp.builtins.system.evalSource(&fx.ev, "(setq m 3) (setq n (* m m))");
    try testing.expectEqual(@as(i64, 9), fx.symValue("N").toFixnum());
}

// --- pathnames ---

fn namestringOf(fx: *Fixture, src: []const u8) ![]const u8 {
    const v = try fx.evalStr(src);
    return zisp.pathname.namestringOf(fx.arena.allocator(), v);
}

test "#P reads a pathname carrying its namestring" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectEqualStrings("sandbox/", try namestringOf(fx, "#P\"sandbox/\""));
}

test "a pathname prints readably with prin1 and bare with princ" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"~S ~A\" #P\"a/b\" #P\"a/b\")");
    try testing.expectEqualStrings("#P\"a/b\" a/b", fx.console());
}

test "pathname coerces a string and passes a pathname through" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectEqualStrings("x/y", try namestringOf(fx, "(pathname \"x/y\")"));
    try testing.expect((try fx.evalStr("(let ((p #P\"z\")) (eq p (pathname p)))")).equalsRaw(value.T));
}

test "namestring returns the text of either designator" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr("(namestring #P\"a/b\")");
    const a_text = try heap_mod.stringUtf8Alloc(testing.allocator, v);
    defer testing.allocator.free(a_text);
    try testing.expectEqualStrings("a/b", a_text);
    const w = try fx.evalStr("(namestring \"c/d\")");
    const c_text = try heap_mod.stringUtf8Alloc(testing.allocator, w);
    defer testing.allocator.free(c_text);
    try testing.expectEqualStrings("c/d", c_text);
}

test "pathname functions reject non-designators" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.evalStr("(pathname 5)"));
    try testing.expectError(error.TypeError, fx.evalStr("(namestring 5)"));
    try testing.expectError(error.TypeError, fx.evalStr("(truename 5)"));
}

test "pathname functions take exactly one argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.evalStr("(pathname)"));
    try testing.expectError(error.WrongArgCount, fx.evalStr("(namestring)"));
    try testing.expectError(error.WrongArgCount, fx.evalStr("(truename)"));
}

test "truename resolves an existing file to an absolute pathname" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const resolved = try namestringOf(fx, "(truename \"build.zig\")");
    try testing.expect(std.mem.startsWith(u8, resolved, "/"));
    try testing.expect(std.mem.endsWith(u8, resolved, "build.zig"));
}

test "truename on a missing file is a file error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.FileError, fx.evalStr("(truename \"no-such-file-here\")"));
}

test "truename errors when no io is wired" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    fx.ev.io = null;
    try testing.expectError(error.FileError, fx.evalStr("(truename \"build.zig\")"));
}

test "load restores the package the file changed" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const before = fx.interner.currentPackage();
    _ = try fx.evalStr("(load \"vendor/ansi-test/rt-package.lsp\")");
    _ = try fx.evalStr("(load \"tests/lisp/in-package-only.lisp\")");
    try testing.expect(fx.interner.currentPackage() == before);
}

test "probe-file returns the truename of an existing file and nil otherwise" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "here.lisp", .data = "(setq x 1)" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/here.lisp", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const src = try std.fmt.allocPrint(testing.allocator, "(namestring (probe-file \"{s}\"))", .{path});
    defer testing.allocator.free(src);
    const found = try fx.evalStr(src);
    const found_text = try heap_mod.stringUtf8Alloc(testing.allocator, found);
    defer testing.allocator.free(found_text);
    try testing.expect(std.mem.endsWith(u8, found_text, "here.lisp"));

    try testing.expect((try fx.evalStr("(probe-file \"does-not-exist-zzz.lisp\")")).equalsRaw(value.NIL));
}

test "probe-file takes one argument and needs io" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.evalStr("(probe-file)"));
    try testing.expectError(error.TypeError, fx.evalStr("(probe-file 7)"));
    fx.ev.io = null;
    try testing.expectError(error.FileError, fx.evalStr("(probe-file \"x.lisp\")"));
}

test "file-write-date counts seconds from 1900 and so exceeds the 1970 epoch" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dated.lisp", .data = "(setq x 1)" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/dated.lisp", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const src = try std.fmt.allocPrint(testing.allocator, "(file-write-date \"{s}\")", .{path});
    defer testing.allocator.free(src);
    const stamp = try fx.evalStr(src);
    try testing.expect(stamp.toFixnum() > 2208988800);
}

test "file-write-date takes one argument, needs io, and fails on a missing file" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.evalStr("(file-write-date)"));
    try testing.expectError(error.TypeError, fx.evalStr("(file-write-date 7)"));
    try testing.expectError(error.FileError, fx.evalStr("(file-write-date \"does-not-exist-zzz.lisp\")"));
    fx.ev.io = null;
    try testing.expectError(error.FileError, fx.evalStr("(file-write-date \"x.lisp\")"));
}

test "load accepts a pathname as well as a namestring" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "viapath.lisp", .data = "(setq via-pathname 42)" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/viapath.lisp", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const src = try std.fmt.allocPrint(testing.allocator, "(load (pathname \"{s}\"))", .{path});
    defer testing.allocator.free(src);
    _ = try fx.evalStr(src);
    try testing.expectEqual(@as(i64, 42), fx.symValue("VIA-PATHNAME").toFixnum());
}

test "format encodes literal control-string characters back to utf-8" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(format t \"h\xc3\xa9y\")");
    try testing.expectEqualStrings("h\xc3\xa9y", fx.console());
}
