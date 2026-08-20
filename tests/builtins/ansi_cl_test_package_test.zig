//! Loads `vendor/ansi-test/cl-test-package.lsp` and checks the CL-TEST
//! package it defines: its shadows, use list, exports, and that the reader
//! can be moved into it.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const package_mod = zisp.package;
const Evaluator = zisp.eval.Evaluator;

const rt_package_path = "vendor/ansi-test/rt-package.lsp";
const cl_test_package_path = "vendor/ansi-test/cl-test-package.lsp";
const compile_and_load_path = "vendor/ansi-test/compile-and-load.lsp";

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
        try zisp.builtins.system.loadPath(&fx.ev, compile_and_load_path);
        try zisp.builtins.system.loadPath(&fx.ev, rt_package_path);
        try zisp.builtins.system.loadPath(&fx.ev, cl_test_package_path);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn evalStr(self: *Fixture, src: []const u8) !value.Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| {
            result = try self.ev.eval(form);
        }
        return result;
    }

    fn clTest(self: *Fixture) *package_mod.Package {
        return self.interner.registry.find("CL-TEST").?;
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

test "loading cl-test-package.lsp defines the CL-TEST package" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectEqualStrings("CL-TEST", fx.clTest().name);
}

test "CL-TEST uses COMMON-LISP and REGRESSION-TEST" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);

    var saw_cl = false;
    var saw_rt = false;
    for (fx.clTest().use_list.items) |used| {
        if (std.mem.eql(u8, used.name, "COMMON-LISP")) saw_cl = true;
        if (std.mem.eql(u8, used.name, "REGRESSION-TEST")) saw_rt = true;
    }
    try testing.expect(saw_cl);
    try testing.expect(saw_rt);
}

test "CL-TEST shadows the condition-handling macros it redefines" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{ "HANDLER-CASE", "HANDLER-BIND" }) |name| {
        try testing.expect(fx.clTest().shadowing.contains(name));
    }
}

test "CL-TEST exports the helpers the test files reach for" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{
        "RANDOM-FROM-SEQ", "RANDOM-CASE",  "COIN",            "RANDOM-PERMUTE",
        "*UNIVERSE*",      "*CL-SYMBOLS*", "*MINI-UNIVERSE*", "SIGNALS-ERROR",
        "TYPEF",
    }) |name| {
        const found = fx.clTest().findSymbol(name) orelse return error.MissingSymbol;
        try testing.expectEqual(package_mod.Status.external, found.status);
    }
}

test "CL-TEST imports compile-and-load from CL-USER" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{ "COMPILE-AND-LOAD", "COMPILE-AND-LOAD*" }) |name| {
        try testing.expect(fx.clTest().findSymbol(name) != null);
    }
}

test "in-package moves the reader into CL-TEST" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(in-package :cl-test)");
    try testing.expectEqualStrings("CL-TEST", fx.interner.currentPackage().name);
}
