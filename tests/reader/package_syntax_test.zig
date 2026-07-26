const std = @import("std");
const zisp = @import("zisp");
const heap = zisp.heap;
const symbol = zisp.symbol;
const printer = zisp.printer;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const ReaderError = zisp.reader.ReaderError;
const Value = zisp.Value;

const Setup = struct {
    arena: std.heap.ArenaAllocator,
    h: heap.Heap,
    interner: symbol.Interner,
    allocator: std.mem.Allocator,

    fn deinit(self: *Setup) void {
        self.interner.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

fn newSetup(test_allocator: std.mem.Allocator) !*Setup {
    const s = try test_allocator.create(Setup);
    s.* = .{
        .arena = std.heap.ArenaAllocator.init(test_allocator),
        .h = undefined,
        .interner = try symbol.Interner.init(test_allocator),
        .allocator = test_allocator,
    };
    s.h = heap.Heap.init(s.arena.allocator());
    try symbol.initStandardSymbols(&s.interner);
    return s;
}

fn readOne(setup: *Setup, src: []const u8) !Value {
    var tk = Tokenizer.init(src);
    var rd = Reader.init(&tk, &setup.h, &setup.interner);
    const got = try rd.read();
    return got orelse error.UnexpectedEof;
}

fn expectPrintsIn(setup: *Setup, v: Value, expected: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(setup.allocator);
    defer aw.deinit();
    try printer.write(setup.allocator, &aw.writer, v, .{
        .escape = true,
        .current_package = setup.interner.currentPackage(),
    });
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "an unqualified name interns into the current package" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "foo");
    try std.testing.expect(symbol.homePackage(v).? == s.interner.cl_user);
}

test "a double-colon prefix interns into the named package" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "common-lisp::hidden");
    try std.testing.expectEqualStrings("HIDDEN", symbol.name(v));
    try std.testing.expect(symbol.homePackage(v).? == s.interner.cl);
}

test "a single-colon prefix resolves an external symbol" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const expected = try s.interner.intern("CAR");
    const v = try readOne(s, "cl:car");
    try std.testing.expect(v.equalsRaw(expected));
}

test "a package nickname works as a prefix" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const expected = try s.interner.intern("CDR");
    const v = try readOne(s, "common-lisp:cdr");
    try std.testing.expect(v.equalsRaw(expected));
}

test "a single-colon prefix rejects an internal symbol" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    _ = try s.interner.internIn(s.interner.cl, "PRIVATE");
    try std.testing.expectError(ReaderError.SymbolNotExternal, readOne(s, "cl:private"));
}

test "a single-colon prefix rejects a name absent from the package" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectError(ReaderError.SymbolNotExternal, readOne(s, "cl:no-such-symbol"));
}

test "an unknown package prefix is rejected" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectError(ReaderError.NoSuchPackage, readOne(s, "nope:foo"));
}

test "a leading double colon reads as a keyword" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "::foo");
    try std.testing.expect(symbol.homePackage(v).? == s.interner.keyword);
    try std.testing.expectEqualStrings("FOO", symbol.name(v));
}

test "a pipe-quoted colon is part of the name, not a package marker" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "|a:b|");
    try std.testing.expectEqualStrings("a:b", symbol.name(v));
    try std.testing.expect(symbol.homePackage(v).? == s.interner.cl_user);
}

test "an escaped colon is part of the name, not a package marker" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "a\\:b");
    try std.testing.expectEqualStrings("A:B", symbol.name(v));
}

test "a pipe-quoted package prefix keeps its case" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const pkg = try s.interner.registry.create("mixed");
    const v = try readOne(s, "|mixed|::thing");
    try std.testing.expect(symbol.homePackage(v).? == pkg);
}

test "sharp-colon reads a fresh uninterned symbol every time" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    var tk = Tokenizer.init("#:gs #:gs");
    var rd = Reader.init(&tk, &s.h, &s.interner);
    const first = (try rd.read()).?;
    const second = (try rd.read()).?;
    try std.testing.expectEqualStrings("GS", symbol.name(first));
    try std.testing.expect(!first.equalsRaw(second));
    try std.testing.expect(symbol.homePackage(first) == null);
}

test "a symbol accessible in the current package prints unqualified" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    _ = try s.interner.intern("CAR");
    try expectPrintsIn(s, try readOne(s, "cl:car"), "CAR");
    try expectPrintsIn(s, try readOne(s, "foo"), "FOO");
}

test "an internal symbol of another package prints with two colons" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "common-lisp::hidden");
    try expectPrintsIn(s, v, "COMMON-LISP::HIDDEN");
}

test "an external symbol shadowed in the current package prints with one colon" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const other = try s.interner.registry.create("OTHER");
    const shared = try s.interner.internIn(other, "NAME");
    try other.addExternal(symbol.name(shared), shared);
    _ = other.internal.remove(symbol.name(shared));
    _ = try s.interner.internIn(s.interner.cl_user, "NAME");
    try expectPrintsIn(s, shared, "OTHER:NAME");
}

test "a keyword prints with a leading colon" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    try expectPrintsIn(s, try readOne(s, ":key"), ":KEY");
}

test "an uninterned symbol prints with a sharp-colon prefix" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    try expectPrintsIn(s, try readOne(s, "#:loose"), "#:LOOSE");
}

test "a package name needing escapes is piped in the prefix" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const pkg = try s.interner.registry.create("ODD NAME");
    const sym = try s.interner.internIn(pkg, "X");
    try expectPrintsIn(s, sym, "|ODD NAME|::X");
}

test "princ drops package qualification entirely" {
    const s = try newSetup(std.testing.allocator);
    defer s.deinit();
    const v = try readOne(s, "common-lisp::hidden");
    var aw = std.Io.Writer.Allocating.init(s.allocator);
    defer aw.deinit();
    try printer.write(s.allocator, &aw.writer, v, .{
        .escape = false,
        .current_package = s.interner.currentPackage(),
    });
    try std.testing.expectEqualStrings("HIDDEN", aw.written());
}
