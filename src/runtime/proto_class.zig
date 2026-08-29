//! The class system conditions are built on until CLOS lands.
//!
//! Everything about a condition class lives here: what a class holds,
//! how a definition linearizes its supers, how the slots of a hierarchy
//! combine, and how an instance stores them. `docs/condition-bootstrap.md`
//! is the plan, and CLOS deletes this file whole.
//!
//! A class and an instance are both heap structures. A class carries the
//! symbol `%condition-class` where an instance carries its class, so the
//! two are told apart by what that one field holds.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

/// The fields of a class, in the order it stores them.
const Field = enum(usize) {
    name,
    direct_supers,
    precedence,
    slots,
    report,

    const count = 5;
};

const CLASS_MARKER = "%CONDITION-CLASS";

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

/// Whether `v` is a class object rather than an instance or a structure.
pub fn isClass(ev: *Evaluator, v: Value) bool {
    if (!heap.isStructure(v)) return false;
    const marker = ev.interner.lookup(CLASS_MARKER) orelse return false;
    return heap.asStructure(v).name.equalsRaw(marker);
}

/// Whether `v` is an instance of some class here, which is what makes it
/// a condition.
pub fn isInstance(ev: *Evaluator, v: Value) bool {
    if (!heap.isStructure(v)) return false;
    return isClass(ev, heap.asStructure(v).name);
}

pub fn classOf(v: Value) Value {
    return heap.asStructure(v).name;
}

fn field(class: Value, which: Field) Value {
    return heap.asStructure(class).slice()[@intFromEnum(which)];
}

pub fn className(class: Value) Value {
    return field(class, .name);
}

pub fn reportOf(class: Value) Value {
    return field(class, .report);
}

/// The report of `class` or of the nearest class it descends from that
/// has one, which is what a `print-object` method would inherit.
pub fn inheritedReport(class: Value) Value {
    var rest = field(class, .precedence);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const held = field(heap.car(rest), .report);
        if (!held.equalsRaw(value.NIL)) return held;
    }
    return value.NIL;
}

/// Whether `class` is `wanted` or descends from it, which is the whole of
/// `typep` for a condition.
pub fn descendsFrom(class: Value, wanted: Value) bool {
    var rest = field(class, .precedence);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        if (heap.car(rest).equalsRaw(wanted)) return true;
    }
    return false;
}

// --- definition ---

/// `(%make-condition-class name supers slots report)` builds a class.
///
/// `supers` is a list of class objects and `slots` a list of
/// `(name (initarg ...) initform-function-or-nil)`. The precedence list
/// and the effective slots are worked out here and never recomputed: a
/// condition class may not be redefined.
fn makeClassFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 4) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;

    var held = ev.heap.protect();
    defer held.close();
    for (args) |a| try held.push(a);

    const precedence = try linearize(ev, args[1]);
    try held.push(precedence);
    const slots = try combineSlots(ev, precedence, args[2]);
    try held.push(slots);

    const marker = try ev.interner.intern(CLASS_MARKER);
    var fields: [Field.count]Value = .{ args[0], args[1], value.NIL, slots, args[3] };
    const class = try ev.heap.allocStructure(marker, &fields);
    try held.push(class);
    // A class stands at the head of its own precedence list, which it can
    // only be told once it exists.
    const whole = try ev.heap.allocCons(class, precedence);
    heap.setSlot(ev.heap, class, @intFromEnum(Field.precedence), whole);
    return class;
}

/// The classes `supers` and their supers, most specific first, each
/// appearing once at its last position. A condition hierarchy is shallow
/// and its supers are listed in the order they should be tried, so this
/// walk gives the same answer the standard ordering does.
fn linearize(ev: *Evaluator, supers: Value) Error!Value {
    var seen: std.ArrayList(Value) = .empty;
    defer seen.deinit(ev.allocator);
    try collectSupers(ev, supers, &seen);

    var result = value.NIL;
    var index = seen.items.len;
    while (index > 0) {
        index -= 1;
        const class = seen.items[index];
        if (indexOf(seen.items[0..index], class) != null) continue;
        result = try ev.heap.allocCons(class, result);
    }
    return result;
}

fn indexOf(list: []const Value, wanted: Value) ?usize {
    for (list, 0..) |v, i| {
        if (v.equalsRaw(wanted)) return i;
    }
    return null;
}

fn collectSupers(ev: *Evaluator, supers: Value, out: *std.ArrayList(Value)) Error!void {
    var rest = supers;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const class = heap.car(rest);
        if (!isClass(ev, class)) return Error.TypeError;
        try out.append(ev.allocator, class);
        var inherited = field(class, .precedence);
        // The head of a class's precedence list is the class itself,
        // which is already recorded.
        if (inherited.isCons()) inherited = heap.cdr(inherited);
        while (inherited.isCons()) : (inherited = heap.cdr(inherited)) {
            try out.append(ev.allocator, heap.car(inherited));
        }
    }
}

/// The slots of the whole hierarchy, least specific first, with a slot
/// named twice keeping the most specific definition at the position the
/// least specific one gave it. An instance stores one value per entry,
/// in this order, so a reader is an index.
fn combineSlots(ev: *Evaluator, precedence: Value, direct: Value) Error!Value {
    var names: std.ArrayList(Value) = .empty;
    defer names.deinit(ev.allocator);
    var specs: std.ArrayList(Value) = .empty;
    defer specs.deinit(ev.allocator);

    var inherited: std.ArrayList(Value) = .empty;
    defer inherited.deinit(ev.allocator);
    var rest = precedence;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try inherited.append(ev.allocator, heap.car(rest));
    }
    var index = inherited.items.len;
    while (index > 0) {
        index -= 1;
        try addSlots(ev, field(inherited.items[index], .slots), &names, &specs);
    }
    try addSlots(ev, direct, &names, &specs);

    var result = value.NIL;
    var i = specs.items.len;
    while (i > 0) {
        i -= 1;
        result = try ev.heap.allocCons(specs.items[i], result);
    }
    return result;
}

fn addSlots(
    ev: *Evaluator,
    slots: Value,
    names: *std.ArrayList(Value),
    specs: *std.ArrayList(Value),
) Error!void {
    var rest = slots;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const spec = heap.car(rest);
        if (!spec.isCons()) return Error.TypeError;
        const name = heap.car(spec);
        if (indexOf(names.items, name)) |at| {
            specs.items[at] = spec;
            continue;
        }
        try names.append(ev.allocator, name);
        try specs.append(ev.allocator, spec);
    }
}

// --- instances ---

/// `(%allocate-condition class)` builds an instance with every slot
/// unbound.
fn allocateFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!isClass(ev, args[0])) return Error.TypeError;

    var held = ev.heap.protect();
    defer held.close();
    try held.push(args[0]);

    var slots: std.ArrayList(Value) = .empty;
    defer slots.deinit(ev.allocator);
    var rest = field(args[0], .slots);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try slots.append(ev.allocator, value.SPECIAL_SLOT_UNBOUND);
    }
    return ev.heap.allocStructure(args[0], slots.items);
}

fn classPFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isClass(ev, args[0]));
}

fn conditionPFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(isInstance(ev, args[0]));
}

fn classOfFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!isInstance(ev, args[0])) return Error.TypeError;
    return classOf(args[0]);
}

fn classNameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!isClass(ev, args[0])) return Error.TypeError;
    return className(args[0]);
}

fn classSlotsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!isClass(ev, args[0])) return Error.TypeError;
    return field(args[0], .slots);
}

fn classReportFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const class = if (isClass(ev, args[0]))
        args[0]
    else if (isInstance(ev, args[0]))
        classOf(args[0])
    else
        return Error.TypeError;
    return inheritedReport(class);
}

/// `(%condition-typep object class)` is `typep` for a condition.
fn typepFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!isClass(ev, args[1])) return Error.TypeError;
    if (!isInstance(ev, args[0])) return value.NIL;
    return boolv(descendsFrom(classOf(args[0]), args[1]));
}

/// `(%condition-subtypep class other)` is `subtypep` for two of them.
fn subtypepFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!isClass(ev, args[0]) or !isClass(ev, args[1])) return Error.TypeError;
    return boolv(descendsFrom(args[0], args[1]));
}

/// Where `name` sits in an instance, or nil where the class has no such
/// slot.
fn slotIndexFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const class = if (isClass(ev, args[0]))
        args[0]
    else if (isInstance(ev, args[0]))
        classOf(args[0])
    else
        return Error.TypeError;

    var index: i64 = 0;
    var rest = field(class, .slots);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        if (heap.car(heap.car(rest)).equalsRaw(args[1])) return Value.fromFixnum(index);
        index += 1;
    }
    return value.NIL;
}

fn slotAt(ev: *Evaluator, object: Value, index: Value) Error!usize {
    if (!isInstance(ev, object)) return Error.TypeError;
    if (!index.isFixnum() or index.toFixnum() < 0) return Error.TypeError;
    const at: usize = @intCast(index.toFixnum());
    if (at >= heap.asStructure(object).len) return Error.TypeError;
    return at;
}

fn refFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const at = try slotAt(ev, args[0], args[1]);
    const held = heap.asStructure(args[0]).slice()[at];
    if (held.equalsRaw(value.SPECIAL_SLOT_UNBOUND)) return Error.UnboundVariable;
    return held;
}

fn setRefFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 3) return Error.WrongArgCount;
    const at = try slotAt(ev, args[0], args[1]);
    heap.setSlot(ev.heap, args[0], at, args[2]);
    return args[2];
}

fn boundpFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const at = try slotAt(ev, args[0], args[1]);
    return boolv(!heap.asStructure(args[0]).slice()[at].equalsRaw(value.SPECIAL_SLOT_UNBOUND));
}

fn makunboundFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const at = try slotAt(ev, args[0], args[1]);
    heap.setSlot(ev.heap, args[0], at, value.SPECIAL_SLOT_UNBOUND);
    return args[0];
}

pub fn registerProtoClass(ev: *Evaluator) !void {
    _ = try ev.defineNative("%MAKE-CONDITION-CLASS", &makeClassFn);
    _ = try ev.defineNative("%CONDITION-CLASS-P", &classPFn);
    _ = try ev.defineNative("%CONDITION-CLASS-NAME", &classNameFn);
    _ = try ev.defineNative("%CONDITION-CLASS-SLOTS", &classSlotsFn);
    _ = try ev.defineNative("%CONDITION-CLASS-REPORT", &classReportFn);
    _ = try ev.defineNative("%ALLOCATE-CONDITION", &allocateFn);
    _ = try ev.defineNative("%CONDITION-P", &conditionPFn);
    _ = try ev.defineNative("%CONDITION-CLASS-OF", &classOfFn);
    _ = try ev.defineNative("%CONDITION-TYPEP", &typepFn);
    _ = try ev.defineNative("%CONDITION-SUBTYPEP", &subtypepFn);
    _ = try ev.defineNative("%CONDITION-SLOT-INDEX", &slotIndexFn);
    _ = try ev.defineNative("%CONDITION-REF", &refFn);
    _ = try ev.defineNative("%SET-CONDITION-REF", &setRefFn);
    _ = try ev.defineNative("%CONDITION-BOUNDP", &boundpFn);
    _ = try ev.defineNative("%CONDITION-MAKUNBOUND", &makunboundFn);
}
