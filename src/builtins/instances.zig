//! The objects CLOS is built from.
//!
//! A standard instance is a heap structure whose name field holds its
//! class rather than a symbol, with two fields: the vector of its slot
//! values and the wrapper its class had when it was laid out. A
//! funcallable instance carries the same three on a function object,
//! along with the function a call to it runs. Everything else about
//! classes, slots and dispatch is written in Lisp over these.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const printer = @import("../runtime/printer.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const streams = @import("streams.zig");
const format = @import("format.zig");
const hash_tables = @import("hash_tables.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

const SLOTS = 0;
const WRAPPER = 1;

/// The symbols kept in `Evaluator.clos_symbols`, by index.
const Interned = enum(u8) {
    class_key,
    class,
    null_type,
    cons,
    symbol,
    fixnum,
    character,
    t,
    bignum,
    ratio,
    single_float,
    double_float,
    complex,
    string,
    hash_table,
    function,
    package,
    logical_pathname,
    pathname,
    file_stream,
    string_stream,
    stream,
    random_state,
    readtable,
    structure_object,
    array,
    bit_vector,
    vector,
    slot_unbound,
    fast_miss,
    standard_metaclasses,
    dispatch_epoch,
    gf_dispatch_miss,
    standard_generic_function,
    eql_specializer,
    quote,
    amp_optional,
    amp_rest,
    amp_body,
    amp_key,
    amp_allow_other_keys,
    amp_aux,
    amp_whole,
    amp_environment,
    structure_print_object,

    fn text(self: Interned) []const u8 {
        return switch (self) {
            .class_key => "%CLASS",
            .class => "CLASS",
            .null_type => "NULL",
            .cons => "CONS",
            .symbol => "SYMBOL",
            .fixnum => "FIXNUM",
            .character => "CHARACTER",
            .t => "T",
            .bignum => "BIGNUM",
            .ratio => "RATIO",
            .single_float => "SINGLE-FLOAT",
            .double_float => "DOUBLE-FLOAT",
            .complex => "COMPLEX",
            .string => "STRING",
            .hash_table => "HASH-TABLE",
            .function => "FUNCTION",
            .package => "PACKAGE",
            .logical_pathname => "LOGICAL-PATHNAME",
            .pathname => "PATHNAME",
            .file_stream => "FILE-STREAM",
            .string_stream => "STRING-STREAM",
            .stream => "STREAM",
            .random_state => "RANDOM-STATE",
            .readtable => "READTABLE",
            .structure_object => "STRUCTURE-OBJECT",
            .array => "ARRAY",
            .bit_vector => "BIT-VECTOR",
            .vector => "VECTOR",
            .slot_unbound => "*%SLOT-UNBOUND*",
            .fast_miss => "*%FAST-MISS*",
            .standard_metaclasses => "*%STANDARD-METACLASSES*",
            .dispatch_epoch => "*%DISPATCH-EPOCH*",
            .gf_dispatch_miss => "%GF-DISPATCH-MISS",
            .standard_generic_function => "*%THE-CLASS-STANDARD-GENERIC-FUNCTION*",
            .eql_specializer => "*%THE-CLASS-EQL-SPECIALIZER*",
            .quote => "QUOTE",
            .amp_optional => "&OPTIONAL",
            .amp_rest => "&REST",
            .amp_body => "&BODY",
            .amp_key => "&KEY",
            .amp_allow_other_keys => "&ALLOW-OTHER-KEYS",
            .amp_aux => "&AUX",
            .amp_whole => "&WHOLE",
            .amp_environment => "&ENVIRONMENT",
            .structure_print_object => "*%STRUCTURE-PRINT-OBJECT*",
        };
    }
};

comptime {
    std.debug.assert(std.enums.values(Interned).len <= @typeInfo(@FieldType(Evaluator, "clos_symbols")).array.len);
}

fn interned(ev: *Evaluator, which: Interned) Error!Value {
    const slot = &ev.clos_symbols[@backingInt(which)];
    if (slot.raw == 0) slot.* = try ev.interner.intern(which.text());
    return slot.*;
}

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

/// Whether `v` is a standard instance: a structure named by an object
/// rather than by a symbol.
pub fn isStandardInstance(v: Value) bool {
    return heap.isStructure(v) and !heap.asStructure(v).name.isSymbol();
}

/// Whether `v` is an instance of any class CLOS defined, funcallable or
/// not.
pub fn isInstance(v: Value) bool {
    return isStandardInstance(v) or function.isFuncallable(v);
}

pub fn classOf(v: Value) Value {
    if (function.isFuncallable(v)) return function.asFunction(v).payload.funcallable.class;
    return heap.asStructure(v).name;
}

pub fn slotsOf(v: Value) Value {
    if (function.isFuncallable(v)) return function.asFunction(v).payload.funcallable.slots;
    return heap.asStructure(v).slice()[SLOTS];
}

fn expectInstance(v: Value) Error!Value {
    if (!isInstance(v)) return Error.TypeError;
    return v;
}

/// `(%allocate-standard-instance class wrapper slots)`.
fn allocateStandardFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    var fields = [_]Value{ args[2], args[1] };
    return ev.heap.allocStructure(args[0], &fields);
}

/// `(%allocate-funcallable-instance class wrapper slots)`. A call to it
/// signals until `%set-funcallable-instance-function` gives it something
/// to run.
fn allocateFuncallableFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    return function.allocFuncallable(ev.heap.allocator, args[0], args[2], args[1]);
}

fn instancePFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isInstance(args[0]));
}

fn funcallableInstancePFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(function.isFuncallable(args[0]));
}

fn instanceClassFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return classOf(try expectInstance(args[0]));
}

fn instanceSlotsFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return slotsOf(try expectInstance(args[0]));
}

fn instanceWrapperFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    const v = try expectInstance(args[0]);
    if (function.isFuncallable(v)) return function.asFunction(v).payload.funcallable.wrapper;
    return heap.asStructure(v).slice()[WRAPPER];
}

/// `(%set-instance-layout instance class wrapper slots)` gives an instance
/// a new class and storage in place, which is what `change-class` and an
/// update for a redefined class come to.
fn setInstanceLayoutFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 4) return Error.WrongArgCount;
    const v = try expectInstance(args[0]);
    if (function.isFuncallable(v)) {
        const instance = &function.asFunction(v).payload.funcallable;
        instance.class = args[1];
        instance.wrapper = args[2];
        instance.slots = args[3];
    } else {
        heap.asStructure(v).name = args[1];
        heap.setSlot(ev.heap, v, WRAPPER, args[2]);
        heap.setSlot(ev.heap, v, SLOTS, args[3]);
    }
    heap.writeBarrier(ev.heap, v, args[1]);
    heap.writeBarrier(ev.heap, v, args[2]);
    heap.writeBarrier(ev.heap, v, args[3]);
    return v;
}

fn setFuncallableFunctionFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!function.isFuncallable(args[0])) return Error.TypeError;
    if (!function.isFunction(args[1])) return Error.TypeError;
    function.asFunction(args[0]).payload.funcallable.function = args[1];
    heap.writeBarrier(ev.heap, args[0], args[1]);
    return args[1];
}

/// `(%set-function-name function name)` names a function for backtraces
/// and the printer. Only the symbol's name is kept.
fn setFunctionNameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!function.isFunction(args[0])) return Error.TypeError;
    const name = try ev.functionNameSymbol(args[1]);
    function.asFunction(args[0]).name = symbol_mod.symbol(name).name;
    return args[0];
}

/// The symbol a `class-of` lookup starts from for an object that is not
/// an instance: the structure's name, or the most specific standard class
/// the object belongs to.
fn builtInClassName(v: Value) Interned {
    if (v.equalsRaw(value.NIL)) return .null_type;
    if (v.isCons()) return .cons;
    if (v.isSymbol()) return .symbol;
    if (v.isFixnum()) return .fixnum;
    if (v.tag() == .char) return .character;
    if (v.tag() != .heap) return .t;
    return switch (heap.heapType(v)) {
        .bignum => .bignum,
        .ratio => .ratio,
        .single_float => .single_float,
        .double_float => .double_float,
        .complex => .complex,
        .string => .string,
        .vector => vectorClassName(v),
        .hash_table => .hash_table,
        .function, .closure => .function,
        .package => .package,
        .pathname => if (heap.asPathname(v).is_logical) .logical_pathname else .pathname,
        .stream => switch (heap.asStream(v).kind) {
            .file => .file_stream,
            .string => .string_stream,
            else => .stream,
        },
        .random_state => .random_state,
        .readtable => .readtable,
        .structure => .structure_object,
        else => .t,
    };
}

fn vectorClassName(v: Value) Interned {
    const a = heap.asArray(v);
    if (a.rank != 1) return .array;
    if (a.element_type == .bit) return .bit_vector;
    return .vector;
}

/// Where a class keeps its name and its precedence list among its slots.
/// `*%class-layout*` in clos.lisp puts them there.
const CLASS_NAME = 0;
const CLASS_PRECEDENCE = 3;
const CLASS_WRAPPER = 9;
const CLASS_SLOT_TABLE = 13;
/// Where a slot definition keeps its type and its location, from
/// `*%slotd-layout*`.
const SLOTD_TYPE = 6;
const SLOTD_LOCATION = 9;

fn classSlot(class: Value, index: usize) Value {
    if (!isStandardInstance(class)) return value.NIL;
    const slots = slotsOf(class);
    if (!heap.isArray(slots) or heap.asArray(slots).storage_len <= index) return value.NIL;
    return heap.arrayElements(slots)[index];
}

pub fn classNameOf(class: Value) Value {
    return classSlot(class, CLASS_NAME);
}

/// Whether `v` is a class: an instance whose own class descends from
/// `class`.
pub fn isClassObject(ev: *Evaluator, v: Value) Error!bool {
    if (!isStandardInstance(v)) return false;
    const key = try interned(ev, .class_key);
    const class_class = symbol_mod.plistGet(try interned(ev, .class), key) orelse return false;
    return inPrecedence(classOf(v), class_class);
}

fn inPrecedence(class: Value, wanted: Value) bool {
    var rest = classSlot(class, CLASS_PRECEDENCE);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        if (heap.car(rest).equalsRaw(wanted)) return true;
    }
    return false;
}

/// `typep` against a class: whether `class` is in the precedence list of
/// the class of `v`.
pub fn classTypep(ev: *Evaluator, v: Value, class: Value) Error!bool {
    return inPrecedence(try classOfValue(ev, v), class);
}

/// The class named `name` on its property list, or null.
pub fn classNamed(ev: *Evaluator, name: Value) Error!?Value {
    if (!name.isSymbol()) return null;
    const class = symbol_mod.plistGet(name, try interned(ev, .class_key)) orelse return null;
    if (class.equalsRaw(value.NIL)) return null;
    return class;
}

/// `(%class-of object)`. A class is kept on its name's property list
/// under `%class`, so a built-in class or a structure's is one lookup.
fn classOfFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return classOfValue(ev, args[0]);
}

pub fn classOfValue(ev: *Evaluator, v: Value) Error!Value {
    if (isInstance(v)) return classOf(v);
    const key = try interned(ev, .class_key);
    if (heap.isStructure(v)) {
        if (symbol_mod.plistGet(heap.asStructure(v).name, key)) |class| {
            if (!class.equalsRaw(value.NIL)) return class;
        }
    }
    const name = try interned(ev, builtInClassName(v));
    if (symbol_mod.plistGet(name, key)) |class| {
        if (!class.equalsRaw(value.NIL)) return class;
    }
    return symbol_mod.plistGet(value.T, key) orelse value.NIL;
}

// --- printing ---

/// The hook the printer asks to print an instance, which runs
/// `print-object` on it.
pub fn objectHook(ev: *Evaluator) printer.ObjectHook {
    return .{ .context = ev.asOpaque(), .wants = &hookWants, .print = &hookPrint };
}

/// An instance always goes to `print-object`. A structure goes there
/// once some `print-object` method is specialized on a structure class.
fn hookWants(context: *anyopaque, v: Value) bool {
    if (isInstance(v)) return true;
    if (!heap.isStructure(v)) return false;
    const ev = Evaluator.fromOpaque(context);
    const flag = interned(ev, .structure_print_object) catch return false;
    const held = symbol_mod.symbol(flag).value_cell;
    return !held.equalsRaw(value.NIL) and !held.equalsRaw(value.SPECIAL_UNBOUND);
}

fn hookPrint(
    context: *anyopaque,
    writer: *std.Io.Writer,
    v: Value,
    settings: printer.Settings,
) printer.PrintError!void {
    const ev = Evaluator.fromOpaque(context);
    printObject(ev, writer, v, settings) catch |e| {
        if (e == Error.OutOfMemory) return error.OutOfMemory;
        ev.print_failure = e;
        return error.WriteFailed;
    };
}

/// Write what `(print-object v stream)` writes, with `*print-escape*` and
/// `*print-readably*` bound to what the printer was asked for.
fn printObject(ev: *Evaluator, writer: *std.Io.Writer, v: Value, settings: printer.Settings) Error!void {
    const print_object = ev.env.lookupFunction(try ev.interner.intern("PRINT-OBJECT")) orelse {
        var unhooked = settings;
        unhooked.unhooked = v;
        return printer.write(ev.allocator, writer, v, unhooked);
    };
    var held = ev.heap.protect();
    defer held.close();
    try held.push(v);
    const stream = try ev.heap.allocStream(streams.emptyStream(.string, .output));
    try held.push(stream);
    const mark = ev.dynamicMark();
    defer ev.unwindSpecials(mark);
    try ev.bindSpecial(try ev.interner.intern("*PRINT-ESCAPE*"), boolv(settings.escape));
    try ev.bindSpecial(try ev.interner.intern("*PRINT-READABLY*"), boolv(settings.readably));
    _ = try ev.callFunction(print_object, &.{ v, stream });
    try writer.writeAll(heap.asStream(stream).output.items);
}

/// `(%write-unhooked object stream)` writes OBJECT the way the printer
/// does for a type with no `print-object` method of its own, which is
/// what the method on `t` comes to.
fn writeUnhookedFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const target = try streams.streamOf(ev, args[1], .output);
    var settings = format.writeSettings(ev);
    settings.unhooked = args[0];
    if (!settings.escape) {
        var arena = std.heap.ArenaAllocator.init(ev.allocator);
        defer arena.deinit();
        if (try format.reportText(ev, arena.allocator(), args[0])) |text| {
            try streams.emitBytes(ev, target, text);
            return args[0];
        }
    }
    const text = printer.writeToOwnedSlice(ev.allocator, args[0], settings) catch |e|
        return ev.printFailure(e);
    defer ev.allocator.free(text);
    try streams.emitBytes(ev, target, text);
    return args[0];
}

/// A number naming where an object sits, for `print-unreadable-object`.
fn objectAddressFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return Value.fromFixnum(@intCast((args[0].raw >> 3) & 0xFFFFFFFFFFFF));
}

// --- slot access ---

fn specialValue(ev: *Evaluator, which: Interned) Error!Value {
    return symbol_mod.symbol(try interned(ev, which)).value_cell;
}

/// The slot definition `name` names in standard instance `v`, or null
/// where the standard route does not apply: `v` is not an instance of a
/// class whose metaclass is a standard one, its layout is out of date,
/// or its class has no such slot.
fn standardSlotd(ev: *Evaluator, v: Value, name: Value) Error!?Value {
    if (!isInstance(v)) return null;
    const class = classOf(v);
    if (!isStandardInstance(class)) return null;
    const metaclass = classOf(class);
    var standard = try specialValue(ev, .standard_metaclasses);
    var found = false;
    while (standard.isCons()) : (standard = heap.cdr(standard)) {
        if (heap.car(standard).equalsRaw(metaclass)) {
            found = true;
            break;
        }
    }
    if (!found) return null;
    const wrapper = if (function.isFuncallable(v))
        function.asFunction(v).payload.funcallable.wrapper
    else
        heap.asStructure(v).slice()[WRAPPER];
    if (!wrapper.equalsRaw(classSlot(class, CLASS_WRAPPER))) return null;
    const table_v = classSlot(class, CLASS_SLOT_TABLE);
    if (!hash_tables.isHashTable(table_v)) return null;
    const table = heap.asHashTable(table_v);
    const index = hash_tables.findEntry(table, name) orelse return null;
    return table.entries.items[index].value;
}

fn slotdField(slotd: Value, index: usize) Value {
    return heap.arrayElements(slotsOf(slotd))[index];
}

/// `(%fast-slot-value object name)`: the value of a slot reached the
/// standard way, or `*%fast-miss*` where the caller has to take the
/// general route, which includes an unbound slot.
fn fastSlotValueFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const miss = try specialValue(ev, .fast_miss);
    const slotd = try standardSlotd(ev, args[0], args[1]) orelse return miss;
    const location = slotdField(slotd, SLOTD_LOCATION);
    const held = if (location.isFixnum())
        heap.arrayElements(slotsOf(args[0]))[@intCast(location.toFixnum())]
    else if (location.isCons())
        heap.cdr(location)
    else
        return miss;
    if (held.equalsRaw(try specialValue(ev, .slot_unbound))) return miss;
    return held;
}

/// `(%fast-set-slot-value object name new)`: t where it stored NEW the
/// standard way, nil where the caller has to, which includes a slot with
/// a type to check.
fn fastSetSlotValueFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    const slotd = try standardSlotd(ev, args[0], args[1]) orelse return value.NIL;
    if (!slotdField(slotd, SLOTD_TYPE).equalsRaw(value.T)) return value.NIL;
    const location = slotdField(slotd, SLOTD_LOCATION);
    if (location.isFixnum()) {
        heap.setSlot(ev.heap, slotsOf(args[0]), @intCast(location.toFixnum()), args[2]);
    } else if (location.isCons()) {
        heap.setCdr(ev.heap, location, args[2]);
    } else return value.NIL;
    return value.T;
}

/// `(%fast-slot-boundp object name)`: t or nil where the standard route
/// answers, and `*%fast-miss*` where it does not.
fn fastSlotBoundpFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const slotd = try standardSlotd(ev, args[0], args[1]) orelse return try specialValue(ev, .fast_miss);
    const location = slotdField(slotd, SLOTD_LOCATION);
    const held = if (location.isFixnum())
        heap.arrayElements(slotsOf(args[0]))[@intCast(location.toFixnum())]
    else if (location.isCons())
        heap.cdr(location)
    else
        return try specialValue(ev, .fast_miss);
    return boolv(!held.equalsRaw(try specialValue(ev, .slot_unbound)));
}

// --- dispatch ---

/// Where a generic function keeps what dispatch reads, from
/// `*%gf-layout*`.
const GF_CACHE = 8;
const GF_EPOCH = 9;
const GF_DISPATCH_POSITIONS = 10;
const GF_REQUIRED_COUNT = 11;
const GF_EQL_POSITIONS = 12;
const GF_ARGUMENT_LIMIT = 15;
/// An eql specializer's object, from `*%eql-layout*`.
const EQL_OBJECT = 0;

/// What the cache is keyed by at one argument position: the eql
/// specializer the argument matches, or its class.
fn dispatchKey(ev: *Evaluator, gf_slots: Value, position: Value, argument: Value) Error!Value {
    var eqls = heap.arrayElements(gf_slots)[GF_EQL_POSITIONS];
    while (eqls.isCons()) : (eqls = heap.cdr(eqls)) {
        const entry = heap.car(eqls);
        if (!heap.car(entry).equalsRaw(position)) continue;
        var specializers = heap.cdr(entry);
        while (specializers.isCons()) : (specializers = heap.cdr(specializers)) {
            const specializer = heap.car(specializers);
            const object = heap.arrayElements(slotsOf(specializer))[EQL_OBJECT];
            if (@import("../runtime/equality.zig").eql(object, argument)) return specializer;
        }
        break;
    }
    return classOfValue(ev, argument);
}

/// `(%gf-dispatch gf arguments)`: run the effective method the cache holds
/// for ARGUMENTS, or let `%gf-dispatch-miss` work one out.
fn gfDispatchFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const gf = args[0];
    const arguments = args[1];
    const miss = ev.env.lookupFunction(try interned(ev, .gf_dispatch_miss)) orelse return Error.UnboundFunction;
    if (!function.isFuncallable(gf) or
        !classOf(gf).equalsRaw(try specialValue(ev, .standard_generic_function)))
    {
        return ev.callFunction(miss, args);
    }
    const gf_slots = slotsOf(gf);
    const fields = heap.arrayElements(gf_slots);

    const required = fields[GF_REQUIRED_COUNT];
    const limit = fields[GF_ARGUMENT_LIMIT];
    {
        var count: i64 = 0;
        var rest = arguments;
        while (rest.isCons()) : (rest = heap.cdr(rest)) count += 1;
        if (required.isFixnum() and count < required.toFixnum()) return ev.callFunction(miss, args);
        if (limit.isFixnum() and count > limit.toFixnum()) return ev.callFunction(miss, args);
    }
    const epoch = try specialValue(ev, .dispatch_epoch);
    if (!fields[GF_EPOCH].equalsRaw(epoch)) return ev.callFunction(miss, args);

    var node = fields[GF_CACHE];
    var positions = fields[GF_DISPATCH_POSITIONS];
    while (positions.isCons()) : (positions = heap.cdr(positions)) {
        if (!hash_tables.isHashTable(node)) return ev.callFunction(miss, args);
        const position = heap.car(positions);
        var argument = arguments;
        var i: i64 = 0;
        while (i < position.toFixnum()) : (i += 1) argument = heap.cdr(argument);
        const key = try dispatchKey(ev, gf_slots, position, heap.car(argument));
        const table = heap.asHashTable(node);
        const index = hash_tables.findEntry(table, key) orelse return ev.callFunction(miss, args);
        node = table.entries.items[index].value;
    }
    if (!function.isFunction(node)) return ev.callFunction(miss, args);
    return ev.callFunction(node, &.{arguments});
}

/// `(%tree-names-function-p tree names)`: whether some `(function name)`
/// in TREE names one of NAMES, which is how a method body is found to
/// take `call-next-method` as an object.
fn treeNamesFunctionPFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(namesFunction(args[0], args[1], try interned(ev, .function)));
}

fn namesFunction(tree: Value, names: Value, function_symbol: Value) bool {
    if (!tree.isCons()) return false;
    if (heap.car(tree).equalsRaw(function_symbol) and heap.cdr(tree).isCons()) {
        const named = heap.car(heap.cdr(tree));
        var walk = names;
        while (walk.isCons()) : (walk = heap.cdr(walk)) {
            if (heap.car(walk).equalsRaw(named)) return true;
        }
    }
    var rest = tree;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        if (namesFunction(heap.car(rest), names, function_symbol)) return true;
    }
    return false;
}

// --- lambda lists and initforms ---

fn lambdaListKeyword(ev: *Evaluator, v: Value) Error!?Interned {
    if (!v.isSymbol()) return null;
    for ([_]Interned{ .amp_optional, .amp_rest, .amp_body, .amp_key, .amp_allow_other_keys, .amp_aux, .amp_whole, .amp_environment }) |which| {
        if (v.equalsRaw(try interned(ev, which))) return which;
    }
    return null;
}

fn lambdaListKeywordPFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(try lambdaListKeyword(ev, args[0]) != null);
}

/// `(%parse-lambda-list lambda-list)`: the list (required optional rest
/// keys allow-other-keys key-p), each part's parameters as written.
fn parseLambdaListFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const Section = enum(u2) { required, optional, key, ignored };
    var section: Section = .required;
    // The parameters go on the Lisp stack section by section, which is
    // the order a lambda list gives them in, so each section's run is
    // contiguous and a collection while the lists are built sees them.
    var held = ev.heap.protect();
    defer held.close();
    try held.push(args[0]);
    var ends: [3]usize = .{ 1, 1, 1 };
    var rest_var = value.NIL;
    var expecting_rest = false;
    var allow = false;
    var key_p = false;
    var walk = held.items()[0];
    while (walk.isCons()) : (walk = heap.cdr(walk)) {
        const item = heap.car(walk);
        if (try lambdaListKeyword(ev, item)) |keyword| {
            expecting_rest = false;
            switch (keyword) {
                .amp_optional => section = .optional,
                .amp_rest, .amp_body => {
                    section = .ignored;
                    expecting_rest = true;
                },
                .amp_key => {
                    section = .key;
                    key_p = true;
                },
                .amp_allow_other_keys => allow = true,
                else => section = .ignored,
            }
            continue;
        }
        if (expecting_rest) {
            rest_var = item;
            expecting_rest = false;
            continue;
        }
        if (section == .ignored) continue;
        try held.push(item);
        const at = @backingInt(section);
        for (ends[at..]) |*end| end.* = held.items().len;
    }
    const starts = [3]usize{ 1, ends[0], ends[1] };
    const required = try ev.heap.list(held.items()[starts[0]..ends[0]]);
    try held.push(required);
    const optional = try ev.heap.list(held.items()[starts[1]..ends[1]]);
    try held.push(optional);
    const keys = try ev.heap.list(held.items()[starts[2]..ends[2]]);
    try held.push(keys);
    const top = held.items().len;
    return ev.heap.list(&.{ held.items()[top - 3], held.items()[top - 2], rest_var, held.items()[top - 1], boolv(allow), boolv(key_p) });
}

/// `(%initial-value initform initfunction)`: what a slot's initform comes
/// to. A constant one is its own value, and anything else is the result
/// of calling INITFUNCTION.
fn initialValueFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const form = args[0];
    if (form.isCons()) {
        if (heap.car(form).equalsRaw(try interned(ev, .quote)) and heap.cdr(form).isCons()) {
            return heap.car(heap.cdr(form));
        }
    } else if (!form.isSymbol() or form.equalsRaw(value.NIL) or form.equalsRaw(value.T) or
        symbol_mod.isKeyword(form, ev.interner))
    {
        return form;
    }
    return ev.callFunction(args[1], &.{});
}

/// `(%direct-instance-p object class)`: whether OBJECT's class is CLASS
/// itself.
fn directInstancePFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    return boolv(isInstance(args[0]) and classOf(args[0]).equalsRaw(args[1]));
}

// --- class precedence lists ---

const CLASS_DIRECT_SUPERCLASSES = 1;

fn directSuperclasses(class: Value) Value {
    return classSlot(class, CLASS_DIRECT_SUPERCLASSES);
}

fn indexIn(items: []const Value, wanted: Value) ?usize {
    for (items, 0..) |item, i| {
        if (item.equalsRaw(wanted)) return i;
    }
    return null;
}

/// `(%topological-cpl class)`: CLASS's precedence list by the sort CLHS
/// 4.3.5 gives, or nil where its superclasses have no consistent order.
/// Among the classes that could come next it takes the one with a direct
/// subclass furthest right in the list built so far.
fn topologicalCplFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const allocator = ev.allocator;

    // Every class above CLASS, each once. Classes do not move while this
    // runs: nothing here allocates on the Lisp heap until the end.
    var classes: std.ArrayList(Value) = .empty;
    defer classes.deinit(allocator);
    try classes.append(allocator, args[0]);
    var scan: usize = 0;
    while (scan < classes.items.len) : (scan += 1) {
        var supers = directSuperclasses(classes.items[scan]);
        while (supers.isCons()) : (supers = heap.cdr(supers)) {
            const super = heap.car(supers);
            if (indexIn(classes.items, super) == null) try classes.append(allocator, super);
        }
    }

    // The local precedence orders as pairs of indices into `classes`.
    const Pair = struct { before: usize, after: usize };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(allocator);
    for (classes.items, 0..) |class, index| {
        var previous = index;
        var supers = directSuperclasses(class);
        while (supers.isCons()) : (supers = heap.cdr(supers)) {
            const at = indexIn(classes.items, heap.car(supers)).?;
            try pairs.append(allocator, .{ .before = previous, .after = at });
            previous = at;
        }
    }

    const placed = try allocator.alloc(bool, classes.items.len);
    defer allocator.free(placed);
    @memset(placed, false);
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    var candidates: std.ArrayList(usize) = .empty;
    defer candidates.deinit(allocator);

    while (order.items.len < classes.items.len) {
        candidates.clearRetainingCapacity();
        for (classes.items, 0..) |_, index| {
            if (placed[index]) continue;
            var preceded = false;
            for (pairs.items) |pair| {
                if (pair.after == index and !placed[pair.before]) {
                    preceded = true;
                    break;
                }
            }
            if (!preceded) try candidates.append(allocator, index);
        }
        if (candidates.items.len == 0) return value.NIL;
        var chosen = candidates.items[0];
        if (candidates.items.len > 1) {
            var found = false;
            var position = order.items.len;
            while (position > 0 and !found) {
                position -= 1;
                var supers = directSuperclasses(classes.items[order.items[position]]);
                while (supers.isCons()) : (supers = heap.cdr(supers)) {
                    const at = indexIn(classes.items, heap.car(supers)).?;
                    if (std.mem.indexOfScalar(usize, candidates.items, at) != null) {
                        chosen = at;
                        found = true;
                        break;
                    }
                }
            }
        }
        placed[chosen] = true;
        try order.append(allocator, chosen);
    }

    const result = try allocator.alloc(Value, order.items.len);
    defer allocator.free(result);
    for (order.items, 0..) |index, i| result[i] = classes.items[index];
    return ev.heap.list(result);
}

/// `(%memq item list)`: the tail of LIST that starts with ITEM, by `eq`.
fn memqFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    var rest = args[1];
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        if (heap.car(rest).equalsRaw(args[0])) return rest;
    }
    return value.NIL;
}

/// `(%find-class-quietly name)`: the class NAME names, or nil.
fn findClassQuietlyFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return try classNamed(ev, args[0]) orelse value.NIL;
}

pub fn registerInstances(ev: *Evaluator) !void {
    _ = try ev.defineNative("%FAST-SLOT-VALUE", &fastSlotValueFn);
    _ = try ev.defineNative("%FAST-SET-SLOT-VALUE", &fastSetSlotValueFn);
    _ = try ev.defineNative("%FAST-SLOT-BOUNDP", &fastSlotBoundpFn);
    _ = try ev.defineNative("%MEMQ", &memqFn);
    _ = try ev.defineNative("%TOPOLOGICAL-CPL", &topologicalCplFn);
    _ = try ev.defineNative("%LAMBDA-LIST-KEYWORD-P", &lambdaListKeywordPFn);
    _ = try ev.defineNative("%PARSE-LAMBDA-LIST", &parseLambdaListFn);
    _ = try ev.defineNative("%INITIAL-VALUE", &initialValueFn);
    _ = try ev.defineNative("%DIRECT-INSTANCE-P", &directInstancePFn);
    _ = try ev.defineNative("%TREE-NAMES-FUNCTION-P", &treeNamesFunctionPFn);
    function.asFunction(try ev.defineNative("%GF-DISPATCH", &gfDispatchFn)).preserves_values = true;
    _ = try ev.defineNative("%FIND-CLASS-QUIETLY", &findClassQuietlyFn);
    _ = try ev.defineNative("%WRITE-UNHOOKED", &writeUnhookedFn);
    _ = try ev.defineNative("%OBJECT-ADDRESS", &objectAddressFn);
    _ = try ev.defineNative("%ALLOCATE-STANDARD-INSTANCE", &allocateStandardFn);
    _ = try ev.defineNative("%ALLOCATE-FUNCALLABLE-INSTANCE", &allocateFuncallableFn);
    _ = try ev.defineNative("%INSTANCE-P", &instancePFn);
    _ = try ev.defineNative("%FUNCALLABLE-INSTANCE-P", &funcallableInstancePFn);
    _ = try ev.defineNative("%INSTANCE-CLASS", &instanceClassFn);
    _ = try ev.defineNative("%INSTANCE-SLOTS", &instanceSlotsFn);
    _ = try ev.defineNative("%INSTANCE-WRAPPER", &instanceWrapperFn);
    _ = try ev.defineNative("%SET-INSTANCE-LAYOUT", &setInstanceLayoutFn);
    _ = try ev.defineNative("%SET-FUNCALLABLE-INSTANCE-FUNCTION", &setFuncallableFunctionFn);
    _ = try ev.defineNative("%SET-FUNCTION-NAME", &setFunctionNameFn);
    _ = try ev.defineNative("%CLASS-OF", &classOfFn);
}
