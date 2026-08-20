//! Streams: opening and closing files under the full option matrix, the
//! character and byte operations, and string streams.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    aw: std.Io.Writer.Allocating,
    ev: Evaluator,
    tmp: std.testing.TmpDir,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
            .tmp = std.testing.tmpDir(.{}),
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        fx.ev.io = testing.io;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.tmp.cleanup();
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// A path inside this test's temporary directory.
    fn path(self: *Fixture, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.arena.allocator(),
            ".zig-cache/tmp/{s}/{s}",
            .{ self.tmp.sub_path, name },
        );
    }

    fn writeFile(self: *Fixture, name: []const u8, contents: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = contents });
    }

    fn readFile(self: *Fixture, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, self.arena.allocator(), .unlimited);
    }

    fn evalStr(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| {
            result = try self.ev.eval(form);
        }
        return result;
    }

    /// Evaluate `src` with `{s}` replaced by a path in the temporary
    /// directory, so a test reads as one form.
    fn evalWithPath(self: *Fixture, comptime src: []const u8, name: []const u8) !Value {
        return self.evalStr(try self.fill(src, name));
    }

    /// `src` with its one `{s}` filled in with a temporary path.
    fn fill(self: *Fixture, comptime src: []const u8, name: []const u8) ![]const u8 {
        const file = try self.path(name);
        return std.fmt.allocPrint(self.arena.allocator(), src, .{file});
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectText(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.evalStr(src);
        try testing.expect(heap_mod.isString(v));
        const text = try heap_mod.stringUtf8Alloc(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    fn expectErr(self: *Fixture, err: Error, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- the stream protocol ---

test "the standard streams answer the protocol predicates" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(streamp *standard-output*)");
    try fx.expectNil("(streamp 7)");
    try fx.expectT("(output-stream-p *standard-output*)");
    try fx.expectT("(input-stream-p *standard-input*)");
    try fx.expectT("(open-stream-p *standard-output*)");
    try fx.expectT("(eq (stream-element-type *standard-output*) 'character)");
    try fx.expectErr(Error.WrongArgCount, "(streamp)");
    try fx.expectErr(Error.TypeError, "(input-stream-p 7)");
    try fx.expectErr(Error.TypeError, "(open-stream-p 7)");
    try fx.expectErr(Error.TypeError, "(stream-element-type 7)");
}

test "a stream knows which directions it allows" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(input-stream-p (make-string-input-stream \"a\"))");
    try fx.expectNil("(output-stream-p (make-string-input-stream \"a\"))");
    try fx.expectT("(output-stream-p (make-string-output-stream))");
    try fx.expectNil("(input-stream-p (make-string-output-stream))");
}

test "a binary stream reports its element type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("bin", "AB");
    const v = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :element-type '(unsigned-byte 8)) (stream-element-type s))",
        "bin",
    );
    try testing.expect((try fx.evalStr("(equal '(unsigned-byte 8) '(unsigned-byte 8))")).equalsRaw(value.T));
    try testing.expect(v.isCons());
}

// --- open and close ---

test "with-open-file reads a file and closes the stream" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("in.txt", "hello\nworld\n");
    const v = try fx.evalWithPath(
        "(let ((kept nil)) (with-open-file (s \"{s}\") (setq kept s) (read-line s)) (open-stream-p kept))",
        "in.txt",
    );
    try testing.expect(v.equalsRaw(value.NIL));
}

test "with-open-file closes the stream even when the body fails" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("in.txt", "hello\n");
    const v = try fx.evalWithPath(
        \\(let ((kept nil))
        \\  (ignore-errors
        \\    (with-open-file (s "{s}") (setq kept s) (car 7)))
        \\  (open-stream-p kept))
    , "in.txt");
    try testing.expect(v.equalsRaw(value.NIL));
}

test "opening a missing file for input is an error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.FileError, try fx.fill("(open \"{s}\")", "absent.txt"));
}

test "the four directions each open" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("d.txt", "abc");
    const file = try fx.path("d.txt");
    inline for (.{ ":input", ":output", ":io", ":probe" }) |direction| {
        const src = try std.fmt.allocPrint(
            fx.arena.allocator(),
            "(streamp (open \"" ++ "{s}" ++ "\" :direction " ++ direction ++ " :if-exists :append))",
            .{file},
        );
        try fx.expectT(src);
    }
}

test "a probe stream opens closed" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("p.txt", "abc");
    const v = try fx.evalWithPath("(open-stream-p (open \"{s}\" :direction :probe))", "p.txt");
    try testing.expect(v.equalsRaw(value.NIL));
}

test "close reports whether it had anything to do" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(let ((s (make-string-output-stream))) (close s))");
    try fx.expectNil("(let ((s (make-string-output-stream))) (close s) (close s))");
    try fx.expectErr(Error.TypeError, "(close 7)");
    try fx.expectErr(Error.WrongArgCount, "(close)");
}

// --- the if-exists matrix ---

test "if-exists :supersede and :new-version start from nothing" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    inline for (.{ ":supersede", ":new-version" }) |option| {
        try fx.writeFile("s.txt", "old contents");
        _ = try fx.evalWithPath(
            "(with-open-file (s \"{s}\" :direction :output :if-exists " ++ option ++
                ") (write-string \"new\" s))",
            "s.txt",
        );
        try testing.expectEqualStrings("new", try fx.readFile("s.txt"));
    }
}

test "if-exists :append adds to what is there" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("a.txt", "old");
    _ = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :direction :output :if-exists :append) (write-string \"+new\" s))",
        "a.txt",
    );
    try testing.expectEqualStrings("old+new", try fx.readFile("a.txt"));
}

test "if-exists :overwrite writes over the front and keeps the tail" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("o.txt", "0123456789");
    _ = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :direction :output :if-exists :overwrite) (write-string \"abc\" s))",
        "o.txt",
    );
    try testing.expectEqualStrings("abc3456789", try fx.readFile("o.txt"));
}

test "if-exists :rename moves the old file aside and keeps it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("r.txt", "old");
    _ = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :direction :output :if-exists :rename) (write-string \"new\" s))",
        "r.txt",
    );
    try testing.expectEqualStrings("new", try fx.readFile("r.txt"));
    try testing.expectEqualStrings("old", try fx.readFile("r.txt.bak"));
}

test "if-exists :rename-and-delete removes the renamed file" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("rd.txt", "old");
    _ = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :direction :output :if-exists :rename-and-delete) (write-string \"new\" s))",
        "rd.txt",
    );
    try testing.expectEqualStrings("new", try fx.readFile("rd.txt"));
    try testing.expectError(error.FileNotFound, fx.readFile("rd.txt.bak"));
}

test "if-exists :error signals and nil returns nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("e.txt", "old");
    const file = try fx.path("e.txt");

    _ = file;
    try fx.expectErr(
        Error.FileError,
        try fx.fill("(open \"{s}\" :direction :output :if-exists :error)", "e.txt"),
    );
    try fx.expectNil(try fx.fill("(open \"{s}\" :direction :output :if-exists nil)", "e.txt"));
    try testing.expectEqualStrings("old", try fx.readFile("e.txt"));
}

// --- the if-does-not-exist matrix ---

test "if-does-not-exist :create makes the file" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalWithPath(
        \\(with-open-file (s "{s}" :direction :output :if-does-not-exist :create)
        \\  (write-string "made" s))
    , "c.txt");
    try testing.expectEqualStrings("made", try fx.readFile("c.txt"));
}

test "if-does-not-exist :error signals and nil returns nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.FileError, try fx.fill("(open \"{s}\" :if-does-not-exist :error)", "missing.txt"));
    try fx.expectNil(try fx.fill("(open \"{s}\" :if-does-not-exist nil)", "missing.txt"));
}

test "open rejects a bad option" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.writeFile("x.txt", "a");
    try fx.expectErr(Error.TypeError, try fx.fill("(open \"{s}\" :direction :sideways)", "x.txt"));
    try fx.expectErr(Error.TypeError, try fx.fill("(open \"{s}\" :element-type 'fixnum)", "x.txt"));
    try fx.expectErr(Error.TypeError, try fx.fill("(open \"{s}\" :external-format :ebcdic)", "x.txt"));
    try fx.expectErr(Error.TypeError, try fx.fill("(open \"{s}\" :if-does-not-exist :frob)", "x.txt"));
    try fx.expectErr(Error.ProgramError, try fx.fill("(open \"{s}\" :frob 1)", "x.txt"));
    try fx.expectErr(Error.WrongArgCount, "(open)");
}

// --- element types and external formats ---

test "a byte stream round-trips unsigned bytes" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalWithPath(
        \\(with-open-file (s "{s}" :direction :output :element-type '(unsigned-byte 8))
        \\  (write-byte 65 s) (write-byte 255 s))
    , "b.bin");
    const v = try fx.evalWithPath(
        \\(with-open-file (s "{s}" :element-type '(unsigned-byte 8))
        \\  (list (read-byte s) (read-byte s) (read-byte s nil :eof)))
    , "b.bin");
    try testing.expect((try fx.evalStr("t")).equalsRaw(value.T));
    try testing.expect(v.isCons());
    try testing.expectEqual(@as(i64, 65), heap_mod.car(v).toFixnum());
}

test "a signed sixteen-bit stream round-trips negative values" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalWithPath(
        \\(with-open-file (s "{s}" :direction :output :element-type '(signed-byte 16))
        \\  (write-byte -2 s) (write-byte 300 s))
    , "s16.bin");
    const v = try fx.evalWithPath(
        \\(with-open-file (s "{s}" :element-type '(signed-byte 16))
        \\  (and (= (read-byte s) -2) (= (read-byte s) 300)))
    , "s16.bin");
    try testing.expect(v.equalsRaw(value.T));
}

test "write-byte checks its value against the element type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(write-byte 256 (make-string-output-stream))");
    try fx.expectErr(Error.TypeError, "(write-byte -1 (make-string-output-stream))");
    try fx.expectErr(Error.TypeError, "(write-byte 'x (make-string-output-stream))");
    try fx.expectErr(Error.WrongArgCount, "(write-byte 1)");
    try fx.expectErr(Error.WrongArgCount, "(read-byte)");
    try fx.expectErr(Error.TypeError, "(read-byte 7)");
}

test "a utf-8 stream round-trips characters past latin-1" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :direction :output) (write-string \"\xe6\x97\xa5\xe6\x9c\xac\" s))",
        "u.txt",
    );
    try testing.expectEqualStrings("\xe6\x97\xa5\xe6\x9c\xac", try fx.readFile("u.txt"));
    const v = try fx.evalWithPath(
        "(with-open-file (s \"{s}\") (char-code (read-char s)))",
        "u.txt",
    );
    try testing.expectEqual(@as(i64, 0x65E5), v.toFixnum());
}

test "a latin-1 stream writes one byte a character" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :direction :output :external-format :latin-1) (write-char #\\U+00E9 s))",
        "l.txt",
    );
    try testing.expectEqualStrings("\xe9", try fx.readFile("l.txt"));
    const v = try fx.evalWithPath(
        "(with-open-file (s \"{s}\" :external-format :latin-1) (char-code (read-char s)))",
        "l.txt",
    );
    try testing.expectEqual(@as(i64, 0xE9), v.toFixnum());
}

test "a character past latin-1 will not fit a latin-1 stream" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, try fx.fill(
        "(with-open-file (s \"{s}\" :direction :output :external-format :latin-1) (write-char #\\U+65E5 s))",
        "wide.txt",
    ));
}

// --- characters ---

test "read-char, peek-char and unread-char walk a stream" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(with-input-from-string (s "abc")
        \\  (and (char= (read-char s) #\a)
        \\       (char= (peek-char nil s) #\b)
        \\       (char= (read-char s) #\b)
        \\       (progn (unread-char #\b s) (char= (read-char s) #\b))
        \\       (char= (read-char s) #\c)))
    );
}

test "peek-char with t skips whitespace" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(with-input-from-string (s \"   x\") (char= (peek-char t s) #\\x))");
}

test "reading past the end signals or returns the eof value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.FileError, "(with-input-from-string (s \"\") (read-char s))");
    try fx.expectT("(with-input-from-string (s \"\") (eq (read-char s nil :done) :done))");
    try fx.expectT("(with-input-from-string (s \"\") (eq (peek-char nil s nil :done) :done))");
    try fx.expectErr(Error.FileError, "(with-input-from-string (s \"\") (peek-char nil s))");
}

test "the character operations check their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(write-char 7)");
    try fx.expectErr(Error.WrongArgCount, "(write-char)");
    try fx.expectErr(Error.TypeError, "(unread-char 7)");
    try fx.expectErr(Error.WrongArgCount, "(unread-char)");
    try fx.expectErr(Error.TypeError, "(peek-char 7 (make-string-input-stream \"a\"))");
    try fx.expectErr(Error.TypeError, "(read-char 7)");
    try fx.expectErr(
        Error.ControlError,
        "(with-input-from-string (s \"ab\") (read-char s) (unread-char #\\a s) (unread-char #\\a s))",
    );
}

test "writing to a stream that only reads is a type error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(write-char #\\a (make-string-input-stream \"x\"))");
    try fx.expectErr(Error.TypeError, "(read-char (make-string-output-stream))");
}

test "using a closed stream is an error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(
        Error.FileError,
        "(let ((s (make-string-input-stream \"a\"))) (close s) (read-char s))",
    );
}

// --- lines and strings ---

test "read-line returns each line and says when the last had no newline" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(with-input-from-string (s \"one\ntwo\") (read-line s))", "one");
    try fx.expectNil("(with-input-from-string (s \"one\ntwo\") (nth-value 1 (read-line s)))");
    try fx.expectT(
        "(with-input-from-string (s \"one\ntwo\") (read-line s) (nth-value 1 (read-line s)))",
    );
    try fx.expectT("(with-input-from-string (s \"\") (eq (read-line s nil :done) :done))");
}

test "write-string and write-line put text on a stream" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(with-output-to-string (s) (write-string \"ab\" s))", "ab");
    try fx.expectText("(with-output-to-string (s) (write-line \"ab\" s))", "ab\n");
    try fx.expectText("(with-output-to-string (s) (write-char #\\a s) (write-char #\\b s))", "ab");
    try fx.expectErr(Error.TypeError, "(write-string 7 (make-string-output-stream))");
    try fx.expectErr(Error.WrongArgCount, "(write-string)");
}

// --- string streams ---

test "a string output stream hands over what was written and forgets it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((s (make-string-output-stream)))
        \\  (write-string "ab" s)
        \\  (and (string= (get-output-stream-string s) "ab")
        \\       (string= (get-output-stream-string s) "")))
    );
    try fx.expectErr(Error.TypeError, "(get-output-stream-string 7)");
    try fx.expectErr(Error.WrongArgCount, "(get-output-stream-string)");
    try fx.expectErr(Error.TypeError, "(make-string-input-stream 7)");
    try fx.expectErr(Error.WrongArgCount, "(make-string-input-stream)");
}

test "format writes to a stream as well as to a string" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectText("(with-output-to-string (s) (format s \"~A-~A\" 1 2))", "1-2");
    try fx.expectText("(format nil \"~A\" 7)", "7");
    _ = try fx.evalStr("(format t \"to console\")");
    try testing.expectEqualStrings("to console", fx.aw.written());
}

test "the output-forcing operations accept a stream and do nothing" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(force-output)");
    try fx.expectNil("(finish-output *standard-output*)");
    try fx.expectNil("(clear-output)");
    try fx.expectErr(Error.WrongArgCount, "(force-output 1 2)");
    try fx.expectErr(Error.TypeError, "(force-output 7)");
}
