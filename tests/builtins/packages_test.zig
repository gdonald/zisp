const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const package_mod = zisp.package;
const Evaluator = zisp.eval.Evaluator;
const Value = zisp.Value;

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

    /// Read and evaluate every form in `src`, returning the last value.
    fn run(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var last = value.NIL;
        while (try rd.read()) |form| last = try self.ev.eval(form);
        return last;
    }

    fn runPrints(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.run(src);
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try zisp.printer.write(testing.allocator, &aw.writer, v, .{
            .escape = true,
            .current_package = self.interner.currentPackage(),
        });
        try testing.expectEqualStrings(expected, aw.written());
    }
};

test "make-package registers the name, nicknames, and use list" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    _ = try fx.run("(make-package \"MINE\" :nicknames (list \"MY\") :use (list \"CL\"))");
    try fx.runPrints("(package-name (find-package \"MY\"))", "\"MINE\"");
    try fx.runPrints("(package-nicknames (find-package \"MINE\"))", "(\"MY\")");
    try fx.runPrints("(package-name (car (package-use-list (find-package \"MINE\"))))", "\"COMMON-LISP\"");
}

test "make-package rejects a name already in use" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.PackageError, fx.run("(make-package \"CL\")"));
}

test "make-package rejects an unknown option" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ProgramError, fx.run("(make-package \"MINE\" :bogus 1)"));
}

test "make-package rejects an odd option list" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.WrongArgCount, fx.run("(make-package \"MINE\" :use)"));
}

test "find-package accepts strings, symbols, keywords, and packages" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(package-name (find-package \"KEYWORD\"))", "\"KEYWORD\"");
    try fx.runPrints("(package-name (find-package :keyword))", "\"KEYWORD\"");
    try fx.runPrints("(package-name (find-package (find-package \"CL\")))", "\"COMMON-LISP\"");
}

test "find-package returns nil for an unknown name" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(find-package \"NOPE\")", "NIL");
}

test "package-name of a deleted package is nil" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"GONE\")");
    try fx.runPrints("(let ((p (find-package \"GONE\"))) (list (delete-package p) (package-name p)))", "(T NIL)");
}

test "delete-package returns nil for an unknown or already deleted package" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(delete-package \"NOPE\")", "NIL");
    _ = try fx.run("(make-package \"GONE\")");
    try fx.runPrints("(let ((p (find-package \"GONE\"))) (delete-package p) (delete-package p))", "NIL");
}

test "list-all-packages holds the standard packages and omits deleted ones" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(length (list-all-packages))", "3");
    _ = try fx.run("(make-package \"EXTRA\")");
    try fx.runPrints("(length (list-all-packages))", "4");
    _ = try fx.run("(delete-package \"EXTRA\")");
    try fx.runPrints("(length (list-all-packages))", "3");
}

test "packagep distinguishes packages from other values" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(list (packagep (find-package :cl)) (packagep 1) (packagep :cl))", "(T NIL NIL)");
}

test "intern returns the symbol and its status" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (intern \"FOO\" \"MINE\")))", "NIL");
    try fx.runPrints("(cadr (multiple-value-list (intern \"FOO\" \"MINE\")))", ":INTERNAL");
    _ = try fx.run("(export (intern \"FOO\" \"MINE\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (intern \"FOO\" \"MINE\")))", ":EXTERNAL");
}

test "intern defaults to the current package" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(symbol-package (intern \"HERE\"))", "#<PACKAGE \"COMMON-LISP-USER\">");
}

test "find-symbol reports inherited status and misses" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"CAR\" \"CL-USER\")))", ":INHERITED");
    try fx.runPrints("(multiple-value-list (find-symbol \"NOT-A-SYMBOL-ANYWHERE\"))", "(NIL NIL)");
}

test "export makes an inherited symbol present and external" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\" :use (list \"CL\"))");
    _ = try fx.run("(export (find-symbol \"CAR\" \"MINE\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"CAR\" \"MINE\")))", ":EXTERNAL");
}

test "export accepts a list of symbols" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(export (list (intern \"A\" \"MINE\") (intern \"B\" \"MINE\")) \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"B\" \"MINE\")))", ":EXTERNAL");
}

test "export on an already external symbol is idempotent" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(export (intern \"A\" \"MINE\") \"MINE\")");
    _ = try fx.run("(export (intern \"A\" \"MINE\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"A\" \"MINE\")))", ":EXTERNAL");
}

test "unexport moves a symbol back to internal" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(export (intern \"A\" \"MINE\") \"MINE\")");
    _ = try fx.run("(unexport (intern \"A\" \"MINE\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"A\" \"MINE\")))", ":INTERNAL");
}

test "unexport of a symbol that is not external changes nothing" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(unexport (intern \"A\" \"MINE\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"A\" \"MINE\")))", ":INTERNAL");
}

test "use-package makes external symbols visible" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"PROVIDER\")");
    _ = try fx.run("(export (intern \"SHARED\" \"PROVIDER\") \"PROVIDER\")");
    _ = try fx.run("(make-package \"CONSUMER\")");
    _ = try fx.run("(use-package \"PROVIDER\" \"CONSUMER\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"SHARED\" \"CONSUMER\")))", ":INHERITED");
    try fx.runPrints("(package-name (car (package-used-by-list \"PROVIDER\")))", "\"CONSUMER\"");
}

test "use-package accepts a list of packages" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"CONSUMER\")");
    _ = try fx.run("(use-package (list \"CL\") \"CONSUMER\")");
    try fx.runPrints("(length (package-use-list \"CONSUMER\"))", "1");
}

test "unuse-package removes the inheritance" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"CONSUMER\" :use (list \"CL\"))");
    _ = try fx.run("(unuse-package \"CL\" \"CONSUMER\")");
    try fx.runPrints("(package-use-list \"CONSUMER\")", "NIL");
    try fx.runPrints("(find-symbol \"CAR\" \"CONSUMER\")", "NIL");
}

test "unuse-package accepts a list of packages" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"CONSUMER\" :use (list \"CL\"))");
    _ = try fx.run("(unuse-package (list \"CL\") \"CONSUMER\")");
    try fx.runPrints("(package-use-list \"CONSUMER\")", "NIL");
}

test "import makes a foreign symbol present without changing its home" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(import (find-symbol \"CAR\" \"CL\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"CAR\" \"MINE\")))", ":INTERNAL");
    try fx.runPrints("(package-name (symbol-package (find-symbol \"CAR\" \"MINE\")))", "\"COMMON-LISP\"");
}

test "importing the same symbol twice is a no-op" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(import (find-symbol \"CAR\" \"CL\") \"MINE\")");
    _ = try fx.run("(import (find-symbol \"CAR\" \"CL\") \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"CAR\" \"MINE\")))", ":INTERNAL");
}

test "import conflicting with a present symbol of the same name errors" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(intern \"CAR\" \"MINE\")");
    try testing.expectError(error.PackageError, fx.run("(import (find-symbol \"CAR\" \"CL\") \"MINE\")"));
}

test "import adopts an uninterned symbol into the package" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(import (make-symbol \"LOOSE\") \"MINE\")");
    try fx.runPrints("(package-name (symbol-package (find-symbol \"LOOSE\" \"MINE\")))", "\"MINE\"");
}

test "shadow creates a present symbol that hides the inherited one" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\" :use (list \"CL\"))");
    _ = try fx.run("(shadow \"CAR\" \"MINE\")");
    try fx.runPrints("(cadr (multiple-value-list (find-symbol \"CAR\" \"MINE\")))", ":INTERNAL");
    try fx.runPrints("(length (package-shadowing-symbols \"MINE\"))", "1");
}

test "shadow accepts a list of names" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\" :use (list \"CL\"))");
    _ = try fx.run("(shadow (list \"CAR\" \"CDR\") \"MINE\")");
    try fx.runPrints("(length (package-shadowing-symbols \"MINE\"))", "2");
}

test "shadow on an already present symbol reuses it" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    _ = try fx.run("(intern \"A\" \"MINE\")");
    _ = try fx.run("(shadow \"A\" \"MINE\")");
    try fx.runPrints("(length (package-shadowing-symbols \"MINE\"))", "1");
}

test "shadowing-import replaces a present symbol and records the shadow" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\" :use (list \"CL\"))");
    _ = try fx.run("(intern \"CAR\" \"MINE\")");
    _ = try fx.run("(shadowing-import (find-symbol \"CAR\" \"CL\") \"MINE\")");
    try fx.runPrints("(package-name (symbol-package (find-symbol \"CAR\" \"MINE\")))", "\"COMMON-LISP\"");
    try fx.runPrints("(length (package-shadowing-symbols \"MINE\"))", "1");
}

test "unintern removes a present symbol and clears its home" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    try fx.runPrints("(let ((s (intern \"A\" \"MINE\"))) (list (unintern s \"MINE\") (symbol-package s)))", "(T NIL)");
    try fx.runPrints("(find-symbol \"A\" \"MINE\")", "NIL");
}

test "unintern of an absent or different symbol returns nil" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\")");
    try fx.runPrints("(unintern (make-symbol \"A\") \"MINE\")", "NIL");
    _ = try fx.run("(intern \"A\" \"MINE\")");
    try fx.runPrints("(unintern (make-symbol \"A\") \"MINE\")", "NIL");
}

test "symbol-package of an uninterned symbol is nil" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(symbol-package (make-symbol \"LOOSE\"))", "NIL");
}

test "make-symbol produces a fresh symbol each call" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(eq (make-symbol \"A\") (make-symbol \"A\"))", "NIL");
}

test "symbol-name returns the name without any package prefix" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(symbol-name :foo)", "\"FOO\"");
    try fx.runPrints("(symbol-name 'cl::car)", "\"CAR\"");
}

test "keywordp is true only for symbols in the KEYWORD package" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try fx.runPrints("(list (keywordp :a) (keywordp 'a) (keywordp 1))", "(T NIL NIL)");
}

test "in-package switches the reader's current package" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"MINE\" :use (list \"CL\"))");
    _ = try fx.run("(in-package \"MINE\")");
    try testing.expect(fx.interner.currentPackage() == fx.interner.registry.find("MINE").?);
    try fx.runPrints("(package-name *package*)", "\"MINE\"");
}

test "in-package on an unknown package signals" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.NoSuchPackage, fx.run("(in-package \"NOPE\")"));
}

test "a package designator must be a string, symbol, or package" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.TypeError, fx.run("(find-package 7)"));
}

test "%package-symbols partitions by internal, external, and inherited" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"PROVIDER\")");
    _ = try fx.run("(export (intern \"SHARED\" \"PROVIDER\") \"PROVIDER\")");
    _ = try fx.run("(make-package \"MINE\" :use (list \"PROVIDER\"))");
    _ = try fx.run("(intern \"OWN\" \"MINE\")");
    _ = try fx.run("(export (intern \"PUB\" \"MINE\") \"MINE\")");

    try fx.runPrints("(length (%package-symbols \"MINE\" \"INTERNAL\"))", "1");
    try fx.runPrints("(length (%package-symbols \"MINE\" \"EXTERNAL\"))", "1");
    try fx.runPrints("(length (%package-symbols \"MINE\" \"PRESENT\"))", "2");
    try fx.runPrints("(car (%package-symbols \"MINE\" \"INHERITED\"))", "PROVIDER:SHARED");
}

test "%package-symbols skips inherited names the package already has" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    _ = try fx.run("(make-package \"PROVIDER\")");
    _ = try fx.run("(export (intern \"SHARED\" \"PROVIDER\") \"PROVIDER\")");
    _ = try fx.run("(make-package \"MINE\" :use (list \"PROVIDER\"))");
    _ = try fx.run("(shadow \"SHARED\" \"MINE\")");
    try fx.runPrints("(%package-symbols \"MINE\" \"INHERITED\")", "NIL");
}
