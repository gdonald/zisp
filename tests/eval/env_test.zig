const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const Env = zisp.eval.Env;
const Frame = zisp.eval.Frame;
const HASH_THRESHOLD = zisp.eval.env.HASH_THRESHOLD;

const ScratchSym = struct {
    interner: symbol_mod.Interner,

    fn init(allocator: std.mem.Allocator) !ScratchSym {
        var s: ScratchSym = .{ .interner = symbol_mod.Interner.init(allocator) };
        try symbol_mod.initStandardSymbols(&s.interner);
        return s;
    }

    fn deinit(self: *ScratchSym) void {
        self.interner.deinit();
    }

    fn sym(self: *ScratchSym, name: []const u8) !value.Value {
        return self.interner.intern(name);
    }
};

test "empty env: lookupValue/lookupFunction return null when global cell unbound" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    try std.testing.expect(env.lookupValue(x) == null);
    try std.testing.expect(env.lookupFunction(x) == null);
}

test "frame bind / lookup in single frame" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    const v42 = value.Value.fromFixnum(42);
    try env.bindValue(x, v42);
    try std.testing.expect(env.lookupValue(x).?.equalsRaw(v42));
}

test "rebind in same frame replaces value (no duplicates)" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    try env.bindValue(x, value.Value.fromFixnum(1));
    try env.bindValue(x, value.Value.fromFixnum(2));
    try std.testing.expectEqual(@as(i64, 2), env.lookupValue(x).?.toFixnum());
    try std.testing.expectEqual(@as(usize, 1), env.top_value.?.count());
}

test "inner frame shadows outer; pop restores outer" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    _ = try env.pushValueFrame();
    try env.top_value.?.bind(env.allocator, x, value.Value.fromFixnum(1));

    _ = try env.pushValueFrame();
    try env.top_value.?.bind(env.allocator, x, value.Value.fromFixnum(99));
    try std.testing.expectEqual(@as(i64, 99), env.lookupValue(x).?.toFixnum());

    env.popValueFrame();
    try std.testing.expectEqual(@as(i64, 1), env.lookupValue(x).?.toFixnum());
}

test "lookup falls back to global value cell" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    symbol_mod.symbol(x).value_cell = value.Value.fromFixnum(7);
    try std.testing.expectEqual(@as(i64, 7), env.lookupValue(x).?.toFixnum());

    // Lexical binding shadows the global.
    try env.bindValue(x, value.Value.fromFixnum(8));
    try std.testing.expectEqual(@as(i64, 8), env.lookupValue(x).?.toFixnum());
}

test "value namespace and function namespace are independent (Lisp-2)" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const f = try sc.sym("F");
    const fn_marker = value.Value.fromFixnum(100);
    const val_marker = value.Value.fromFixnum(200);

    try env.bindFunction(f, fn_marker);
    try env.bindValue(f, val_marker);

    try std.testing.expectEqual(@as(i64, 100), env.lookupFunction(f).?.toFixnum());
    try std.testing.expectEqual(@as(i64, 200), env.lookupValue(f).?.toFixnum());
}

test "function lookup falls back to global function cell only" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const f = try sc.sym("F");
    symbol_mod.symbol(f).value_cell = value.Value.fromFixnum(11);
    symbol_mod.symbol(f).function_cell = value.Value.fromFixnum(22);

    try std.testing.expectEqual(@as(i64, 22), env.lookupFunction(f).?.toFixnum());
    try std.testing.expectEqual(@as(i64, 11), env.lookupValue(f).?.toFixnum());
}

test "assignValue mutates innermost lexical binding" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    _ = try env.pushValueFrame();
    try env.top_value.?.bind(env.allocator, x, value.Value.fromFixnum(1));

    _ = try env.pushValueFrame();
    // Inner frame doesn't bind x; assignValue should still find outer.
    env.assignValue(x, value.Value.fromFixnum(99));

    env.popValueFrame();
    try std.testing.expectEqual(@as(i64, 99), env.lookupValue(x).?.toFixnum());
}

test "assignValue with no lexical binding sets global" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    env.assignValue(x, value.Value.fromFixnum(5));
    try std.testing.expect(symbol_mod.symbol(x).value_cell.equalsRaw(value.Value.fromFixnum(5)));
}

test "assignFunction mirrors assignValue but on function cell" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const f = try sc.sym("F");
    env.assignFunction(f, value.Value.fromFixnum(33));
    try std.testing.expect(symbol_mod.symbol(f).function_cell.equalsRaw(value.Value.fromFixnum(33)));

    _ = try env.pushFunctionFrame();
    try env.top_function.?.bind(env.allocator, f, value.Value.fromFixnum(44));
    env.assignFunction(f, value.Value.fromFixnum(55));
    try std.testing.expectEqual(@as(i64, 55), env.lookupFunction(f).?.toFixnum());
    // Global cell unchanged because lexical binding intercepted.
    try std.testing.expect(symbol_mod.symbol(f).function_cell.equalsRaw(value.Value.fromFixnum(33)));
}

test "frame promotes to hash map past threshold" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    var f = try env.pushValueFrame();
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i <= HASH_THRESHOLD) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "V{d}", .{i});
        const sym = try sc.sym(name);
        try f.bind(env.allocator, sym, value.Value.fromFixnum(@intCast(i)));
    }
    try std.testing.expect(f.isHashed());

    // After promotion, lookup still works for every binding.
    i = 0;
    while (i <= HASH_THRESHOLD) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "V{d}", .{i});
        const sym = try sc.sym(name);
        try std.testing.expectEqual(@as(i64, @intCast(i)), f.find(sym).?.toFixnum());
    }
}

test "rebind in promoted (hashed) frame replaces value" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    var f = try env.pushValueFrame();
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    while (i <= HASH_THRESHOLD + 1) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "V{d}", .{i});
        const sym = try sc.sym(name);
        try f.bind(env.allocator, sym, value.Value.fromFixnum(@intCast(i)));
    }
    try std.testing.expect(f.isHashed());

    const sym0 = try sc.sym("V0");
    try f.bind(env.allocator, sym0, value.Value.fromFixnum(999));
    try std.testing.expectEqual(@as(i64, 999), f.find(sym0).?.toFixnum());
}

test "assign returns false when symbol absent" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    var f = try env.pushValueFrame();
    const x = try sc.sym("X");
    try std.testing.expect(!f.assign(x, value.Value.fromFixnum(1)));
}

test "assign in promoted frame mutates existing binding" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    var f = try env.pushValueFrame();
    var name_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i <= HASH_THRESHOLD + 1) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "V{d}", .{i});
        const sym = try sc.sym(name);
        try f.bind(env.allocator, sym, value.Value.fromFixnum(@intCast(i)));
    }
    const v0 = try sc.sym("V0");
    try std.testing.expect(f.assign(v0, value.Value.fromFixnum(-1)));
    try std.testing.expectEqual(@as(i64, -1), f.find(v0).?.toFixnum());

    // Symbol not in hashed frame returns false.
    const missing = try sc.sym("MISSING");
    try std.testing.expect(!f.assign(missing, value.Value.fromFixnum(0)));
}

test "popValueFrame on empty env is a no-op" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    env.popValueFrame();
    env.popFunctionFrame();
    try std.testing.expect(env.top_value == null);
    try std.testing.expect(env.top_function == null);
}

test "deinit frees deeply nested frames" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = try env.pushValueFrame();
        _ = try env.pushFunctionFrame();
    }
    // No explicit pops — deinit must walk the chain.
    env.deinit();

    try std.testing.expect(env.top_value == null);
    try std.testing.expect(env.top_function == null);
}

test "defineGlobalValue / defineGlobalFunction set the symbol cells" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const x = try sc.sym("X");
    env.defineGlobalValue(x, value.Value.fromFixnum(11));
    env.defineGlobalFunction(x, value.Value.fromFixnum(22));
    try std.testing.expect(symbol_mod.symbol(x).value_cell.equalsRaw(value.Value.fromFixnum(11)));
    try std.testing.expect(symbol_mod.symbol(x).function_cell.equalsRaw(value.Value.fromFixnum(22)));
}

test "find on empty frame returns null" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const f = try env.pushValueFrame();
    const x = try sc.sym("X");
    try std.testing.expect(f.find(x) == null);
}

test "popFunctionFrame restores parent and frees" {
    var sc = try ScratchSym.init(std.testing.allocator);
    defer sc.deinit();
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const f = try sc.sym("F");
    _ = try env.pushFunctionFrame();
    try env.top_function.?.bind(env.allocator, f, value.Value.fromFixnum(1));

    const inner = try env.pushFunctionFrame();
    try inner.bind(env.allocator, f, value.Value.fromFixnum(2));
    try std.testing.expectEqual(@as(i64, 2), env.lookupFunction(f).?.toFixnum());

    env.popFunctionFrame();
    try std.testing.expectEqual(@as(i64, 1), env.lookupFunction(f).?.toFixnum());
}
