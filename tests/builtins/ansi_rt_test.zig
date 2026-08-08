//! Loads `vendor/ansi-test/rt.lsp` on top of its package definition and
//! checks that the framework's entry points are defined and its test
//! database is initialized.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const package_mod = zisp.package;
const Evaluator = zisp.eval.Evaluator;

const package_path = "vendor/ansi-test/rt-package.lsp";
const rt_path = "vendor/ansi-test/rt.lsp";

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
        try zisp.builtins.system.loadPath(&fx.ev, package_path);
        try zisp.builtins.system.loadPath(&fx.ev, rt_path);
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

    fn symbolIn(self: *Fixture, name: []const u8) value.Value {
        return self.rt().findSymbol(name).?.sym;
    }
};

/// Names `rt.lsp` must define for the rest of the suite to be drivable.
const defined_functions = [_][]const u8{
    "DO-TESTS",         "DO-TEST",       "PENDING-TESTS", "GET-TEST",
    "REM-TEST",         "REM-ALL-TESTS", "ADD-ENTRY",     "DO-ENTRY",
    "CONTINUE-TESTING",
};

const defined_macros = [_][]const u8{ "DEFTEST", "DEFNOTE" };

test "rt.lsp loads without error or output" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expectEqualStrings("", fx.aw.written());
}

test "rt.lsp defines the framework's functions" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    for (defined_functions) |name| {
        const cell = symbol_mod.symbol(fx.symbolIn(name)).function_cell;
        if (cell.equalsRaw(value.SPECIAL_UNBOUND)) {
            std.debug.print("rt.lsp did not define {s}\n", .{name});
            return error.TestFailed;
        }
    }
}

test "rt.lsp defines deftest and defnote as macros" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    for (defined_macros) |name| {
        const cell = symbol_mod.symbol(fx.symbolIn(name)).function_cell;
        try testing.expect(!cell.equalsRaw(value.SPECIAL_UNBOUND));
        try testing.expect(zisp.eval.function.asFunction(cell).payload.closure.is_macro);
    }
}

test "rt.lsp defines the entry structure with its accessors" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    for ([_][]const u8{ "MAKE-ENTRY", "COPY-ENTRY", "ENTRY-P", "PEND", "NAME", "VALS" }) |name| {
        const cell = symbol_mod.symbol(fx.symbolIn(name)).function_cell;
        if (cell.equalsRaw(value.SPECIAL_UNBOUND)) {
            std.debug.print("rt.lsp did not define {s}\n", .{name});
            return error.TestFailed;
        }
    }
}

test "the test database starts empty with its tail pointing at the head" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    const entries = symbol_mod.symbol(fx.symbolIn("*ENTRIES*")).value_cell;
    // A single dummy cell that holds no entry.
    try testing.expect(entries.isCons());
    try testing.expect(heap_mod.car(entries).equalsRaw(value.NIL));
    try testing.expect(heap_mod.cdr(entries).equalsRaw(value.NIL));

    const tail = symbol_mod.symbol(fx.symbolIn("*ENTRIES-TAIL*")).value_cell;
    try testing.expect(tail.equalsRaw(entries));
}

test "the sandbox path defaults to nil when no sandbox directory exists" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    const path = symbol_mod.symbol(fx.symbolIn("*SANDBOX-PATH*")).value_cell;
    try testing.expect(path.equalsRaw(value.NIL));
}

test "loading rt.lsp leaves the current package alone" {
    const fx = try Fixture.init(testing.allocator);
    defer fx.deinit(testing.allocator);
    try testing.expect(fx.interner.currentPackage() == fx.interner.cl_user);
}
