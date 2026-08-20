//! Hash tables. The table's `:test` picks which equality predicate keys
//! are compared with and which hash goes with it.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const equality = @import("../runtime/equality.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const HashTest = heap.HashTest;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerHashTables(ev: *Evaluator) !void {
    _ = try ev.defineNative("MAKE-HASH-TABLE", &makeHashTableFn);
    _ = try ev.defineNative("HASH-TABLE-P", &hashTablePFn);
    _ = try ev.defineNative("%PUTHASH", &puthashFn);
    _ = try ev.defineNative("REMHASH", &remhashFn);
    _ = try ev.defineNative("CLRHASH", &clrhashFn);
    _ = try ev.defineNative("MAPHASH", &maphashFn);
    _ = try ev.defineNative("%HASH-TABLE-ENTRIES", &entriesFn);
    _ = try ev.defineNative("HASH-TABLE-COUNT", &countFn);
    _ = try ev.defineNative("HASH-TABLE-SIZE", &sizeFn);
    _ = try ev.defineNative("HASH-TABLE-TEST", &testFn);
    _ = try ev.defineNative("HASH-TABLE-REHASH-SIZE", &rehashSizeFn);
    _ = try ev.defineNative("HASH-TABLE-REHASH-THRESHOLD", &rehashThresholdFn);

    // `gethash` hands back a present-flag alongside the value.
    function.asFunction(try ev.defineNative("GETHASH", &gethashFn)).preserves_values = true;

    for ([_][]const u8{ "EQ", "EQL", "EQUAL", "EQUALP" }) |n| {
        _ = try ev.interner.intern(n);
    }
}

pub fn isHashTable(v: Value) bool {
    return v.tag() == .heap and heap.heapType(v) == .hash_table;
}

fn expectTable(v: Value) Error!*heap.HeapHashTable {
    if (!isHashTable(v)) return Error.TypeError;
    return heap.asHashTable(v);
}

// --- construction ---

const DEFAULT_SIZE: u64 = 16;

fn testFromDesignator(v: Value) Error!HashTest {
    if (!v.isSymbol()) return Error.TypeError;
    const n = symbol_mod.symbol(v).name;
    if (std.mem.eql(u8, n, "EQ")) return .eq;
    if (std.mem.eql(u8, n, "EQL")) return .eql;
    if (std.mem.eql(u8, n, "EQUAL")) return .equal;
    if (std.mem.eql(u8, n, "EQUALP")) return .equalp;
    return Error.TypeError;
}

fn testName(kind: HashTest) []const u8 {
    return switch (kind) {
        .eq => "EQ",
        .eql => "EQL",
        .equal => "EQUAL",
        .equalp => "EQUALP",
    };
}

/// A `:test` argument may be the symbol or the function it names.
fn testFromArgument(ev: *Evaluator, given: Value) Error!HashTest {
    if (function.isFunction(given)) {
        const name = function.asFunction(given).name orelse return Error.TypeError;
        return testFromDesignator(ev.interner.lookup(name) orelse return Error.TypeError);
    }
    return testFromDesignator(given);
}

fn makeHashTableFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len % 2 != 0) return Error.WrongArgCount;

    var hash_test: HashTest = .eql;
    var size: u64 = DEFAULT_SIZE;
    var rehash_size = value.NIL;
    var rehash_threshold = value.NIL;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const given = args[i + 1];
        if (try keywordIs(ev, args[i], "TEST")) {
            hash_test = try testFromArgument(ev, given);
        } else if (try keywordIs(ev, args[i], "SIZE")) {
            if (!given.isFixnum() or given.toFixnum() < 0) return Error.TypeError;
            size = @intCast(given.toFixnum());
        } else if (try keywordIs(ev, args[i], "REHASH-SIZE")) {
            if (!equality.isNumber(given)) return Error.TypeError;
            rehash_size = given;
        } else if (try keywordIs(ev, args[i], "REHASH-THRESHOLD")) {
            if (!equality.isNumber(given)) return Error.TypeError;
            rehash_threshold = given;
        } else return Error.ProgramError;
    }
    return ev.heap.allocHashTableWith(hash_test, size, rehash_size, rehash_threshold);
}

fn keywordIs(ev: *Evaluator, key: Value, name: []const u8) Error!bool {
    return key.equalsRaw(try ev.interner.internKeyword(name));
}

fn hashTablePFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return if (isHashTable(args[0])) value.T else value.NIL;
}

// --- lookup and update ---

/// Index of the live entry holding `key`, or null.
fn findEntry(table: *heap.HeapHashTable, key: Value) ?u32 {
    const bucket = table.buckets.get(equality.hash(table.hash_test, key)) orelse return null;
    for (bucket.items) |index| {
        const entry = table.entries.items[index];
        if (entry.live and equality.matches(table.hash_test, entry.key, key)) return index;
    }
    return null;
}

fn gethashFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    const table = try expectTable(args[1]);
    if (findEntry(table, args[0])) |index| {
        return ev.setValues(&.{ table.entries.items[index].value, value.T });
    }
    const default = if (args.len == 3) args[2] else value.NIL;
    return ev.setValues(&.{ default, value.NIL });
}

fn puthashFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    const table = try expectTable(args[1]);
    if (findEntry(table, args[0])) |index| {
        table.entries.items[index].value = args[2];
        return args[2];
    }

    const allocator = ev.heap.allocator;
    const index: u32 = @intCast(table.entries.items.len);
    try table.entries.append(allocator, .{ .key = args[0], .value = args[2], .live = true });
    const slot = try table.buckets.getOrPut(allocator, equality.hash(table.hash_test, args[0]));
    if (!slot.found_existing) slot.value_ptr.* = .empty;
    try slot.value_ptr.append(allocator, index);
    table.live_count += 1;
    return args[2];
}

fn remhashFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const table = try expectTable(args[1]);
    const index = findEntry(table, args[0]) orelse return value.NIL;
    table.entries.items[index].live = false;
    table.live_count -= 1;
    return value.T;
}

fn clrhashFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const table = try expectTable(args[0]);
    var it = table.buckets.valueIterator();
    while (it.next()) |bucket| bucket.deinit(ev.heap.allocator);
    table.buckets.clearRetainingCapacity();
    table.entries.clearRetainingCapacity();
    table.live_count = 0;
    return args[0];
}

// --- traversal ---

fn maphashFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const fn_v = try callable(ev, args[0]);
    const table = try expectTable(args[1]);
    // Index rather than iterate: the function may add entries, and the
    // ones present when the walk started are the ones it must see.
    const seen = table.entries.items.len;
    var i: usize = 0;
    while (i < seen) : (i += 1) {
        const entry = table.entries.items[i];
        if (!entry.live) continue;
        _ = try ev.callFunction(fn_v, &.{ entry.key, entry.value });
    }
    return value.NIL;
}

/// The live pairs as a list of `(key . value)`, which is what
/// `with-hash-table-iterator` walks.
fn entriesFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const table = try expectTable(args[0]);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(value.NIL);
    try held.push(value.NIL);
    var list = value.NIL;
    var i: usize = table.entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = table.entries.items[i];
        if (!entry.live) continue;
        const pair = try ev.heap.allocCons(entry.key, entry.value);
        held.setItem(1, pair);
        list = try ev.heap.allocCons(pair, list);
        held.setItem(0, list);
    }
    return list;
}

fn callable(ev: *Evaluator, designator: Value) Error!Value {
    if (function.isFunction(designator)) return designator;
    if (designator.isSymbol()) {
        return ev.env.lookupFunction(designator) orelse
            ev.unbound(designator, Error.UnboundFunction);
    }
    return Error.TypeError;
}

// --- introspection ---

fn countFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return Value.fromFixnum(@intCast((try expectTable(args[0])).live_count));
}

/// The capacity, which is the requested size until the table outgrows it.
fn sizeFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    const table = try expectTable(args[0]);
    return Value.fromFixnum(@intCast(@max(table.requested_size, table.live_count)));
}

fn testFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return ev.interner.intern(testName((try expectTable(args[0])).hash_test));
}

fn rehashSizeFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return (try expectTable(args[0])).rehash_size;
}

fn rehashThresholdFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return (try expectTable(args[0])).rehash_threshold;
}
