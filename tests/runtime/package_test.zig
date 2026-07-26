const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol = zisp.symbol;
const package = zisp.package;
const Interner = symbol.Interner;

fn newInterner() !Interner {
    var interner = try Interner.init(testing.allocator);
    errdefer interner.deinit();
    try symbol.initStandardSymbols(&interner);
    return interner;
}

test "the three standard packages exist under name and nickname" {
    var interner = try newInterner();
    defer interner.deinit();

    try testing.expect(interner.registry.find("COMMON-LISP").? == interner.cl);
    try testing.expect(interner.registry.find("CL").? == interner.cl);
    try testing.expect(interner.registry.find("COMMON-LISP-USER").? == interner.cl_user);
    try testing.expect(interner.registry.find("CL-USER").? == interner.cl_user);
    try testing.expect(interner.registry.find("KEYWORD").? == interner.keyword);
}

test "find on an unknown package name returns null" {
    var interner = try newInterner();
    defer interner.deinit();
    try testing.expect(interner.registry.find("NOPE") == null);
}

test "creating a package that already exists reports PackageExists" {
    var interner = try newInterner();
    defer interner.deinit();
    try testing.expectError(package.Error.PackageExists, interner.registry.create("COMMON-LISP"));
}

test "a nickname colliding with another package reports PackageExists" {
    var interner = try newInterner();
    defer interner.deinit();
    const pkg = try interner.registry.create("MINE");
    try testing.expectError(package.Error.PackageExists, interner.registry.addNickname(pkg, "CL"));
}

test "re-adding a package's own nickname is a no-op" {
    var interner = try newInterner();
    defer interner.deinit();
    try interner.registry.addNickname(interner.cl, "CL");
    try testing.expectEqual(@as(usize, 1), interner.cl.nicknames.items.len);
}

test "interning the same name twice in one package returns the same symbol" {
    var interner = try newInterner();
    defer interner.deinit();
    const pkg = try interner.registry.create("MINE");
    const first = try interner.internIn(pkg, "FOO");
    const second = try interner.internIn(pkg, "FOO");
    try testing.expect(first.equalsRaw(second));
}

test "the same name in two packages produces two distinct symbols" {
    var interner = try newInterner();
    defer interner.deinit();
    const one = try interner.registry.create("ONE");
    const two = try interner.registry.create("TWO");
    const a = try interner.internIn(one, "FOO");
    const b = try interner.internIn(two, "FOO");
    try testing.expect(!a.equalsRaw(b));
}

test "a fresh symbol is internal in its home package" {
    var interner = try newInterner();
    defer interner.deinit();
    const pkg = try interner.registry.create("MINE");
    const sym = try interner.internIn(pkg, "FOO");
    try testing.expectEqual(package.Status.internal, pkg.findSymbol("FOO").?.status);
    try testing.expect(symbol.homePackage(sym).? == pkg);
}

test "a keyword is external in KEYWORD and evaluates to itself" {
    var interner = try newInterner();
    defer interner.deinit();
    const sym = try interner.internKeyword("FOO");
    try testing.expectEqual(package.Status.external, interner.keyword.findSymbol("FOO").?.status);
    try testing.expect(symbol.symbol(sym).value_cell.equalsRaw(sym));
    try testing.expect(symbol.symbol(sym).constant);
}

test "a used package's external symbols are inherited" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);

    const sym = try interner.internIn(provider, "SHARED");
    try provider.addExternal(symbol.name(sym), sym);
    _ = provider.internal.remove(symbol.name(sym));

    const found = consumer.findSymbol("SHARED").?;
    try testing.expect(found.sym.equalsRaw(sym));
    try testing.expectEqual(package.Status.inherited, found.status);
}

test "a used package's internal symbols are not inherited" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);
    _ = try interner.internIn(provider, "HIDDEN");
    try testing.expect(consumer.findSymbol("HIDDEN") == null);
}

test "a present symbol shadows an inherited one of the same name" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);
    const shared = try interner.internIn(provider, "NAME");
    try provider.addExternal(symbol.name(shared), shared);

    const own = try interner.internIn(consumer, "NAME");
    try testing.expect(consumer.findSymbol("NAME").?.sym.equalsRaw(own));
}

test "addUse is idempotent and records the reverse link" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);
    try consumer.addUse(provider);
    try testing.expectEqual(@as(usize, 1), consumer.use_list.items.len);
    try testing.expectEqual(@as(usize, 1), provider.used_by.items.len);
}

test "removeUse severs both directions" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);
    consumer.removeUse(provider);
    try testing.expectEqual(@as(usize, 0), consumer.use_list.items.len);
    try testing.expectEqual(@as(usize, 0), provider.used_by.items.len);
}

test "removeUse on a package that is not used changes nothing" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    consumer.removeUse(provider);
    try testing.expectEqual(@as(usize, 0), consumer.use_list.items.len);
}

test "deleting a package drops its name, nicknames, and use links" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    try interner.registry.addNickname(provider, "PROV");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);

    interner.registry.delete(provider);

    try testing.expect(interner.registry.find("PROVIDER") == null);
    try testing.expect(interner.registry.find("PROV") == null);
    try testing.expect(provider.deleted);
    try testing.expectEqual(@as(usize, 0), consumer.use_list.items.len);
}

test "deleting a package that uses another severs the forward link" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const consumer = try interner.registry.create("CONSUMER");
    try consumer.addUse(provider);
    interner.registry.delete(consumer);
    try testing.expectEqual(@as(usize, 0), provider.used_by.items.len);
}

test "removePresent clears internal, external, and shadowing entries" {
    var interner = try newInterner();
    defer interner.deinit();
    const pkg = try interner.registry.create("MINE");
    const sym = try interner.internIn(pkg, "FOO");
    try pkg.shadowing.put(pkg.allocator, symbol.name(sym), sym);
    pkg.removePresent("FOO");
    try testing.expect(pkg.findPresent("FOO") == null);
    try testing.expect(!pkg.isShadowing("FOO"));
}

test "isShadowing reports names added to the shadowing table" {
    var interner = try newInterner();
    defer interner.deinit();
    const pkg = try interner.registry.create("MINE");
    const sym = try interner.internIn(pkg, "FOO");
    try testing.expect(!pkg.isShadowing("FOO"));
    try pkg.shadowing.put(pkg.allocator, symbol.name(sym), sym);
    try testing.expect(pkg.isShadowing("FOO"));
}

test "usesPackage answers for both used and unused packages" {
    var interner = try newInterner();
    defer interner.deinit();
    const provider = try interner.registry.create("PROVIDER");
    const other = try interner.registry.create("OTHER");
    try testing.expect(!interner.cl_user.usesPackage(provider));
    try interner.cl_user.addUse(provider);
    try testing.expect(interner.cl_user.usesPackage(provider));
    try testing.expect(!interner.cl_user.usesPackage(other));
}

test "an uninterned symbol has no home package" {
    var interner = try newInterner();
    defer interner.deinit();
    const sym = try interner.makeUninterned("LOOSE");
    try testing.expect(symbol.homePackage(sym) == null);
    try testing.expect(interner.registry.find("LOOSE") == null);
}

test "toValue round-trips through asPackage" {
    var interner = try newInterner();
    defer interner.deinit();
    const pkg = try interner.registry.create("MINE");
    const v = pkg.toValue();
    try testing.expect(package.isPackage(v));
    try testing.expect(package.asPackage(v) == pkg);
}

test "isPackage rejects a non-package value" {
    var interner = try newInterner();
    defer interner.deinit();
    try testing.expect(!package.isPackage(value.Value.fromFixnum(7)));
    try testing.expect(!package.isPackage(value.NIL));
}

test "intern promotes an existing internal COMMON-LISP symbol to external" {
    var interner = try newInterner();
    defer interner.deinit();
    const sym = try interner.internIn(interner.cl, "LATER-EXPORTED");
    try testing.expectEqual(package.Status.internal, interner.cl.findSymbol("LATER-EXPORTED").?.status);
    const again = try interner.intern("LATER-EXPORTED");
    try testing.expect(again.equalsRaw(sym));
    try testing.expectEqual(package.Status.external, interner.cl.findSymbol("LATER-EXPORTED").?.status);
}

test "currentPackage follows the value of *package*" {
    var interner = try newInterner();
    defer interner.deinit();
    try testing.expect(interner.currentPackage() == interner.cl_user);
    const pkg = try interner.registry.create("MINE");
    interner.setCurrentPackage(pkg);
    try testing.expect(interner.currentPackage() == pkg);
    const in_current = try interner.internCurrent("X");
    try testing.expect(in_current.equalsRaw(pkg.findSymbol("X").?.sym));
}

test "currentPackage falls back to CL-USER when *package* holds a non-package" {
    var interner = try newInterner();
    defer interner.deinit();
    symbol.symbol(interner.package_symbol).value_cell = value.Value.fromFixnum(3);
    try testing.expect(interner.currentPackage() == interner.cl_user);
}

test "lookup resolves through the current package and what it uses" {
    var interner = try newInterner();
    defer interner.deinit();
    const cl_symbol = try interner.intern("CAR");
    try testing.expect(interner.lookup("CAR").?.equalsRaw(cl_symbol));
    try testing.expect(interner.lookup("NO-SUCH-NAME") == null);
}

test "count totals the symbols present in every package" {
    var interner = try newInterner();
    defer interner.deinit();
    const before = interner.count();
    const pkg = try interner.registry.create("MINE");
    _ = try interner.internIn(pkg, "A");
    _ = try interner.internIn(pkg, "B");
    try testing.expectEqual(before + 2, interner.count());
}
