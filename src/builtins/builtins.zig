const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

fn isNil(v: Value) bool {
    return v.equalsRaw(value.NIL);
}

const Cxr = struct { name: []const u8, seq: []const u8 };

const cxr_table = [_]Cxr{
    .{ .name = "CAAR", .seq = "aa" },     .{ .name = "CADR", .seq = "ad" },
    .{ .name = "CDAR", .seq = "da" },     .{ .name = "CDDR", .seq = "dd" },
    .{ .name = "CAAAR", .seq = "aaa" },   .{ .name = "CAADR", .seq = "aad" },
    .{ .name = "CADAR", .seq = "ada" },   .{ .name = "CADDR", .seq = "add" },
    .{ .name = "CDAAR", .seq = "daa" },   .{ .name = "CDADR", .seq = "dad" },
    .{ .name = "CDDAR", .seq = "dda" },   .{ .name = "CDDDR", .seq = "ddd" },
    .{ .name = "CAAAAR", .seq = "aaaa" }, .{ .name = "CAAADR", .seq = "aaad" },
    .{ .name = "CAADAR", .seq = "aada" }, .{ .name = "CAADDR", .seq = "aadd" },
    .{ .name = "CADAAR", .seq = "adaa" }, .{ .name = "CADADR", .seq = "adad" },
    .{ .name = "CADDAR", .seq = "adda" }, .{ .name = "CADDDR", .seq = "addd" },
    .{ .name = "CDAAAR", .seq = "daaa" }, .{ .name = "CDAADR", .seq = "daad" },
    .{ .name = "CDADAR", .seq = "dada" }, .{ .name = "CDADDR", .seq = "dadd" },
    .{ .name = "CDDAAR", .seq = "ddaa" }, .{ .name = "CDDADR", .seq = "ddad" },
    .{ .name = "CDDDAR", .seq = "ddda" }, .{ .name = "CDDDDR", .seq = "dddd" },
};

const ordinals = [_][]const u8{
    "FIRST", "SECOND",  "THIRD",  "FOURTH", "FIFTH",
    "SIXTH", "SEVENTH", "EIGHTH", "NINTH",  "TENTH",
};

pub fn registerStandard(ev: *Evaluator) !void {
    _ = try ev.defineNative("CONS", &consFn);
    _ = try ev.defineNative("CAR", &carFn);
    _ = try ev.defineNative("CDR", &cdrFn);
    inline for (cxr_table) |entry| {
        _ = try ev.defineNative(entry.name, makeCxr(entry.seq));
    }
    inline for (ordinals, 0..) |nm, idx| {
        _ = try ev.defineNative(nm, makeNth(idx));
    }
    _ = try ev.defineNative("NTH", &nthFn);
    _ = try ev.defineNative("NTHCDR", &nthcdrFn);

    _ = try ev.defineNative("LIST", &listFn);
    _ = try ev.defineNative("LIST*", &listStarFn);
    _ = try ev.defineNative("APPEND", &appendFn);
    _ = try ev.defineNative("REVERSE", &reverseFn);
    _ = try ev.defineNative("NREVERSE", &nreverseFn);
    _ = try ev.defineNative("LENGTH", &lengthFn);

    _ = try ev.defineNative("EQ", &eqFn);
    _ = try ev.defineNative("EQL", &eqlFn);
    _ = try ev.defineNative("EQUAL", &equalFn);
    _ = try ev.defineNative("EQUALP", &equalpFn);

    _ = try ev.defineNative("ATOM", &atomFn);
    _ = try ev.defineNative("CONSP", &conspFn);
    _ = try ev.defineNative("LISTP", &listpFn);
    _ = try ev.defineNative("NULL", &nullFn);
    _ = try ev.defineNative("ENDP", &endpFn);
    _ = try ev.defineNative("SYMBOLP", &symbolpFn);
    _ = try ev.defineNative("NUMBERP", &numberpFn);
    _ = try ev.defineNative("INTEGERP", &integerpFn);
    _ = try ev.defineNative("STRINGP", &stringpFn);

    _ = try ev.defineNative("+", &addFn);
    _ = try ev.defineNative("-", &subFn);
    _ = try ev.defineNative("*", &mulFn);
    _ = try ev.defineNative("/", &divFn);
    _ = try ev.defineNative("MOD", &modFn);
    _ = try ev.defineNative("REM", &remFn);
    _ = try ev.defineNative("1+", &onePlusFn);
    _ = try ev.defineNative("1-", &oneMinusFn);
    _ = try ev.defineNative("ABS", &absFn);
    _ = try ev.defineNative("MIN", &minFn);
    _ = try ev.defineNative("MAX", &maxFn);

    _ = try ev.defineNative("=", cmpFn(.eq));
    _ = try ev.defineNative("/=", cmpFn(.ne));
    _ = try ev.defineNative("<", cmpFn(.lt));
    _ = try ev.defineNative(">", cmpFn(.gt));
    _ = try ev.defineNative("<=", cmpFn(.le));
    _ = try ev.defineNative(">=", cmpFn(.ge));
    _ = try ev.defineNative("ZEROP", zeropFn);
    _ = try ev.defineNative("PLUSP", pluspFn);
    _ = try ev.defineNative("MINUSP", minuspFn);
    _ = try ev.defineNative("ODDP", &oddpFn);
    _ = try ev.defineNative("EVENP", &evenpFn);

    _ = try ev.defineNative("NOT", &notFn);

    _ = try ev.defineNative("FUNCALL", &funcallFn);
    _ = try ev.defineNative("APPLY", &applyFn);

    _ = try ev.defineNative("MAPCAR", &mapcarFn);
    _ = try ev.defineNative("MAPC", &mapcFn);
    _ = try ev.defineNative("MAPCAN", &mapcanFn);
}

// --- cons accessors ---

fn carOf(v: Value) Error!Value {
    if (isNil(v)) return value.NIL;
    if (v.isCons()) return heap.car(v);
    return Error.TypeError;
}

fn cdrOf(v: Value) Error!Value {
    if (isNil(v)) return value.NIL;
    if (v.isCons()) return heap.cdr(v);
    return Error.TypeError;
}

fn consFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 2) return Error.WrongArgCount;
    return evaluator(p).heap.allocCons(args[0], args[1]);
}

fn carFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return carOf(args[0]);
}

fn cdrFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return cdrOf(args[0]);
}

fn makeCxr(comptime seq: []const u8) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len != 1) return Error.WrongArgCount;
            var v = args[0];
            var i: usize = seq.len;
            while (i > 0) {
                i -= 1;
                v = if (seq[i] == 'a') try carOf(v) else try cdrOf(v);
            }
            return v;
        }
    }.f;
}

fn nthOf(n: i64, list: Value) Error!Value {
    var v = list;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (isNil(v)) return value.NIL;
        if (!v.isCons()) return Error.TypeError;
        v = heap.cdr(v);
    }
    if (isNil(v)) return value.NIL;
    if (!v.isCons()) return Error.TypeError;
    return heap.car(v);
}

fn makeNth(comptime idx: i64) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len != 1) return Error.WrongArgCount;
            return nthOf(idx, args[0]);
        }
    }.f;
}

fn nthFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isFixnum()) return Error.TypeError;
    const n = args[0].toFixnum();
    if (n < 0) return Error.TypeError;
    return nthOf(n, args[1]);
}

fn nthcdrFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isFixnum()) return Error.TypeError;
    var n = args[0].toFixnum();
    if (n < 0) return Error.TypeError;
    var v = args[1];
    while (n > 0) : (n -= 1) {
        if (isNil(v)) return value.NIL;
        if (!v.isCons()) return Error.TypeError;
        v = heap.cdr(v);
    }
    return v;
}

// --- list construction ---

fn makeList(ev: *Evaluator, items: []const Value, tail: Value) Error!Value {
    var result = tail;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        result = try ev.heap.allocCons(items[i], result);
    }
    return result;
}

fn listFn(p: *anyopaque, args: []const Value) Error!Value {
    return makeList(evaluator(p), args, value.NIL);
}

fn listStarFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len == 0) return Error.WrongArgCount;
    return makeList(evaluator(p), args[0 .. args.len - 1], args[args.len - 1]);
}

fn appendFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return value.NIL;
    var result = args[args.len - 1];
    var i: usize = args.len - 1;
    while (i > 0) {
        i -= 1;
        var elems: std.ArrayList(Value) = .empty;
        defer elems.deinit(ev.allocator);
        var v = args[i];
        while (!isNil(v)) {
            if (!v.isCons()) return Error.TypeError;
            try elems.append(ev.allocator, heap.car(v));
            v = heap.cdr(v);
        }
        result = try makeList(ev, elems.items, result);
    }
    return result;
}

fn reverseFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var result = value.NIL;
    var v = args[0];
    while (!isNil(v)) {
        if (!v.isCons()) return Error.TypeError;
        result = try ev.heap.allocCons(heap.car(v), result);
        v = heap.cdr(v);
    }
    return result;
}

fn nreverseFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    var prev = value.NIL;
    var cur = args[0];
    while (!isNil(cur)) {
        if (!cur.isCons()) return Error.TypeError;
        const next = heap.cdr(cur);
        heap.setCdr(cur, prev);
        prev = cur;
        cur = next;
    }
    return prev;
}

fn lengthFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    const v = args[0];
    if (isNil(v) or v.isCons()) {
        var count: i64 = 0;
        var cur = v;
        while (!isNil(cur)) {
            if (!cur.isCons()) return Error.TypeError;
            count += 1;
            cur = heap.cdr(cur);
        }
        return Value.fromFixnum(count);
    }
    if (v.tag() == .heap) {
        switch (heap.heapType(v)) {
            .string => return Value.fromFixnum(@intCast(heap.asString(v).len)),
            .vector => return Value.fromFixnum(@intCast(heap.asVector(v).len)),
            else => return Error.TypeError,
        }
    }
    return Error.TypeError;
}

// --- equality ---

fn numberp(v: Value) bool {
    if (v.isFixnum()) return true;
    if (v.tag() != .heap) return false;
    return switch (heap.heapType(v)) {
        .single_float, .double_float, .ratio => true,
        else => false,
    };
}

fn toF64(v: Value) f64 {
    if (v.isFixnum()) return @floatFromInt(v.toFixnum());
    const t = heap.heapType(v);
    if (t == .single_float) return heap.asSingleFloat(v).value;
    if (t == .double_float) return heap.asDoubleFloat(v).value;
    const r = heap.asRatio(v);
    return @as(f64, @floatFromInt(r.numerator)) / @as(f64, @floatFromInt(r.denominator));
}

fn numEqual(a: Value, b: Value) bool {
    if (a.isFixnum() and b.isFixnum()) return a.toFixnum() == b.toFixnum();
    return toF64(a) == toF64(b);
}

fn eqlValues(a: Value, b: Value) bool {
    if (a.equalsRaw(b)) return true;
    if (a.tag() != .heap or b.tag() != .heap) return false;
    const ta = heap.heapType(a);
    if (ta != heap.heapType(b)) return false;
    return switch (ta) {
        .single_float => heap.asSingleFloat(a).value == heap.asSingleFloat(b).value,
        .double_float => heap.asDoubleFloat(a).value == heap.asDoubleFloat(b).value,
        .ratio => heap.asRatio(a).numerator == heap.asRatio(b).numerator and
            heap.asRatio(a).denominator == heap.asRatio(b).denominator,
        else => false,
    };
}

fn equalValues(a: Value, b: Value) bool {
    if (eqlValues(a, b)) return true;
    if (a.isCons() and b.isCons()) {
        return equalValues(heap.car(a), heap.car(b)) and equalValues(heap.cdr(a), heap.cdr(b));
    }
    if (a.tag() == .heap and b.tag() == .heap and
        heap.heapType(a) == .string and heap.heapType(b) == .string)
    {
        return std.mem.eql(u8, heap.asString(a).constSlice(), heap.asString(b).constSlice());
    }
    return false;
}

fn charLower(c: u21) u21 {
    if (c < 128) return std.ascii.toLower(@intCast(c));
    return c;
}

fn stringEqualFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn equalpValues(a: Value, b: Value) bool {
    if (numberp(a) and numberp(b)) return numEqual(a, b);
    if (a.isChar() and b.isChar()) return charLower(a.toChar()) == charLower(b.toChar());
    if (a.isCons() and b.isCons()) {
        return equalpValues(heap.car(a), heap.car(b)) and equalpValues(heap.cdr(a), heap.cdr(b));
    }
    if (a.tag() == .heap and b.tag() == .heap) {
        const ta = heap.heapType(a);
        const tb = heap.heapType(b);
        if (ta == .string and tb == .string) {
            return stringEqualFold(heap.asString(a).constSlice(), heap.asString(b).constSlice());
        }
        if (ta == .vector and tb == .vector) {
            const va = heap.asVector(a).constSlice();
            const vb = heap.asVector(b).constSlice();
            if (va.len != vb.len) return false;
            for (va, vb) |ea, eb| {
                if (!equalpValues(ea, eb)) return false;
            }
            return true;
        }
    }
    return a.equalsRaw(b);
}

fn eqFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(args[0].equalsRaw(args[1]));
}

fn eqlFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(eqlValues(args[0], args[1]));
}

fn equalFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(equalValues(args[0], args[1]));
}

fn equalpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(equalpValues(args[0], args[1]));
}

// --- type predicates ---

fn atomFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(!args[0].isCons());
}

fn conspFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].isCons());
}

fn listpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isNil(args[0]) or args[0].isCons());
}

fn nullFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isNil(args[0]));
}

fn endpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (isNil(args[0])) return value.T;
    if (args[0].isCons()) return value.NIL;
    return Error.TypeError;
}

fn symbolpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].isSymbol());
}

fn numberpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(numberp(args[0]));
}

fn integerpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].isFixnum());
}

fn stringpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].tag() == .heap and heap.heapType(args[0]) == .string);
}

// --- arithmetic ---

fn asFix(v: Value) Error!i64 {
    if (!v.isFixnum()) return Error.TypeError;
    return v.toFixnum();
}

fn gcd(a: i64, b: i64) i64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = @rem(x, y);
        x = y;
        y = t;
    }
    return x;
}

fn makeRatio(ev: *Evaluator, num: i64, den: i64) Error!Value {
    if (den == 0) return Error.DivisionByZero;
    if (num == 0) return Value.fromFixnum(0);
    var n = num;
    var d = den;
    if (d < 0) {
        n = -n;
        d = -d;
    }
    const g = gcd(if (n < 0) -n else n, d);
    n = @divExact(n, g);
    d = @divExact(d, g);
    if (d == 1) return Value.fromFixnum(n);
    return ev.heap.allocRatio(n, d);
}

fn addFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    var sum: i64 = 0;
    for (args) |a| sum += try asFix(a);
    return Value.fromFixnum(sum);
}

fn subFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len == 0) return Error.WrongArgCount;
    if (args.len == 1) return Value.fromFixnum(-(try asFix(args[0])));
    var acc = try asFix(args[0]);
    for (args[1..]) |a| acc -= try asFix(a);
    return Value.fromFixnum(acc);
}

fn mulFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    var prod: i64 = 1;
    for (args) |a| prod *= try asFix(a);
    return Value.fromFixnum(prod);
}

fn divFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    if (args.len == 1) return makeRatio(ev, 1, try asFix(args[0]));
    const num = try asFix(args[0]);
    var den: i64 = 1;
    for (args[1..]) |a| {
        const d = try asFix(a);
        if (d == 0) return Error.DivisionByZero;
        den *= d;
    }
    return makeRatio(ev, num, den);
}

fn modFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const a = try asFix(args[0]);
    const b = try asFix(args[1]);
    if (b == 0) return Error.DivisionByZero;
    return Value.fromFixnum(@mod(a, b));
}

fn remFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const a = try asFix(args[0]);
    const b = try asFix(args[1]);
    if (b == 0) return Error.DivisionByZero;
    return Value.fromFixnum(@rem(a, b));
}

fn onePlusFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return Value.fromFixnum((try asFix(args[0])) + 1);
}

fn oneMinusFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return Value.fromFixnum((try asFix(args[0])) - 1);
}

fn absFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    const n = try asFix(args[0]);
    return Value.fromFixnum(if (n < 0) -n else n);
}

fn minFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len == 0) return Error.WrongArgCount;
    var acc = try asFix(args[0]);
    for (args[1..]) |a| {
        const n = try asFix(a);
        if (n < acc) acc = n;
    }
    return Value.fromFixnum(acc);
}

fn maxFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len == 0) return Error.WrongArgCount;
    var acc = try asFix(args[0]);
    for (args[1..]) |a| {
        const n = try asFix(a);
        if (n > acc) acc = n;
    }
    return Value.fromFixnum(acc);
}

// --- comparisons ---

const CmpOp = enum { eq, ne, lt, gt, le, ge };

fn cmpFn(comptime op: CmpOp) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len == 0) return Error.WrongArgCount;
            for (args) |a| {
                if (!a.isFixnum()) return Error.TypeError;
            }
            if (op == .ne) {
                for (args, 0..) |a, i| {
                    for (args[i + 1 ..]) |b| {
                        if (a.toFixnum() == b.toFixnum()) return value.NIL;
                    }
                }
                return value.T;
            }
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const x = args[i - 1].toFixnum();
                const y = args[i].toFixnum();
                const ok = switch (op) {
                    .eq => x == y,
                    .lt => x < y,
                    .gt => x > y,
                    .le => x <= y,
                    .ge => x >= y,
                    .ne => unreachable,
                };
                if (!ok) return value.NIL;
            }
            return value.T;
        }
    }.f;
}

fn signPred(comptime want: enum { zero, plus, minus }) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            _ = p;
            if (args.len != 1) return Error.WrongArgCount;
            const n = try asFix(args[0]);
            return boolv(switch (want) {
                .zero => n == 0,
                .plus => n > 0,
                .minus => n < 0,
            });
        }
    }.f;
}

const zeropFn = signPred(.zero);
const pluspFn = signPred(.plus);
const minuspFn = signPred(.minus);

fn oddpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(@rem(try asFix(args[0]), 2) != 0);
}

fn evenpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(@rem(try asFix(args[0]), 2) == 0);
}

fn notFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isNil(args[0]));
}

// --- application ---

fn resolveCallee(ev: *Evaluator, designator: Value) Error!Value {
    if (function.isFunction(designator)) return designator;
    if (designator.isSymbol()) {
        return ev.env.lookupFunction(designator) orelse Error.UnboundFunction;
    }
    return Error.TypeError;
}

fn funcallFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    const callee = try resolveCallee(ev, args[0]);
    return ev.callFunction(callee, args[1..]);
}

fn applyFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const callee = try resolveCallee(ev, args[0]);

    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(ev.allocator);
    try collected.appendSlice(ev.allocator, args[1 .. args.len - 1]);

    var v = args[args.len - 1];
    while (!isNil(v)) {
        if (!v.isCons()) return Error.TypeError;
        try collected.append(ev.allocator, heap.car(v));
        v = heap.cdr(v);
    }
    return ev.callFunction(callee, collected.items);
}

// --- mapping ---

const MapKind = enum { car, c, can };

fn mapDriver(ev: *Evaluator, args: []const Value, comptime kind: MapKind) Error!Value {
    if (args.len < 2) return Error.WrongArgCount;
    const callee = try resolveCallee(ev, args[0]);
    const lists = args[1..];

    const cursors = try ev.allocator.alloc(Value, lists.len);
    defer ev.allocator.free(cursors);
    @memcpy(cursors, lists);
    const call_args = try ev.allocator.alloc(Value, lists.len);
    defer ev.allocator.free(call_args);

    var head = value.NIL;
    var tail = value.NIL;

    while (true) {
        for (cursors) |c| {
            if (!c.isCons()) return finishMap(kind, args, head);
        }
        for (cursors, 0..) |c, i| {
            call_args[i] = heap.car(c);
            cursors[i] = heap.cdr(c);
        }
        const r = try ev.callFunction(callee, call_args);
        switch (kind) {
            .c => {},
            .car => {
                const cell = try ev.heap.allocCons(r, value.NIL);
                if (isNil(head)) {
                    head = cell;
                } else {
                    heap.setCdr(tail, cell);
                }
                tail = cell;
            },
            .can => {
                var seg = r;
                if (isNil(seg)) continue;
                if (isNil(head)) {
                    head = seg;
                } else {
                    heap.setCdr(tail, seg);
                }
                while (seg.isCons() and !isNil(heap.cdr(seg))) seg = heap.cdr(seg);
                tail = seg;
            },
        }
    }
}

fn finishMap(comptime kind: MapKind, args: []const Value, head: Value) Value {
    return switch (kind) {
        .c => args[1],
        else => head,
    };
}

fn mapcarFn(p: *anyopaque, args: []const Value) Error!Value {
    return mapDriver(evaluator(p), args, .car);
}

fn mapcFn(p: *anyopaque, args: []const Value) Error!Value {
    return mapDriver(evaluator(p), args, .c);
}

fn mapcanFn(p: *anyopaque, args: []const Value) Error!Value {
    return mapDriver(evaluator(p), args, .can);
}
