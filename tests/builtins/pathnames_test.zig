//! Pathname components: parsing a namestring into directory / name / type,
//! and rebuilding one with make-pathname and merge-pathnames.

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
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
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

    /// The namestring of whatever `src` evaluates to, as raw text.
    fn expectNamestring(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const wrapped = try std.fmt.allocPrint(testing.allocator, "(namestring {s})", .{src});
        defer testing.allocator.free(wrapped);
        const v = try self.evalStr(wrapped);
        const text = try heap_mod.stringUtf8Alloc(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    fn expectPrinted(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.evalStr(src);
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try zisp.printer.write(testing.allocator, &aw.writer, v, .{ .escape = true });
        try testing.expectEqualStrings(expected, aw.written());
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectError(self: *Fixture, src: []const u8, expected: Error) !void {
        try testing.expectError(expected, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

// --- component readers ---

test "pathnamep distinguishes a pathname from its namestring" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(pathnamep (pathname \"/a/b.lsp\"))");
    try fx.expectNil("(pathnamep \"/a/b.lsp\")");
}

test "pathname-directory of an absolute namestring lists the components" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrinted("(pathname-directory \"/usr/share/x.lsp\")", "(:ABSOLUTE \"usr\" \"share\")");
}

test "pathname-directory of a relative namestring is tagged :relative" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrinted("(pathname-directory \"aux/x.lsp\")", "(:RELATIVE \"aux\")");
}

test "pathname-directory is nil when the namestring names no directory" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(pathname-directory \"x.lsp\")");
}

test "pathname-directory maps a parent segment to :up and drops a bare dot" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrinted("(pathname-directory \"../././a/x\")", "(:RELATIVE :UP \"a\")");
    try fx.expectPrinted("(pathname-directory \"./a/x\")", "(:RELATIVE \"a\")");
}

test "pathname-directory collapses repeated separators" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrinted("(pathname-directory \"/a//b/x\")", "(:ABSOLUTE \"a\" \"b\")");
}

test "pathname-name and pathname-type split at the last dot" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(pathname-name \"/a/rt.tar.lsp\")", "rt.tar");
    try fx.expectNamestring("(pathname-type \"/a/rt.tar.lsp\")", "lsp");
}

test "a leading dot belongs to the name, leaving no type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(pathname-name \"/a/.emacs\")", ".emacs");
    try fx.expectNil("(pathname-type \"/a/.emacs\")");
}

test "a namestring ending in a separator has neither name nor type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(pathname-name \"/a/b/\")");
    try fx.expectNil("(pathname-type \"/a/b/\")");
}

test "components read through a pathname object as well as a namestring" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(pathname-name (pathname \"/a/b.lsp\"))", "b");
}

test "host, device and version start out nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(pathname-host \"/a/b.lsp\")");
    try fx.expectNil("(pathname-device \"/a/b.lsp\")");
    try fx.expectNil("(pathname-version \"/a/b.lsp\")");
}

test "a non-designator is a type error to every component reader" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "(pathname-directory 7)",
        "(pathname-name 7)",
        "(pathname-type 7)",
        "(pathname-host 7)",
    }) |src| {
        try fx.expectError(src, Error.TypeError);
    }
}

test "component readers take exactly one argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "(pathnamep)",
        "(pathname-directory)",
        "(pathname-name)",
        "(pathname-type)",
        "(pathname-version)",
        "(compile-file-pathname)",
    }) |src| {
        try fx.expectError(src, Error.WrongArgCount);
    }
}

// --- make-pathname ---

test "make-pathname builds a namestring from directory, name and type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring(
        "(make-pathname :directory '(:absolute \"a\" \"b\") :name \"c\" :type \"lsp\")",
        "/a/b/c.lsp",
    );
}

test "make-pathname renders a relative directory without a leading separator" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(make-pathname :directory '(:relative \"a\") :name \"c\")", "a/c");
}

test "make-pathname renders :up and :back as a parent segment" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(make-pathname :directory '(:relative :up :back))", "../../");
}

test "make-pathname with no components yields an empty namestring" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(make-pathname)", "");
}

test "make-pathname fills unsupplied components from :defaults" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(make-pathname :type \"o\" :defaults \"/a/b/c.lsp\")", "/a/b/c.o");
}

test "make-pathname ignores the host, device, version and case keywords" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring(
        "(make-pathname :host nil :device nil :version :newest :case :common :name \"c\")",
        "c",
    );
}

test "make-pathname rejects an unknown keyword and an odd argument list" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectError("(make-pathname :bogus 1)", Error.ProgramError);
    try fx.expectError("(make-pathname 7 8)", Error.ProgramError);
    try fx.expectError("(make-pathname :name)", Error.ProgramError);
}

test "make-pathname rejects a malformed directory or a non-string component" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectError("(make-pathname :directory 7)", Error.TypeError);
    try fx.expectError("(make-pathname :directory '(:sideways \"a\"))", Error.TypeError);
    try fx.expectError("(make-pathname :directory '(\"a\"))", Error.TypeError);
    try fx.expectError("(make-pathname :directory '(:absolute :sideways))", Error.TypeError);
    try fx.expectError("(make-pathname :directory '(:absolute 7))", Error.TypeError);
    try fx.expectError("(make-pathname :name 7)", Error.TypeError);
    try fx.expectError("(make-pathname :name \"c\" :type 7)", Error.TypeError);
}

// --- merge-pathnames ---

test "merge-pathnames extends a relative directory with the default's" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"auxiliary/\" \"/home/x/\")", "/home/x/auxiliary/");
}

test "merge-pathnames over a default that names a file keeps that name" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring(
        "(merge-pathnames \"auxiliary/\" \"/home/x/gclload1.lsp\")",
        "/home/x/auxiliary/gclload1.lsp",
    );
}

test "merge-pathnames keeps an absolute directory as given" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"/etc/a.lsp\" \"/home/x/b.lsp\")", "/etc/a.lsp");
}

test "merge-pathnames takes the default's directory when there is none" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"a.lsp\" \"/home/x/b.o\")", "/home/x/a.lsp");
}

test "merge-pathnames keeps its own directory when the default has none" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"/etc/a.lsp\" \"b.o\")", "/etc/a.lsp");
}

test "merge-pathnames fills in a missing name and type from the default" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"/etc/\" \"/home/b.o\")", "/etc/b.o");
}

test "merge-pathnames fills a missing type from the default even with its own name" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"/etc/a\" \"/home/b.o\")", "/etc/a.o");
    try fx.expectNamestring("(merge-pathnames \"/etc/a.x\" \"/home/b.o\")", "/etc/a.x");
}

test "merge-pathnames with one argument just re-renders the pathname" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"/a/b.lsp\")", "/a/b.lsp");
}

test "merge-pathnames accepts but ignores a default version" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(merge-pathnames \"a.lsp\" \"/home/\" :newest)", "/home/a.lsp");
}

test "merge-pathnames takes one to three arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectError("(merge-pathnames)", Error.WrongArgCount);
    try fx.expectError("(merge-pathnames \"a\" \"b\" :newest 4)", Error.WrongArgCount);
}

// --- compile-file-pathname ---

test "compile-file-pathname replaces the source type with the fasl type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNamestring("(compile-file-pathname \"/a/rt.lsp\")", "/a/rt.zfasl");
    try fx.expectNamestring("(compile-file-pathname \"rt\")", "rt.zfasl");
}
