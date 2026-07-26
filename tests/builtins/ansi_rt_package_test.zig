//! Loads `vendor/ansi-test/rt-package.lsp` and checks the package it
//! defines: name, nicknames, use list, and the exported symbol set the rest
//! of the ansi-test suite reaches through.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const package_mod = zisp.package;
const Evaluator = zisp.eval.Evaluator;

const lsp_path = "vendor/ansi-test/rt-package.lsp";

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
        fx.ev.io = testing.io;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        try zisp.builtins.registerSystem(&fx.ev);
        try zisp.builtins.system.loadPath(&fx.ev, lsp_path);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn rt(self: *Fixture) *package_mod.Package {
        return self.interner.registry.find("REGRESSION-TEST").?;
    }
};

/// Every symbol `rt-package.lsp` exports. The rest of the suite reaches the
/// framework through these names.
const exported = [_][]const u8{
    "*COMPILE-TESTS*",        "*DO-TESTS-WHEN-DEFINED*", "*TEST*",
    "CONTINUE-TESTING",       "DEFTEST",                 "DO-TEST",
    "DO-TESTS",               "DO-EXTENDED-TESTS",       "GET-TEST",
    "PENDING-TESTS",          "REM-ALL-TESTS",           "REM-TEST",
    "DEFNOTE",                "MY-AREF",                 "LOAD-EXPECTED-FAILURES",
    "*CATCH-ERRORS*",         "*PASSED-TESTS*",          "*FAILED-TESTS*",
    "DISABLE-NOTE",           "*EXPECTED-FAILURES*",     "*UNEXPECTED-FAILURES*",
    "*UNEXPECTED-SUCCESSES*",
};

test "rt-package.lsp loads without error" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectEqualStrings("", fx.aw.written());
}

test "rt-package.lsp creates REGRESSION-TEST with both nicknames" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    const pkg = fx.rt();
    try testing.expect(fx.interner.registry.find("RTEST").? == pkg);
    try testing.expect(fx.interner.registry.find("RT").? == pkg);
}

test "REGRESSION-TEST uses COMMON-LISP" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    const pkg = fx.rt();
    try testing.expectEqual(@as(usize, 1), pkg.use_list.items.len);
    try testing.expect(pkg.use_list.items[0] == fx.interner.cl);
}

test "REGRESSION-TEST exports every name in the framework's interface" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    const pkg = fx.rt();
    for (exported) |name| {
        const found = pkg.findSymbol(name) orelse {
            std.debug.print("REGRESSION-TEST is missing {s}\n", .{name});
            return error.TestFailed;
        };
        try testing.expectEqual(package_mod.Status.external, found.status);
    }
}

test "loading rt-package.lsp twice leaves the package unchanged" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);

    const pkg = fx.rt();
    const before = pkg.external.count();
    try zisp.builtins.system.loadPath(&fx.ev, lsp_path);
    try testing.expect(fx.rt() == pkg);
    try testing.expectEqual(before, pkg.external.count());
}

test "rt-package.lsp leaves the current package alone" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expect(fx.interner.currentPackage() == fx.interner.cl_user);
}
