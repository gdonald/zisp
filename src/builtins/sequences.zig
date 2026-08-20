//! Sequence builtins, generic over lists, vectors and strings.
//!
//! The algorithms work on a materialized element slice and rebuild a
//! sequence of the caller's kind at the end, so one implementation covers
//! all three representations.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const equality = @import("../runtime/equality.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerSequences(ev: *Evaluator) !void {
    _ = try ev.defineNative("CONCATENATE", &concatenateFn);
    _ = try ev.defineNative("COPY-SEQ", &copySeqFn);
    _ = try ev.defineNative("SUBSEQ", &subseqFn);
    _ = try ev.defineNative("REVERSE", &reverseFn);
    _ = try ev.defineNative("NREVERSE", &reverseFn);
    _ = try ev.defineNative("MAP", &mapFn);
    _ = try ev.defineNative("MAP-INTO", &mapIntoFn);
    _ = try ev.defineNative("REDUCE", &reduceFn);
    _ = try ev.defineNative("COUNT", &countFn);
    _ = try ev.defineNative("COUNT-IF", &countIfFn);
    _ = try ev.defineNative("COUNT-IF-NOT", &countIfNotFn);
    _ = try ev.defineNative("FIND", &findFn);
    _ = try ev.defineNative("FIND-IF", &findIfFn);
    _ = try ev.defineNative("FIND-IF-NOT", &findIfNotFn);
    _ = try ev.defineNative("POSITION", &positionFn);
    _ = try ev.defineNative("POSITION-IF", &positionIfFn);
    _ = try ev.defineNative("POSITION-IF-NOT", &positionIfNotFn);
    _ = try ev.defineNative("REMOVE", &removeFn);
    _ = try ev.defineNative("DELETE", &removeFn);
    _ = try ev.defineNative("REMOVE-IF", &removeIfFn);
    _ = try ev.defineNative("DELETE-IF", &removeIfFn);
    _ = try ev.defineNative("REMOVE-IF-NOT", &removeIfNotFn);
    _ = try ev.defineNative("DELETE-IF-NOT", &removeIfNotFn);
    _ = try ev.defineNative("SUBSTITUTE", &substituteFn);
    _ = try ev.defineNative("NSUBSTITUTE", &substituteFn);
    _ = try ev.defineNative("SORT", &sortFn);
    _ = try ev.defineNative("STABLE-SORT", &sortFn);
    _ = try ev.defineNative("MERGE", &mergeFn);
}

// --- sequence views ---

const Kind = enum { list, vector, string };

fn kindOf(v: Value) Error!Kind {
    if (v.equalsRaw(value.NIL) or v.isCons()) return .list;
    if (heap.isString(v)) return .string;
    if (v.tag() == .heap and heap.heapType(v) == .vector) return .vector;
    return Error.TypeError;
}

/// Append every element of `seq` to `out`. A string's elements come back
/// as characters, matching what `elt` yields.
fn collectElements(ev: *Evaluator, seq: Value, out: *std.ArrayList(Value)) Error!void {
    switch (try kindOf(seq)) {
        .list => {
            var rest = seq;
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                try out.append(ev.allocator, heap.car(rest));
            }
            if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
        },
        .string => for (heap.asString(seq).constSlice()) |c| {
            try out.append(ev.allocator, Value.fromChar(@intCast(c)));
        },
        .vector => for (heap.arrayActive(seq)) |element| {
            try out.append(ev.allocator, element);
        },
    }
}

fn build(ev: *Evaluator, kind: Kind, elements: []const Value) Error!Value {
    return switch (kind) {
        .list => listOf(ev, elements),
        .vector => ev.heap.allocVector(elements),
        .string => stringOf(ev, elements),
    };
}

fn listOf(ev: *Evaluator, elements: []const Value) Error!Value {
    const list = try ev.heap.list(elements);
    return list;
}

fn stringOf(ev: *Evaluator, elements: []const Value) Error!Value {
    const result = try ev.heap.allocStringUninitialized(elements.len);
    const chars = heap.asString(result).slice();
    for (elements, chars) |element, *c| {
        if (element.tag() != .char) return Error.TypeError;
        c.* = element.toChar();
    }
    return result;
}

// --- concatenate ---

fn resultKindOf(spec: Value) Error!Kind {
    if (spec.equalsRaw(value.NIL)) return .list;
    if (!spec.isSymbol()) return Error.TypeError;
    const n = symbol_mod.symbol(spec).name;
    if (std.mem.eql(u8, n, "LIST") or std.mem.eql(u8, n, "NULL")) return .list;
    if (std.mem.eql(u8, n, "VECTOR") or std.mem.eql(u8, n, "SIMPLE-VECTOR") or
        std.mem.eql(u8, n, "ARRAY") or std.mem.eql(u8, n, "SIMPLE-ARRAY")) return .vector;
    if (std.mem.eql(u8, n, "STRING") or std.mem.eql(u8, n, "SIMPLE-STRING") or
        std.mem.eql(u8, n, "BASE-STRING") or std.mem.eql(u8, n, "SIMPLE-BASE-STRING")) return .string;
    return Error.TypeError;
}

fn concatenateFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1) return Error.WrongArgCount;
    const kind = try resultKindOf(args[0]);

    var elements: std.ArrayList(Value) = .empty;
    defer elements.deinit(ev.allocator);
    for (args[1..]) |seq| {
        try collectElements(ev, seq, &elements);
    }
    return build(ev, kind, elements.items);
}

// --- copying and slicing ---

fn copySeqFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var elements: std.ArrayList(Value) = .empty;
    defer elements.deinit(ev.allocator);
    try collectElements(ev, args[0], &elements);
    return build(ev, try kindOf(args[0]), elements.items);
}

/// A bounding index: nil means "leave the default", anything else must be
/// a non-negative integer no larger than `limit`.
fn boundValue(v: Value, limit: usize) Error!?usize {
    if (v.equalsRaw(value.NIL)) return null;
    if (!v.isFixnum() or v.toFixnum() < 0) return Error.TypeError;
    const n: usize = @intCast(v.toFixnum());
    if (n > limit) return Error.TypeError;
    return n;
}

fn subseqFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    var elements: std.ArrayList(Value) = .empty;
    defer elements.deinit(ev.allocator);
    try collectElements(ev, args[0], &elements);

    const start = (try boundValue(args[1], elements.items.len)) orelse 0;
    const end = if (args.len == 3)
        (try boundValue(args[2], elements.items.len)) orelse elements.items.len
    else
        elements.items.len;
    if (start > end) return Error.TypeError;
    return build(ev, try kindOf(args[0]), elements.items[start..end]);
}

/// `reverse` copies and `nreverse` is free to destroy, so both land here.
fn reverseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var elements: std.ArrayList(Value) = .empty;
    defer elements.deinit(ev.allocator);
    try collectElements(ev, args[0], &elements);
    std.mem.reverse(Value, elements.items);
    return build(ev, try kindOf(args[0]), elements.items);
}

// --- keyword options ---

const OptionKey = enum { key, test_fn, test_not, start, end, from_end, count, initial_value };
const OptionSet = std.EnumSet(OptionKey);

fn keywordName(option: OptionKey) []const u8 {
    return switch (option) {
        .key => "KEY",
        .test_fn => "TEST",
        .test_not => "TEST-NOT",
        .start => "START",
        .end => "END",
        .from_end => "FROM-END",
        .count => "COUNT",
        .initial_value => "INITIAL-VALUE",
    };
}

/// The standard sequence keyword arguments. Each caller declares which of
/// them it accepts; anything else in the argument list is an error.
const Options = struct {
    key: ?Value = null,
    test_fn: ?Value = null,
    test_not: ?Value = null,
    start: usize = 0,
    end: ?usize = null,
    from_end: bool = false,
    count: ?i64 = null,
    initial_value: ?Value = null,

    fn parse(ev: *Evaluator, args: []const Value, allowed: OptionSet) Error!Options {
        if (args.len % 2 != 0) return Error.WrongArgCount;
        var options = Options{};
        var i: usize = 0;
        outer: while (i < args.len) : (i += 2) {
            const given = args[i + 1];
            for (std.enums.values(OptionKey)) |option| {
                if (!allowed.contains(option)) continue;
                if (!args[i].equalsRaw(try ev.interner.internKeyword(keywordName(option)))) continue;
                try options.set(ev, option, given);
                continue :outer;
            }
            return Error.ProgramError;
        }
        if (options.test_fn != null and options.test_not != null) return Error.ProgramError;
        return options;
    }

    fn set(self: *Options, ev: *Evaluator, option: OptionKey, given: Value) Error!void {
        switch (option) {
            .key => self.key = if (given.equalsRaw(value.NIL)) null else try callable(ev, given),
            .test_fn => self.test_fn = try callable(ev, given),
            .test_not => self.test_not = try callable(ev, given),
            .start => self.start = (try boundValue(given, std.math.maxInt(i32))) orelse 0,
            .end => self.end = try boundValue(given, std.math.maxInt(i32)),
            .from_end => self.from_end = !given.equalsRaw(value.NIL),
            .count => self.count = try countLimit(given),
            .initial_value => self.initial_value = given,
        }
    }

    /// Clamp `:start` / `:end` to a sequence of `len` elements.
    fn region(self: Options, len: usize) Error!struct { start: usize, end: usize } {
        const end = self.end orelse len;
        if (self.start > len or end > len or self.start > end) return Error.TypeError;
        return .{ .start = self.start, .end = end };
    }
};

fn countLimit(given: Value) Error!?i64 {
    if (given.equalsRaw(value.NIL)) return null;
    if (!given.isFixnum()) return Error.TypeError;
    return given.toFixnum();
}

fn callable(ev: *Evaluator, designator: Value) Error!Value {
    if (function.isFunction(designator)) return designator;
    if (designator.isSymbol()) {
        return ev.env.lookupFunction(designator) orelse
            ev.unbound(designator, Error.UnboundFunction);
    }
    return Error.TypeError;
}

fn truthy(v: Value) bool {
    return !v.equalsRaw(value.NIL);
}

/// The element as the `:key` function sees it.
fn keyed(ev: *Evaluator, options: Options, element: Value) Error!Value {
    if (options.key) |k| return ev.callFunction(k, &.{element});
    return element;
}

/// Whether `element` matches `item` under `:test` / `:test-not`, defaulting
/// to `eql`.
fn itemMatches(ev: *Evaluator, options: Options, item: Value, element: Value) Error!bool {
    const subject = try keyed(ev, options, element);
    if (options.test_not) |t| return !truthy(try ev.callFunction(t, &.{ item, subject }));
    if (options.test_fn) |t| return truthy(try ev.callFunction(t, &.{ item, subject }));
    return equality.eql(item, subject);
}

/// Whether `element` satisfies a predicate, optionally inverted for the
/// `-if-not` variants.
fn predicateHolds(ev: *Evaluator, options: Options, pred: Value, element: Value, negate: bool) Error!bool {
    const held = truthy(try ev.callFunction(pred, &.{try keyed(ev, options, element)}));
    return held != negate;
}

/// Elements of a sequence, materialized so every algorithm can index them.
const Elements = struct {
    items: std.ArrayList(Value) = .empty,
    kind: Kind = .list,

    fn of(ev: *Evaluator, seq: Value) Error!Elements {
        var self = Elements{ .kind = try kindOf(seq) };
        try collectElements(ev, seq, &self.items);
        return self;
    }

    fn deinit(self: *Elements, ev: *Evaluator) void {
        self.items.deinit(ev.allocator);
    }
};

// --- map ---

fn mapFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const want_result = !args[0].equalsRaw(value.NIL);
    const kind = if (want_result) try resultKindOf(args[0]) else Kind.list;
    const fn_v = try callable(ev, args[1]);

    var produced: std.ArrayList(Value) = .empty;
    defer produced.deinit(ev.allocator);
    try mapOver(ev, fn_v, args[2..], &produced);
    if (!want_result) return value.NIL;
    return build(ev, kind, produced.items);
}

/// Call `fn_v` on corresponding elements of every sequence, stopping at the
/// shortest, collecting each result.
fn mapOver(
    ev: *Evaluator,
    fn_v: Value,
    seqs: []const Value,
    produced: *std.ArrayList(Value),
) Error!void {
    if (seqs.len == 0) return Error.WrongArgCount;

    var collected: std.ArrayList(Elements) = .empty;
    defer {
        for (collected.items) |*e| e.deinit(ev);
        collected.deinit(ev.allocator);
    }
    var shortest: usize = std.math.maxInt(usize);
    for (seqs) |seq| {
        const elements = try Elements.of(ev, seq);
        try collected.append(ev.allocator, elements);
        shortest = @min(shortest, elements.items.items.len);
    }

    var call_args: std.ArrayList(Value) = .empty;
    defer call_args.deinit(ev.allocator);
    var i: usize = 0;
    while (i < shortest) : (i += 1) {
        call_args.clearRetainingCapacity();
        for (collected.items) |elements| {
            try call_args.append(ev.allocator, elements.items.items[i]);
        }
        try produced.append(ev.allocator, try ev.callFunction(fn_v, call_args.items));
    }
}

/// `map-into` writes into an existing sequence and returns it, filling at
/// most as many elements as that sequence already has.
fn mapIntoFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const target = args[0];
    const fn_v = try callable(ev, args[1]);

    var produced: std.ArrayList(Value) = .empty;
    defer produced.deinit(ev.allocator);
    try mapOver(ev, fn_v, args[2..], &produced);

    switch (try kindOf(target)) {
        .list => {
            var rest = target;
            var i: usize = 0;
            while (rest.isCons() and i < produced.items.len) : (i += 1) {
                heap.setCar(rest, produced.items[i]);
                rest = heap.cdr(rest);
            }
        },
        .vector => {
            const slots = heap.arrayActive(target);
            for (slots, 0..) |*slot, i| {
                if (i >= produced.items.len) break;
                slot.* = produced.items[i];
            }
        },
        .string => {
            const chars = heap.asString(target).slice();
            for (chars, 0..) |*c, i| {
                if (i >= produced.items.len) break;
                const element = produced.items[i];
                if (element.tag() != .char) return Error.TypeError;
                c.* = element.toChar();
            }
        },
    }
    return target;
}

// --- reduce ---

const REDUCE_OPTIONS = OptionSet.initMany(&.{ .key, .from_end, .start, .end, .initial_value });

fn reduceFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const fn_v = try callable(ev, args[0]);
    const options = try Options.parse(ev, args[2..], REDUCE_OPTIONS);

    var elements = try Elements.of(ev, args[1]);
    defer elements.deinit(ev);
    const region = try options.region(elements.items.items.len);

    var subjects: std.ArrayList(Value) = .empty;
    defer subjects.deinit(ev.allocator);
    for (elements.items.items[region.start..region.end]) |element| {
        try subjects.append(ev.allocator, try keyed(ev, options, element));
    }
    if (options.from_end) std.mem.reverse(Value, subjects.items);

    var accumulator: Value = undefined;
    var rest: []const Value = undefined;
    if (options.initial_value) |seed| {
        accumulator = seed;
        rest = subjects.items;
    } else {
        // With no seed and no elements the function is called on nothing.
        if (subjects.items.len == 0) return ev.callFunction(fn_v, &.{});
        accumulator = subjects.items[0];
        rest = subjects.items[1..];
    }
    for (rest) |subject| {
        accumulator = if (options.from_end)
            try ev.callFunction(fn_v, &.{ subject, accumulator })
        else
            try ev.callFunction(fn_v, &.{ accumulator, subject });
    }
    return accumulator;
}

// --- searching and counting ---

const ITEM_OPTIONS = OptionSet.initMany(&.{ .key, .test_fn, .test_not, .start, .end, .from_end });
const PREDICATE_OPTIONS = OptionSet.initMany(&.{ .key, .start, .end, .from_end });

/// What a search returns once it has an index: the element, its position,
/// or nothing at all for a counting pass.
const Want = enum { element, position };

/// Walk the region, in reverse when `:from-end` is set, calling `hit` for
/// each index whose element matches.
fn scan(
    ev: *Evaluator,
    elements: []const Value,
    options: Options,
    matcher: Matcher,
    want: Want,
) Error!Value {
    const region = try options.region(elements.len);
    var i: usize = region.start;
    while (i < region.end) : (i += 1) {
        const index = if (options.from_end) region.end - 1 - (i - region.start) else i;
        if (try matcher.matches(ev, options, elements[index])) {
            return switch (want) {
                .element => elements[index],
                .position => Value.fromFixnum(@intCast(index)),
            };
        }
    }
    return value.NIL;
}

/// Either an item compared under `:test`, or a predicate applied to each
/// element, possibly inverted.
const Matcher = union(enum) {
    item: Value,
    predicate: struct { fn_v: Value, negate: bool },

    fn matches(self: Matcher, ev: *Evaluator, options: Options, element: Value) Error!bool {
        return switch (self) {
            .item => |item| itemMatches(ev, options, item, element),
            .predicate => |pred| predicateHolds(ev, options, pred.fn_v, element, pred.negate),
        };
    }
};

/// Shared entry for `find` / `position` / `count` and their `-if` forms.
fn search(ev: *Evaluator, args: []const Value, spec: SearchSpec) Error!Value {
    if (args.len < 2) return Error.WrongArgCount;
    const options = try Options.parse(ev, args[2..], spec.allowed);
    const matcher: Matcher = if (spec.predicate)
        .{ .predicate = .{ .fn_v = try callable(ev, args[0]), .negate = spec.negate } }
    else
        .{ .item = args[0] };

    var elements = try Elements.of(ev, args[1]);
    defer elements.deinit(ev);
    if (spec.want) |want| return scan(ev, elements.items.items, options, matcher, want);

    const region = try options.region(elements.items.items.len);
    var total: i64 = 0;
    for (elements.items.items[region.start..region.end]) |element| {
        if (try matcher.matches(ev, options, element)) total += 1;
    }
    return Value.fromFixnum(total);
}

/// One search entry point: what it matches on, and what it returns. A null
/// `want` means it counts instead of returning a hit.
const SearchSpec = struct {
    predicate: bool,
    negate: bool = false,
    want: ?Want,
    allowed: OptionSet,
};

fn findFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{ .predicate = false, .want = .element, .allowed = ITEM_OPTIONS });
}

fn findIfFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{ .predicate = true, .want = .element, .allowed = PREDICATE_OPTIONS });
}

fn findIfNotFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{
        .predicate = true,
        .negate = true,
        .want = .element,
        .allowed = PREDICATE_OPTIONS,
    });
}

fn positionFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{ .predicate = false, .want = .position, .allowed = ITEM_OPTIONS });
}

fn positionIfFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{ .predicate = true, .want = .position, .allowed = PREDICATE_OPTIONS });
}

fn positionIfNotFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{
        .predicate = true,
        .negate = true,
        .want = .position,
        .allowed = PREDICATE_OPTIONS,
    });
}

fn countFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{ .predicate = false, .want = null, .allowed = ITEM_OPTIONS });
}

fn countIfFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{ .predicate = true, .want = null, .allowed = PREDICATE_OPTIONS });
}

fn countIfNotFn(p: *anyopaque, args: []const Value) Error!Value {
    return search(evaluator(p), args, .{
        .predicate = true,
        .negate = true,
        .want = null,
        .allowed = PREDICATE_OPTIONS,
    });
}

// --- removal and substitution ---

const REMOVE_ITEM_OPTIONS = OptionSet.initMany(&.{
    .key, .test_fn, .test_not, .start, .end, .from_end, .count,
});
const REMOVE_PREDICATE_OPTIONS = OptionSet.initMany(&.{ .key, .start, .end, .from_end, .count });

/// Mark the elements a removal or substitution acts on. `:count` caps how
/// many are marked, taken from the end when `:from-end` is set.
fn markMatches(
    ev: *Evaluator,
    elements: []const Value,
    options: Options,
    matcher: Matcher,
    marks: []bool,
) Error!void {
    const region = try options.region(elements.len);
    var budget: i64 = options.count orelse std.math.maxInt(i64);
    var i: usize = region.start;
    while (i < region.end and budget > 0) : (i += 1) {
        const index = if (options.from_end) region.end - 1 - (i - region.start) else i;
        if (try matcher.matches(ev, options, elements[index])) {
            marks[index] = true;
            budget -= 1;
        }
    }
}

fn removeMarked(ev: *Evaluator, elements: Elements, marks: []const bool) Error!Value {
    var kept: std.ArrayList(Value) = .empty;
    defer kept.deinit(ev.allocator);
    for (elements.items.items, marks) |element, marked| {
        if (!marked) try kept.append(ev.allocator, element);
    }
    return build(ev, elements.kind, kept.items);
}

fn removeWith(ev: *Evaluator, args: []const Value, spec: SearchSpec) Error!Value {
    if (args.len < 2) return Error.WrongArgCount;
    const options = try Options.parse(ev, args[2..], spec.allowed);
    const matcher: Matcher = if (spec.predicate)
        .{ .predicate = .{ .fn_v = try callable(ev, args[0]), .negate = spec.negate } }
    else
        .{ .item = args[0] };

    var elements = try Elements.of(ev, args[1]);
    defer elements.deinit(ev);
    const marks = try ev.allocator.alloc(bool, elements.items.items.len);
    defer ev.allocator.free(marks);
    @memset(marks, false);

    try markMatches(ev, elements.items.items, options, matcher, marks);
    return removeMarked(ev, elements, marks);
}

fn removeFn(p: *anyopaque, args: []const Value) Error!Value {
    return removeWith(evaluator(p), args, .{
        .predicate = false,
        .want = null,
        .allowed = REMOVE_ITEM_OPTIONS,
    });
}

fn removeIfFn(p: *anyopaque, args: []const Value) Error!Value {
    return removeWith(evaluator(p), args, .{
        .predicate = true,
        .want = null,
        .allowed = REMOVE_PREDICATE_OPTIONS,
    });
}

fn removeIfNotFn(p: *anyopaque, args: []const Value) Error!Value {
    return removeWith(evaluator(p), args, .{
        .predicate = true,
        .negate = true,
        .want = null,
        .allowed = REMOVE_PREDICATE_OPTIONS,
    });
}

/// `substitute` and `nsubstitute` replace every marked element; the
/// destructive one is free to return a fresh sequence.
fn substituteFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 3) return Error.WrongArgCount;
    const options = try Options.parse(ev, args[3..], REMOVE_ITEM_OPTIONS);

    var elements = try Elements.of(ev, args[2]);
    defer elements.deinit(ev);
    const marks = try ev.allocator.alloc(bool, elements.items.items.len);
    defer ev.allocator.free(marks);
    @memset(marks, false);

    try markMatches(ev, elements.items.items, options, .{ .item = args[1] }, marks);
    for (elements.items.items, marks) |*element, marked| {
        if (marked) element.* = args[0];
    }
    return build(ev, elements.kind, elements.items.items);
}

// --- sorting ---

const SORT_OPTIONS = OptionSet.initMany(&.{.key});

/// Strict ordering under the caller's predicate, seen through `:key`.
fn precedes(ev: *Evaluator, options: Options, pred: Value, a: Value, b: Value) Error!bool {
    const ka = try keyed(ev, options, a);
    const kb = try keyed(ev, options, b);
    return truthy(try ev.callFunction(pred, &.{ ka, kb }));
}

/// Bottom-up merge sort. Stable, and its comparator can fail, which
/// std.sort's cannot.
fn mergeSort(
    ev: *Evaluator,
    options: Options,
    pred: Value,
    items: []Value,
    scratch: []Value,
) Error!void {
    if (items.len < 2) return;
    const middle = items.len / 2;
    try mergeSort(ev, options, pred, items[0..middle], scratch[0..middle]);
    try mergeSort(ev, options, pred, items[middle..], scratch[middle..]);
    @memcpy(scratch, items);
    try mergeRuns(ev, options, pred, scratch[0..middle], scratch[middle..], items);
}

/// Merge two ordered runs into `out`, taking from `left` on a tie so equal
/// elements keep their original order.
fn mergeRuns(
    ev: *Evaluator,
    options: Options,
    pred: Value,
    left: []const Value,
    right: []const Value,
    out: []Value,
) Error!void {
    var i: usize = 0;
    var j: usize = 0;
    var o: usize = 0;
    while (i < left.len and j < right.len) : (o += 1) {
        if (try precedes(ev, options, pred, right[j], left[i])) {
            out[o] = right[j];
            j += 1;
        } else {
            out[o] = left[i];
            i += 1;
        }
    }
    while (i < left.len) : ({
        i += 1;
        o += 1;
    }) out[o] = left[i];
    while (j < right.len) : ({
        j += 1;
        o += 1;
    }) out[o] = right[j];
}

fn sortFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const pred = try callable(ev, args[1]);
    const options = try Options.parse(ev, args[2..], SORT_OPTIONS);

    var elements = try Elements.of(ev, args[0]);
    defer elements.deinit(ev);
    const scratch = try ev.allocator.alloc(Value, elements.items.items.len);
    defer ev.allocator.free(scratch);
    try mergeSort(ev, options, pred, elements.items.items, scratch);
    return build(ev, elements.kind, elements.items.items);
}

fn mergeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 4) return Error.WrongArgCount;
    const kind = try resultKindOf(args[0]);
    const pred = try callable(ev, args[3]);
    const options = try Options.parse(ev, args[4..], SORT_OPTIONS);

    var left = try Elements.of(ev, args[1]);
    defer left.deinit(ev);
    var right = try Elements.of(ev, args[2]);
    defer right.deinit(ev);

    const total = left.items.items.len + right.items.items.len;
    const out = try ev.allocator.alloc(Value, total);
    defer ev.allocator.free(out);
    try mergeRuns(ev, options, pred, left.items.items, right.items.items, out);
    return build(ev, kind, out);
}
