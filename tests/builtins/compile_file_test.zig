//! eval-when semantics and compile-file top-level processing.
//!
//! Covers the CLHS 3.2.3.1 rules: single situations and all seven non-empty
//! situation subsets at top level and inside top-level progn, runtime
//! (non-top-level) eval-when, deprecated situation names, and the 21-cell
//! corpus diffed byte-for-byte against SBCL's compile-file + load output.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

const corpus_text = @embedFile("../lisp/eval-when-corpus.lisp");
const corpus_expected = @embedFile("../lisp/eval-when-corpus.expected");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    aw: std.Io.Writer.Allocating,
    warn_aw: std.Io.Writer.Allocating,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .warn_aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        fx.ev.warn_out = &fx.warn_aw.writer;
        fx.ev.io = std.testing.io;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        try zisp.builtins.registerSystem(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.warn_aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
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

    /// Minimal-compile `source`, then evaluate the collected load forms.
    /// Returns the console output with phase markers, matching the shape of
    /// the SBCL golden file.
    fn compileAndLoad(self: *Fixture, allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
        var load_forms: std.ArrayList(Value) = .empty;
        defer load_forms.deinit(allocator);

        try self.aw.writer.print("== COMPILE ==\n", .{});
        try zisp.builtins.system.compileSource(&self.ev, source, &load_forms);
        try self.aw.writer.print("== LOAD ==\n", .{});
        for (load_forms.items) |f| {
            _ = try self.ev.eval(f);
        }
        return self.aw.written();
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- single situations at top level ---

test "top-level eval-when with :compile-toplevel runs at compile time only" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const out = try fx.compileAndLoad(testing.allocator,
        \\(eval-when (:compile-toplevel) (format t "m~%"))
    );
    try testing.expectEqualStrings("== COMPILE ==\nm\n== LOAD ==\n", out);
}

test "top-level eval-when with :load-toplevel runs at load time only" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const out = try fx.compileAndLoad(testing.allocator,
        \\(eval-when (:load-toplevel) (format t "m~%"))
    );
    try testing.expectEqualStrings("== COMPILE ==\n== LOAD ==\nm\n", out);
}

test "top-level eval-when with :execute alone is discarded by compile-file" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const out = try fx.compileAndLoad(testing.allocator,
        \\(eval-when (:execute) (format t "m~%"))
    );
    try testing.expectEqualStrings("== COMPILE ==\n== LOAD ==\n", out);
}

// --- all seven non-empty subsets, top level and inside progn ---

const Subset = struct {
    situations: []const u8,
    compile_marker: bool,
    load_marker: bool,
};

const subsets = [_]Subset{
    .{ .situations = ":compile-toplevel", .compile_marker = true, .load_marker = false },
    .{ .situations = ":load-toplevel", .compile_marker = false, .load_marker = true },
    .{ .situations = ":execute", .compile_marker = false, .load_marker = false },
    .{ .situations = ":compile-toplevel :load-toplevel", .compile_marker = true, .load_marker = true },
    .{ .situations = ":compile-toplevel :execute", .compile_marker = true, .load_marker = false },
    .{ .situations = ":load-toplevel :execute", .compile_marker = false, .load_marker = true },
    .{ .situations = ":compile-toplevel :load-toplevel :execute", .compile_marker = true, .load_marker = true },
};

fn checkSubset(sub: Subset, wrap_in_progn: bool) !void {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    const source = if (wrap_in_progn)
        try std.fmt.allocPrint(testing.allocator,
            \\(progn (eval-when ({s}) (format t "m~%")))
        , .{sub.situations})
    else
        try std.fmt.allocPrint(testing.allocator,
            \\(eval-when ({s}) (format t "m~%"))
        , .{sub.situations});
    defer testing.allocator.free(source);

    const expected = try std.fmt.allocPrint(testing.allocator, "== COMPILE ==\n{s}== LOAD ==\n{s}", .{
        if (sub.compile_marker) "m\n" else "",
        if (sub.load_marker) "m\n" else "",
    });
    defer testing.allocator.free(expected);

    const out = try fx.compileAndLoad(testing.allocator, source);
    try testing.expectEqualStrings(expected, out);
}

test "all seven situation subsets at top level" {
    for (subsets) |sub| {
        try checkSubset(sub, false);
    }
}

test "all seven situation subsets inside a top-level progn" {
    for (subsets) |sub| {
        try checkSubset(sub, true);
    }
}

// --- non-top-level eval-when: only :execute applies ---

test "non-top-level eval-when evaluates the body only for :execute" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    const a = try fx.evalStr("(let () (eval-when (:execute) 5))");
    try testing.expectEqual(@as(i64, 5), a.toFixnum());
    const b = try fx.evalStr("(let () (eval-when (:compile-toplevel) 5))");
    try testing.expect(b.equalsRaw(value.NIL));
    const c = try fx.evalStr("(let () (eval-when (:load-toplevel) 5))");
    try testing.expect(c.equalsRaw(value.NIL));
    const d = try fx.evalStr("(let () (eval-when (:compile-toplevel :load-toplevel) 5))");
    try testing.expect(d.equalsRaw(value.NIL));
}

test "eval-when rejects an unknown situation" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.ProgramError, fx.evalStr("(eval-when (:sometime) 5)"));
}

// --- deprecated situation names ---

test "deprecated eval-when situations map to modern ones with a warning" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    const a = try fx.evalStr("(eval-when (eval) 5)");
    try testing.expectEqual(@as(i64, 5), a.toFixnum());
    const b = try fx.evalStr("(eval-when (compile) 5)");
    try testing.expect(b.equalsRaw(value.NIL));
    const c = try fx.evalStr("(eval-when (load) 5)");
    try testing.expect(c.equalsRaw(value.NIL));

    const warnings = fx.warn_aw.written();
    try testing.expect(std.mem.count(u8, warnings, "deprecated EVAL-WHEN situation") == 3);
    try testing.expect(std.mem.indexOf(u8, warnings, ":EXECUTE") != null);
    try testing.expect(std.mem.indexOf(u8, warnings, ":COMPILE-TOPLEVEL") != null);
    try testing.expect(std.mem.indexOf(u8, warnings, ":LOAD-TOPLEVEL") != null);
}

test "deprecated situations work in compile-file processing" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const out = try fx.compileAndLoad(testing.allocator,
        \\(eval-when (compile) (format t "c~%"))
        \\(eval-when (load) (format t "l~%"))
    );
    try testing.expectEqualStrings("== COMPILE ==\nc\n== LOAD ==\nl\n", out);
}

// --- the 21-cell state-table corpus, diffed against SBCL ---

test "eval-when corpus output matches SBCL byte for byte" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const out = try fx.compileAndLoad(testing.allocator, corpus_text);
    try testing.expectEqualStrings(corpus_expected, out);
}

// --- defmacro is available at compile time ---

test "compile-file evaluates defmacro at compile time and keeps it for load" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const out = try fx.compileAndLoad(testing.allocator,
        \\(defmacro em (x) `(format t "~a~%" ,x))
        \\(eval-when (:compile-toplevel) (em "compile"))
        \\(eval-when (:load-toplevel) (em "load"))
    );
    try testing.expectEqualStrings("== COMPILE ==\ncompile\n== LOAD ==\nload\n", out);
}

// --- compile-file builtin and pathname variables ---

test "compile-file writes a loadable fasl and binds the pathname variables" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cf.lisp",
        .data =
        \\(eval-when (:compile-toplevel)
        \\  (setq seen-compile-pathname *compile-file-pathname*)
        \\  (setq seen-compile-truename *compile-file-truename*))
        \\(setq seen-load-pathname *load-pathname*)
        \\(setq loaded-marker 99)
        ,
    });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/cf.lisp", .{tmp.sub_path});
    defer testing.allocator.free(path);

    // Compile: returns the fasl path, binds *compile-file-pathname*.
    const src_form = try std.fmt.allocPrint(testing.allocator, "(compile-file \"{s}\")", .{path});
    defer testing.allocator.free(src_form);
    const fasl_v = try fx.evalStr(src_form);
    try testing.expect(fasl_v.tag() == .heap and heap_mod.heapType(fasl_v) == .string);
    const fasl_path = heap_mod.asString(fasl_v).constSlice();
    try testing.expect(std.mem.endsWith(u8, fasl_path, "cf.zfasl"));

    // The compile-time capture saw the namestrings; outside they are nil.
    const seen_p = heap_mod.asString(try fx.evalStr("seen-compile-pathname")).constSlice();
    try testing.expectEqualStrings(path, seen_p);
    const seen_t = heap_mod.asString(try fx.evalStr("seen-compile-truename")).constSlice();
    try testing.expect(std.mem.endsWith(u8, seen_t, "/cf.lisp"));
    try testing.expect(seen_t.len > 0 and seen_t[0] == '/');
    try testing.expect((try fx.evalStr("*compile-file-pathname*")).equalsRaw(value.NIL));
    try testing.expect((try fx.evalStr("*compile-file-truename*")).equalsRaw(value.NIL));

    // Load the fasl: load-time forms run, *load-pathname* was bound.
    const load_form = try std.fmt.allocPrint(testing.allocator, "(load \"{s}\")", .{fasl_path});
    defer testing.allocator.free(load_form);
    _ = try fx.evalStr(load_form);
    const marker = try fx.evalStr("loaded-marker");
    try testing.expectEqual(@as(i64, 99), marker.toFixnum());
    const seen_lp = heap_mod.asString(try fx.evalStr("seen-load-pathname")).constSlice();
    try testing.expectEqualStrings(fasl_path, seen_lp);
    try testing.expect((try fx.evalStr("*load-pathname*")).equalsRaw(value.NIL));
    try testing.expect((try fx.evalStr("*load-truename*")).equalsRaw(value.NIL));
}

test "compile-file argument errors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    try testing.expectError(Error.WrongArgCount, fx.evalStr("(compile-file)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(compile-file 5)"));
    try testing.expectError(Error.FileError, fx.evalStr("(compile-file \"no-such-file.lisp\")"));
}
