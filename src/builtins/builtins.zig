const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

pub const system = @import("system.zig");
const readtables = @import("readtables.zig");
pub const registerSystem = system.registerSystem;
pub const packages = @import("packages.zig");
pub const pathnames = @import("pathnames.zig");
pub const strings = @import("strings.zig");
pub const sequences = @import("sequences.zig");
pub const arrays = @import("arrays.zig");
pub const hash_tables = @import("hash_tables.zig");
pub const numbers = @import("numbers.zig");
pub const characters = @import("characters.zig");
pub const streams = @import("streams.zig");
pub const types = @import("types.zig");
pub const pprint = @import("pprint.zig");
pub const gc = @import("gc.zig");
pub const registerGc = gc.registerGc;
const equality = @import("../runtime/equality.zig");

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
    _ = try ev.defineNative("STRINGP", &stringpFn);

    _ = try ev.defineNative("NOT", &notFn);

    _ = try ev.defineNative("FUNCALL", &funcallFn);
    _ = try ev.defineNative("APPLY", &applyFn);
    _ = try ev.defineNative("MACRO-FUNCTION", &macroFunctionFn);
    _ = try ev.defineNative("EVAL", &evalFn);
    _ = try ev.defineNative("GENSYM", &gensymFn);
    _ = try ev.defineNative("GENTEMP", &gentempFn);

    const counter_sym = try ev.interner.intern("*GENSYM-COUNTER*");
    if (symbol_mod.symbol(counter_sym).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) {
        symbol_mod.symbol(counter_sym).value_cell = Value.fromFixnum(1);
    }

    _ = try ev.defineNative("MAPCAR", &mapcarFn);
    _ = try ev.defineNative("MAPC", &mapcFn);
    _ = try ev.defineNative("MAPCAN", &mapcanFn);
    _ = try ev.defineNative("ERROR", &errorFn);

    _ = try ev.defineNative("RPLACA", &rplacaFn);
    _ = try ev.defineNative("RPLACD", &rplacdFn);
    _ = try ev.defineNative("GET", &getFn);
    _ = try ev.defineNative("%PUT", &putFn);
    _ = try ev.defineNative("SYMBOL-VALUE", &symbolValueFn);
    _ = try ev.defineNative("%SET-SYMBOL-VALUE", &setSymbolValueFn);
    _ = try ev.defineNative("SYMBOL-FUNCTION", &symbolFunctionFn);
    _ = try ev.defineNative("%SET-SYMBOL-FUNCTION", &setSymbolFunctionFn);
    _ = try ev.defineNative("SYMBOL-PLIST", &symbolPlistFn);
    _ = try ev.defineNative("%SET-SYMBOL-PLIST", &setSymbolPlistFn);
    _ = try ev.defineNative("ELT", &eltFn);
    _ = try ev.defineNative("%SET-ELT", &setEltFn);
    _ = try ev.defineNative("MEMBER", &memberFn);
    _ = try ev.defineNative("ASSOC", &assocFn);
    _ = try ev.defineNative("FBOUNDP", &fboundpFn);
    _ = try ev.defineNative("BOUNDP", &boundpFn);

    _ = try ev.defineNative("%MAKE-STRUCTURE", &makeStructureFn);
    _ = try ev.defineNative("%STRUCTURE-P", &structurePFn);
    _ = try ev.defineNative("%STRUCTURE-NAME", &structureNameFn);
    _ = try ev.defineNative("%STRUCTURE-REF", &structureRefFn);
    _ = try ev.defineNative("%SET-STRUCTURE-REF", &setStructureRefFn);
    _ = try ev.defineNative("%COPY-STRUCTURE", &copyStructureFn);

    // Pass-through natives keep the values channel of the call they make
    // (or the values they set themselves).
    const funcall_v = ev.env.lookupFunction(try ev.interner.intern("FUNCALL")).?;
    function.asFunction(funcall_v).preserves_values = true;
    const apply_v = ev.env.lookupFunction(try ev.interner.intern("APPLY")).?;
    function.asFunction(apply_v).preserves_values = true;
    const eval_v = ev.env.lookupFunction(try ev.interner.intern("EVAL")).?;
    function.asFunction(eval_v).preserves_values = true;

    try packages.registerPackages(ev);
    try pathnames.registerPathnames(ev);
    try gc.registerGc(ev);
    try strings.registerStrings(ev);
    try sequences.registerSequences(ev);
    try arrays.registerArrays(ev);
    try hash_tables.registerHashTables(ev);
    try numbers.registerNumbers(ev);
    try characters.registerCharacters(ev);
    try streams.registerStreams(ev);
    try types.registerTypes(ev);
    try pprint.registerPprint(ev);
    try pathnames.registerPathnames(ev);
    // Ahead of the prelude: reading the prelude interns every symbol it
    // mentions in the current package, so a name the prelude uses before
    // its native exists would shadow the later definition.
    try readtables.registerReadtables(ev);
    try system.registerSystem(ev);

    try system.evalSource(ev, prelude_source);
    try system.evalSource(ev, iteration_source);
    try system.evalSource(ev, lists_source);
    try system.evalSource(ev, loop_source);
    try system.evalSource(ev, sequences_source);
}

// --- conses, plists, symbol cells ---

fn rplacaFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isCons()) return Error.TypeError;
    heap.setCar(args[0], args[1]);
    return args[0];
}

fn rplacdFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isCons()) return Error.TypeError;
    heap.setCdr(args[0], args[1]);
    return args[0];
}

fn getFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    var plist = symbol_mod.symbol(args[0]).plist;
    while (plist.isCons()) {
        const rest = heap.cdr(plist);
        if (!rest.isCons()) return Error.TypeError;
        if (heap.car(plist).equalsRaw(args[1])) return heap.car(rest);
        plist = heap.cdr(rest);
    }
    return if (args.len == 3) args[2] else value.NIL;
}

fn putFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const sym = symbol_mod.symbol(args[0]);
    var plist = sym.plist;
    while (plist.isCons()) {
        const rest = heap.cdr(plist);
        if (!rest.isCons()) return Error.TypeError;
        if (heap.car(plist).equalsRaw(args[1])) {
            heap.setCar(rest, args[2]);
            return args[2];
        }
        plist = heap.cdr(rest);
    }
    sym.plist = try ev.heap.listWithTail(&.{ args[1], args[2] }, sym.plist);
    return args[2];
}

fn symbolValueFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const cell = symbol_mod.symbol(args[0]).value_cell;
    if (cell.equalsRaw(value.SPECIAL_UNBOUND)) {
        return evaluator(p).unbound(args[0], Error.UnboundVariable);
    }
    return cell;
}

fn setSymbolValueFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    symbol_mod.symbol(args[0]).value_cell = args[1];
    return args[1];
}

fn symbolFunctionFn(p: *anyopaque, args: []const Value) Error!Value {
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const cell = symbol_mod.symbol(args[0]).function_cell;
    if (cell.equalsRaw(value.SPECIAL_UNBOUND)) {
        return evaluator(p).unbound(args[0], Error.UnboundFunction);
    }
    return cell;
}

fn setSymbolFunctionFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    if (!function.isFunction(args[1])) return Error.TypeError;
    symbol_mod.symbol(args[0]).function_cell = args[1];
    return args[1];
}

fn fboundpFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    if (ev.lookupSpecialForm(args[0]) != null) return value.T;
    return if (ev.env.lookupFunction(args[0]) != null) value.T else value.NIL;
}

fn boundpFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    return if (ev.env.lookupValue(args[0]) != null) value.T else value.NIL;
}

fn symbolPlistFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    return symbol_mod.symbol(args[0]).plist;
}

fn setSymbolPlistFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    symbol_mod.symbol(args[0]).plist = args[1];
    return args[1];
}

// --- elt / aref ---

fn eltIndex(v: Value) Error!usize {
    if (!v.isFixnum() or v.toFixnum() < 0) return Error.TypeError;
    return @intCast(v.toFixnum());
}

fn eltFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const i = try eltIndex(args[1]);
    if (args[0].isCons() or isNil(args[0])) {
        var cur = args[0];
        var n = i;
        while (cur.isCons()) {
            if (n == 0) return heap.car(cur);
            n -= 1;
            cur = heap.cdr(cur);
        }
        return Error.TypeError;
    }
    return elementOf(args[0], args[1]);
}

fn setEltFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 3) return Error.WrongArgCount;
    const i = try eltIndex(args[1]);
    if (args[0].isCons()) {
        var cur = args[0];
        var n = i;
        while (cur.isCons()) {
            if (n == 0) {
                heap.setCar(cur, args[2]);
                return args[2];
            }
            n -= 1;
            cur = heap.cdr(cur);
        }
        return Error.TypeError;
    }
    return setElementOf(args[0], args[1], args[2]);
}

/// One element of a vector or a string, bounds-checked.
fn elementOf(seq: Value, index_v: Value) Error!Value {
    const i = try eltIndex(index_v);
    if (heap.isString(seq)) {
        const chars = heap.asString(seq).constSlice();
        if (i >= chars.len) return Error.TypeError;
        return Value.fromChar(@intCast(chars[i]));
    }
    if (!heap.isArray(seq)) return Error.TypeError;
    const slots = heap.arrayActive(seq);
    if (i >= slots.len) return Error.TypeError;
    return slots[i];
}

fn setElementOf(seq: Value, index_v: Value, new_value: Value) Error!Value {
    const i = try eltIndex(index_v);
    if (heap.isString(seq)) {
        const chars = heap.asString(seq).slice();
        if (i >= chars.len) return Error.TypeError;
        if (new_value.tag() != .char) return Error.TypeError;
        chars[i] = new_value.toChar();
        return new_value;
    }
    if (!heap.isArray(seq)) return Error.TypeError;
    const slots = heap.arrayActive(seq);
    if (i >= slots.len) return Error.TypeError;
    slots[i] = new_value;
    return new_value;
}

// --- structures (the runtime half of `defstruct`) ---

fn makeStructureFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    return ev.heap.allocStructure(args[0], args[1..]);
}

fn structurePFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return if (heap.isStructure(args[0])) value.T else value.NIL;
}

fn structureNameFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (!heap.isStructure(args[0])) return Error.TypeError;
    return heap.asStructure(args[0]).name;
}

fn structureSlotIndex(args: []const Value) Error!usize {
    if (!heap.isStructure(args[0])) return Error.TypeError;
    const i = try eltIndex(args[1]);
    const obj = heap.asStructure(args[0]);
    if (i >= obj.len) return Error.TypeError;
    return i;
}

fn structureRefFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const index = try structureSlotIndex(args);
    return heap.asStructure(args[0]).slice()[index];
}

fn setStructureRefFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 3) return Error.WrongArgCount;
    heap.setSlot(args[0], try structureSlotIndex(args[0..2]), args[2]);
    return args[2];
}

fn copyStructureFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!heap.isStructure(args[0])) return Error.TypeError;
    const obj = heap.asStructure(args[0]);
    return ev.heap.allocStructure(obj.name, obj.slice());
}

// --- member ---

/// `(member item list &key test key)`. Default test is eql (raw identity).
/// `:test` and `:key` as accepted by `member` and `assoc`.
const TestAndKey = struct {
    test_fn: ?Value,
    key_fn: ?Value,

    fn parse(ev: *Evaluator, opts: []const Value) Error!TestAndKey {
        if (opts.len % 2 != 0) return Error.WrongArgCount;
        var result = TestAndKey{ .test_fn = null, .key_fn = null };
        const test_kw = try ev.interner.internKeyword("TEST");
        const key_kw = try ev.interner.internKeyword("KEY");
        var i: usize = 0;
        while (i < opts.len) : (i += 2) {
            if (opts[i].equalsRaw(test_kw)) {
                result.test_fn = try resolveCallee(ev, opts[i + 1]);
            } else if (opts[i].equalsRaw(key_kw)) {
                result.key_fn = try resolveCallee(ev, opts[i + 1]);
            } else return Error.ProgramError;
        }
        return result;
    }

    fn matches(self: TestAndKey, ev: *Evaluator, item: Value, elem_in: Value) Error!bool {
        var elem = elem_in;
        if (self.key_fn) |k| elem = try ev.callFunction(k, &.{elem});
        if (self.test_fn) |t| {
            return !(try ev.callFunction(t, &.{ item, elem })).equalsRaw(value.NIL);
        }
        return equality.eql(item, elem);
    }
};

fn assocFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const opts = try TestAndKey.parse(ev, args[2..]);

    var cur = args[1];
    while (cur.isCons()) : (cur = heap.cdr(cur)) {
        const pair = heap.car(cur);
        if (isNil(pair)) continue;
        if (!pair.isCons()) return Error.TypeError;
        if (try opts.matches(ev, args[0], heap.car(pair))) return pair;
    }
    if (!isNil(cur)) return Error.TypeError;
    return value.NIL;
}

fn memberFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const opts = try TestAndKey.parse(ev, args[2..]);

    var cur = args[1];
    while (cur.isCons()) : (cur = heap.cdr(cur)) {
        if (try opts.matches(ev, args[0], heap.car(cur))) return cur;
    }
    if (!isNil(cur)) return Error.TypeError;
    return value.NIL;
}

const prelude_source = @embedFile("../lisp/prelude.lisp");
const iteration_source = @embedFile("../lisp/iteration.lisp");
const lists_source = @embedFile("../lisp/lists.lisp");
const loop_source = @embedFile("../lisp/loop.lisp");
const sequences_source = @embedFile("../lisp/sequences.lisp");

/// `(error datum args...)`. Until the condition system exists this signals
/// a program error; a string datum plus arguments is accepted in the
/// standard `format`-control shape.
fn errorFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len == 0) return Error.WrongArgCount;
    return Error.ProgramError;
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
    // The part of the list already built is reachable from nothing else
    // while the next cell is allocated.
    var held = ev.heap.protect();
    defer held.close();
    try held.push(tail);
    var result = tail;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        result = try ev.heap.allocCons(items[i], result);
        held.setItem(0, result);
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
            .vector => return Value.fromFixnum(@intCast(heap.asArray(v).activeLen())),
            else => return Error.TypeError,
        }
    }
    return Error.TypeError;
}

// --- equality ---

fn eqFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(args[0].equalsRaw(args[1]));
}

fn eqlFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(equality.eql(args[0], args[1]));
}

fn equalFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(equality.equal(args[0], args[1]));
}

fn equalpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(equality.equalp(args[0], args[1]));
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
    return boolv(equality.isNumber(args[0]));
}

fn stringpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].tag() == .heap and heap.heapType(args[0]) == .string);
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
        return ev.env.lookupFunction(designator) orelse
            ev.unbound(designator, Error.UnboundFunction);
    }
    return Error.TypeError;
}

fn funcallFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0) return Error.WrongArgCount;
    const callee = try resolveCallee(ev, args[0]);
    return ev.callFunction(callee, args[1..]);
}

fn evalFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return ev.eval(args[0]);
}

/// `(gensym [prefix-string | nonnegative-fixnum])`. A string names the
/// prefix; a fixnum is used as the counter without touching
/// `*gensym-counter*`. Otherwise the counter is read and incremented.
fn gensymFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;

    var prefix: []const u8 = "G";
    var explicit: ?i64 = null;
    if (args.len == 1) {
        const a = args[0];
        if (a.tag() == .fixnum) {
            if (a.toFixnum() < 0) return Error.TypeError;
            explicit = a.toFixnum();
        } else if (heap.isString(a)) {
            prefix = try heap.stringUtf8Alloc(ev.heap.allocator, a);
        } else return Error.TypeError;
    }

    var n: i64 = undefined;
    if (explicit) |c| {
        n = c;
    } else {
        const counter_sym = try ev.interner.intern("*GENSYM-COUNTER*");
        const cur = ev.env.lookupValue(counter_sym) orelse
            return ev.unbound(counter_sym, Error.UnboundVariable);
        if (cur.tag() != .fixnum or cur.toFixnum() < 0) return Error.TypeError;
        n = cur.toFixnum();
        symbol_mod.symbol(counter_sym).value_cell = Value.fromFixnum(n + 1);
    }

    const name = try std.fmt.allocPrint(ev.allocator, "{s}{d}", .{ prefix, n });
    defer ev.allocator.free(name);
    return ev.interner.makeUninterned(name);
}

/// `(gentemp [prefix-string])`. Interns the first `PREFIXn` name that is
/// not already interned.
fn gentempFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;

    var prefix: []const u8 = "T";
    if (args.len == 1) {
        const a = args[0];
        if (!heap.isString(a)) return Error.TypeError;
        prefix = try heap.stringUtf8Alloc(ev.heap.allocator, a);
    }

    var n: i64 = 1;
    while (true) : (n += 1) {
        const name = try std.fmt.allocPrint(ev.allocator, "{s}{d}", .{ prefix, n });
        defer ev.allocator.free(name);
        if (ev.interner.lookup(name) == null) {
            return ev.interner.intern(name);
        }
    }
}

fn macroFunctionFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const f = ev.env.lookupFunction(args[0]) orelse return value.NIL;
    if (!function.isMacro(f)) return value.NIL;
    return f;
}

fn applyFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const callee = try resolveCallee(ev, args[0]);

    var collected = ev.heap.protect();
    defer collected.close();
    for (args[1 .. args.len - 1]) |arg| try collected.push(arg);

    var v = args[args.len - 1];
    while (!isNil(v)) {
        if (!v.isCons()) return Error.TypeError;
        try collected.push(heap.car(v));
        v = heap.cdr(v);
    }
    return ev.callFunction(callee, collected.items());
}

// --- mapping ---

const MapKind = enum { car, c, can };

fn mapDriver(ev: *Evaluator, args: []const Value, comptime kind: MapKind) Error!Value {
    if (args.len < 2) return Error.WrongArgCount;
    const callee = try resolveCallee(ev, args[0]);
    const lists = args[1..];

    // The cursors, the arguments of the call in flight, and the list
    // built so far all go on the Lisp stack: calling the function
    // allocates, and nothing else refers to any of them.
    var held = ev.heap.protect();
    defer held.close();
    try held.push(value.NIL);
    try held.push(value.NIL);

    var cursors_held = ev.heap.protect();
    defer cursors_held.close();
    for (lists) |list| try cursors_held.push(list);
    const cursors = cursors_held.items();

    var call_held = ev.heap.protect();
    defer call_held.close();
    for (lists) |_| try call_held.push(value.NIL);
    const call_args = call_held.items();

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
                held.setItem(1, r);
                const cell = try ev.heap.allocCons(r, value.NIL);
                if (isNil(head)) {
                    head = cell;
                    held.setItem(0, head);
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
                    held.setItem(0, head);
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
