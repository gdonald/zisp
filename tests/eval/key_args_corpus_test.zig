//! &key argument acceptance corpus.
//!
//! Reads `tests/lisp/key-args-corpus.lisp`. Each form calls a lambda via
//! funcall and returns a list of the bound values; the driver compares that
//! list against the one SBCL produces (recorded as the first token).

const std = @import("std");
const zisp = @import("zisp");
const value = zisp.value;
const symbol_mod = zisp.symbol;
const heap_mod = zisp.heap;
const Tokenizer = zisp.reader.Tokenizer;
const Reader = zisp.reader.Reader;
const Evaluator = zisp.eval.Evaluator;

const corpus_text = @embedFile("../lisp/key-args-corpus.lisp");

const Elem = union(enum) { nil, t, fixnum: i64 };

const ParseError = error{MalformedCorpusLine};

fn nativeFuncall(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    const ev = Evaluator.fromOpaque(ev_opaque);
    if (args.len == 0) return error.WrongArgCount;
    return ev.callFunction(args[0], args[1..]);
}

fn nativeList(ev_opaque: *anyopaque, args: []const value.Value) zisp.eval.function.NativeError!value.Value {
    const ev = Evaluator.fromOpaque(ev_opaque);
    var list = value.NIL;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(args[i], list);
    }
    return list;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        _ = try fx.ev.defineNative("FUNCALL", &nativeFuncall);
        _ = try fx.ev.defineNative("LIST", &nativeList);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

fn parseExpected(allocator: std.mem.Allocator, spec: []const u8) ![]Elem {
    var list: std.ArrayList(Elem) = .empty;
    errdefer list.deinit(allocator);
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "NIL")) {
            try list.append(allocator, .nil);
        } else if (std.mem.eql(u8, part, "T")) {
            try list.append(allocator, .t);
        } else {
            const n = std.fmt.parseInt(i64, part, 10) catch return ParseError.MalformedCorpusLine;
            try list.append(allocator, .{ .fixnum = n });
        }
    }
    return list.toOwnedSlice(allocator);
}

test "key-args corpus matches SBCL result lists" {
    const gpa = std.testing.allocator;
    var iter = std.mem.splitScalar(u8, corpus_text, '\n');
    var line_no: u32 = 0;
    var checked: u32 = 0;
    while (iter.next()) |raw| {
        line_no += 1;
        var i: usize = 0;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        if (i == raw.len) continue;
        if (raw[i] == ';') continue;

        const rest = raw[i..];
        const sep = std.mem.indexOfAny(u8, rest, " \t") orelse return ParseError.MalformedCorpusLine;
        const spec = rest[0..sep];
        const form_src = std.mem.trim(u8, rest[sep..], " \t");
        if (form_src.len == 0) return ParseError.MalformedCorpusLine;

        const expected = try parseExpected(gpa, spec);
        defer gpa.free(expected);

        const fx = try Fixture.init(gpa);
        defer fx.deinit(gpa);

        var tk = Tokenizer.init(form_src);
        var rd = Reader.init(&tk, &fx.heap, &fx.interner);
        const form = (try rd.read()) orelse return ParseError.MalformedCorpusLine;

        const got = fx.ev.eval(form) catch |e| {
            std.debug.print("corpus line {d}: eval error {s}\n  >> {s}\n", .{ line_no, @errorName(e), form_src });
            return e;
        };

        var cur = got;
        for (expected) |want| {
            if (!cur.isCons()) {
                std.debug.print("corpus line {d}: result list too short\n  >> {s}\n", .{ line_no, form_src });
                return error.TestUnexpectedResult;
            }
            const have = heap_mod.car(cur);
            switch (want) {
                .nil => if (!have.equalsRaw(value.NIL)) {
                    std.debug.print("corpus line {d}: expected NIL element\n  >> {s}\n", .{ line_no, form_src });
                    return error.TestUnexpectedResult;
                },
                .t => if (!have.equalsRaw(value.T)) {
                    std.debug.print("corpus line {d}: expected T element\n  >> {s}\n", .{ line_no, form_src });
                    return error.TestUnexpectedResult;
                },
                .fixnum => |n| if (have.tag() != .fixnum or have.toFixnum() != n) {
                    std.debug.print("corpus line {d}: expected {d}\n  >> {s}\n", .{ line_no, n, form_src });
                    return error.TestUnexpectedResult;
                },
            }
            cur = heap_mod.cdr(cur);
        }
        if (!cur.equalsRaw(value.NIL)) {
            std.debug.print("corpus line {d}: result list too long\n  >> {s}\n", .{ line_no, form_src });
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try std.testing.expectEqual(@as(u32, 25), checked);
}
