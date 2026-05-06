const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Interner = symbol_mod.Interner;

test "intern returns same value for same name" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    const a = try interner.intern("FOO");
    const b = try interner.intern("FOO");
    try std.testing.expect(a.equalsRaw(b));
}

test "intern returns different values for different names" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    const foo = try interner.intern("FOO");
    const bar = try interner.intern("BAR");
    try std.testing.expect(!foo.equalsRaw(bar));
}

test "interned symbol carries its name" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    const v = try interner.intern("HELLO");
    try std.testing.expectEqualStrings("HELLO", symbol_mod.name(v));
}

test "intern is case-sensitive (case folding is the reader's job)" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    const upper = try interner.intern("FOO");
    const lower = try interner.intern("foo");
    try std.testing.expect(!upper.equalsRaw(lower));
}

test "name is copied so caller can free" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    const buf = try std.testing.allocator.alloc(u8, 3);
    @memcpy(buf, "FOO");
    const v = try interner.intern(buf);
    std.testing.allocator.free(buf);

    try std.testing.expectEqualStrings("FOO", symbol_mod.name(v));
}

test "lookup returns null for missing name" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    try std.testing.expect(interner.lookup("MISSING") == null);
    _ = try interner.intern("PRESENT");
    try std.testing.expect(interner.lookup("PRESENT") != null);
}

test "initStandardSymbols sets NIL and T" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();
    try symbol_mod.initStandardSymbols(&interner);

    try std.testing.expect(value.NIL.isSymbol());
    try std.testing.expect(value.T.isSymbol());
    try std.testing.expect(!value.NIL.equalsRaw(value.T));
    try std.testing.expectEqualStrings("NIL", symbol_mod.name(value.NIL));
    try std.testing.expectEqualStrings("T", symbol_mod.name(value.T));
}

test "NIL and T are self-evaluating after init" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();
    try symbol_mod.initStandardSymbols(&interner);

    try std.testing.expect(symbol_mod.symbol(value.NIL).value_cell.equalsRaw(value.NIL));
    try std.testing.expect(symbol_mod.symbol(value.T).value_cell.equalsRaw(value.T));
}

test "lambda-list keywords pre-interned" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();
    try symbol_mod.initStandardSymbols(&interner);

    try std.testing.expect(interner.lookup("&REST") != null);
    try std.testing.expect(interner.lookup("&OPTIONAL") != null);
    try std.testing.expect(interner.lookup("QUOTE") != null);
    try std.testing.expect(interner.lookup("LAMBDA") != null);
}

test "interner survives many distinct names" {
    var interner = Interner.init(std.testing.allocator);
    defer interner.deinit();

    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const n = try std.fmt.bufPrint(&buf, "SYM-{d}", .{i});
        _ = try interner.intern(n);
    }
    try std.testing.expectEqual(@as(u32, 1000), interner.count());

    const again = try interner.intern("SYM-500");
    const expected = interner.lookup("SYM-500").?;
    try std.testing.expect(again.equalsRaw(expected));
}
