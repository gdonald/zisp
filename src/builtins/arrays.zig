//! Array builtins: construction, element access by subscript, the
//! introspection functions, the fill-pointer operations, and adjustment.
//!
//! Every array holds one `Value` slot per element whatever its element
//! type; the type restricts what may be stored and is what
//! `array-element-type` reports. A rank-one array of characters is a
//! string, which has its own byte storage.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const ElementType = heap.ElementType;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerArrays(ev: *Evaluator) !void {
    _ = try ev.defineNative("VECTOR", &vectorFn);
    _ = try ev.defineNative("MAKE-ARRAY", &makeArrayFn);
    _ = try ev.defineNative("AREF", &arefFn);
    _ = try ev.defineNative("%SET-AREF", &setArefFn);
    _ = try ev.defineNative("ROW-MAJOR-AREF", &rowMajorArefFn);
    _ = try ev.defineNative("%SET-ROW-MAJOR-AREF", &setRowMajorArefFn);
    _ = try ev.defineNative("ARRAYP", &arraypFn);
    _ = try ev.defineNative("VECTORP", &vectorpFn);
    _ = try ev.defineNative("SIMPLE-VECTOR-P", &simpleVectorPFn);
    _ = try ev.defineNative("BIT-VECTOR-P", &bitVectorPFn);
    _ = try ev.defineNative("ARRAY-RANK", &arrayRankFn);
    _ = try ev.defineNative("ARRAY-DIMENSIONS", &arrayDimensionsFn);
    _ = try ev.defineNative("ARRAY-DIMENSION", &arrayDimensionFn);
    _ = try ev.defineNative("ARRAY-TOTAL-SIZE", &arrayTotalSizeFn);
    _ = try ev.defineNative("ARRAY-ELEMENT-TYPE", &arrayElementTypeFn);
    // Returns the target and the offset together, so the values channel
    // it fills must survive the call.
    function.asFunction(try ev.defineNative("ARRAY-DISPLACEMENT", &arrayDisplacementFn))
        .preserves_values = true;
    _ = try ev.defineNative("ADJUSTABLE-ARRAY-P", &adjustableArrayPFn);
    _ = try ev.defineNative("ARRAY-HAS-FILL-POINTER-P", &hasFillPointerFn);
    _ = try ev.defineNative("FILL-POINTER", &fillPointerFn);
    _ = try ev.defineNative("%SET-FILL-POINTER", &setFillPointerFn);
    _ = try ev.defineNative("VECTOR-PUSH", &vectorPushFn);
    _ = try ev.defineNative("VECTOR-PUSH-EXTEND", &vectorPushExtendFn);
    _ = try ev.defineNative("VECTOR-POP", &vectorPopFn);
    _ = try ev.defineNative("ADJUST-ARRAY", &adjustArrayFn);

    // Intern the element-type names now. Reading user source interns every
    // name it mentions into the current package, so a name first created
    // later would be a different symbol from the one `array-element-type`
    // hands back.
    for ([_][]const u8{ "BIT", "CHARACTER", "UNSIGNED-BYTE", "BASE-CHAR", "STANDARD-CHAR" }) |n| {
        _ = try ev.interner.intern(n);
    }
}

// --- element types ---

fn elementTypeOf(spec: Value) Error!ElementType {
    if (spec.equalsRaw(value.T)) return .t;
    if (spec.isSymbol()) {
        const n = symbol_mod.symbol(spec).name;
        if (std.mem.eql(u8, n, "BIT")) return .bit;
        if (std.mem.eql(u8, n, "CHARACTER") or std.mem.eql(u8, n, "BASE-CHAR") or
            std.mem.eql(u8, n, "STANDARD-CHAR")) return .character;
        return .t;
    }
    // `(unsigned-byte 8)` is the only compound element type recognized.
    if (spec.isCons() and heap.car(spec).isSymbol()) {
        const head = symbol_mod.symbol(heap.car(spec)).name;
        const rest = heap.cdr(spec);
        if (std.mem.eql(u8, head, "UNSIGNED-BYTE") and rest.isCons()) {
            const bits = heap.car(rest);
            if (bits.isFixnum() and bits.toFixnum() == 8) return .unsigned_byte_8;
            if (bits.isFixnum() and bits.toFixnum() == 1) return .bit;
        }
        return .t;
    }
    return .t;
}

fn elementTypeName(ev: *Evaluator, element_type: ElementType) Error!Value {
    return switch (element_type) {
        .t => value.T,
        .character => ev.interner.intern("CHARACTER"),
        .bit => ev.interner.intern("BIT"),
        .unsigned_byte_8 => ev.heap.list(
            &.{ try ev.interner.intern("UNSIGNED-BYTE"), Value.fromFixnum(8) },
        ),
    };
}

/// Reject an element the array's type has no room for.
fn checkElement(element_type: ElementType, element: Value) Error!void {
    switch (element_type) {
        .t => {},
        .character => if (element.tag() != .char) return Error.TypeError,
        .bit => {
            if (!element.isFixnum()) return Error.TypeError;
            if (element.toFixnum() != 0 and element.toFixnum() != 1) return Error.TypeError;
        },
        .unsigned_byte_8 => {
            if (!element.isFixnum()) return Error.TypeError;
            if (element.toFixnum() < 0 or element.toFixnum() > 255) return Error.TypeError;
        },
    }
}

fn defaultElement(element_type: ElementType) Value {
    return switch (element_type) {
        .t => value.NIL,
        .character => Value.fromChar(' '),
        .bit, .unsigned_byte_8 => Value.fromFixnum(0),
    };
}

// --- construction ---

fn vectorFn(p: *anyopaque, args: []const Value) Error!Value {
    return evaluator(p).heap.allocVector(args);
}

/// A dimension specifier is a non-negative integer or a list of them.
fn dimensionList(ev: *Evaluator, spec: Value, out: *std.ArrayList(usize)) Error!void {
    if (spec.isFixnum()) {
        if (spec.toFixnum() < 0) return Error.TypeError;
        try out.append(ev.allocator, @intCast(spec.toFixnum()));
        return;
    }
    var rest = spec;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const d = heap.car(rest);
        if (!d.isFixnum() or d.toFixnum() < 0) return Error.TypeError;
        try out.append(ev.allocator, @intCast(d.toFixnum()));
    }
    if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
}

const MakeArrayOptions = struct {
    element_type: ElementType = .t,
    initial_element: ?Value = null,
    initial_contents: ?Value = null,
    adjustable: bool = false,
    fill_pointer: ?Value = null,
    displaced_to: ?Value = null,
    displaced_index_offset: usize = 0,
};

fn parseMakeArrayOptions(ev: *Evaluator, args: []const Value) Error!MakeArrayOptions {
    if (args.len % 2 != 0) return Error.WrongArgCount;
    var options = MakeArrayOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const given = args[i + 1];
        if (try keywordIs(ev, args[i], "ELEMENT-TYPE")) {
            options.element_type = try elementTypeOf(given);
        } else if (try keywordIs(ev, args[i], "INITIAL-ELEMENT")) {
            options.initial_element = given;
        } else if (try keywordIs(ev, args[i], "INITIAL-CONTENTS")) {
            options.initial_contents = given;
        } else if (try keywordIs(ev, args[i], "ADJUSTABLE")) {
            options.adjustable = !given.equalsRaw(value.NIL);
        } else if (try keywordIs(ev, args[i], "FILL-POINTER")) {
            options.fill_pointer = given;
        } else if (try keywordIs(ev, args[i], "DISPLACED-TO")) {
            options.displaced_to = if (given.equalsRaw(value.NIL)) null else given;
        } else if (try keywordIs(ev, args[i], "DISPLACED-INDEX-OFFSET")) {
            if (!given.isFixnum() or given.toFixnum() < 0) return Error.TypeError;
            options.displaced_index_offset = @intCast(given.toFixnum());
        } else return Error.ProgramError;
    }
    if (options.initial_element != null and options.initial_contents != null) {
        return Error.ProgramError;
    }
    if (options.displaced_to != null and
        (options.initial_element != null or options.initial_contents != null))
    {
        return Error.ProgramError;
    }
    return options;
}

fn keywordIs(ev: *Evaluator, key: Value, name: []const u8) Error!bool {
    return key.equalsRaw(try ev.interner.internKeyword(name));
}

fn makeArrayFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1) return Error.WrongArgCount;
    const options = try parseMakeArrayOptions(ev, args[1..]);

    var sizes: std.ArrayList(usize) = .empty;
    defer sizes.deinit(ev.allocator);
    try dimensionList(ev, args[0], &sizes);

    if (options.fill_pointer != null and sizes.items.len != 1) return Error.TypeError;

    if (options.element_type == .character and sizes.items.len == 1) {
        return makeCharacterVector(ev, sizes.items[0], options);
    }
    return makeGeneralArray(ev, sizes.items, options);
}

/// A one-dimensional array of characters is a string, so it gets the
/// string representation rather than a slot per character.
fn makeCharacterVector(ev: *Evaluator, size: usize, options: MakeArrayOptions) Error!Value {
    if (options.displaced_to != null) return Error.TypeError;
    const result = try ev.heap.allocStringWithCapacity(size, size);
    const s = heap.asString(result);
    s.adjustable = options.adjustable;
    @memset(s.allocated(), ' ');

    if (options.initial_element) |element| {
        if (element.tag() != .char) return Error.TypeError;
        @memset(s.allocated(), element.toChar());
    }
    if (options.initial_contents) |contents| {
        var elements: std.ArrayList(Value) = .empty;
        defer elements.deinit(ev.allocator);
        try flattenContents(ev, contents, &.{size}, &elements);
        for (elements.items, s.allocated()) |element, *c| {
            if (element.tag() != .char) return Error.TypeError;
            c.* = element.toChar();
        }
    }
    if (options.fill_pointer) |fp| {
        s.has_fill_pointer = true;
        s.len = try fillPointerValue(fp, size);
    }
    return result;
}

fn makeGeneralArray(ev: *Evaluator, sizes: []const usize, options: MakeArrayOptions) Error!Value {
    const result = try ev.heap.allocArray(sizes, options.element_type);
    const a = heap.asArray(result);
    a.adjustable = options.adjustable;

    if (options.displaced_to) |target| {
        try displace(ev, result, target, options.displaced_index_offset);
    } else {
        @memset(heap.arrayElements(result), defaultElement(options.element_type));
        if (options.initial_element) |element| {
            try checkElement(options.element_type, element);
            @memset(heap.arrayElements(result), element);
        }
        if (options.initial_contents) |contents| {
            var elements: std.ArrayList(Value) = .empty;
            defer elements.deinit(ev.allocator);
            try flattenContents(ev, contents, sizes, &elements);
            for (elements.items) |element| try checkElement(options.element_type, element);
            @memcpy(heap.arrayElements(result), elements.items);
        }
    }
    if (options.fill_pointer) |fp| {
        a.has_fill_pointer = true;
        a.fill_pointer = try fillPointerValue(fp, a.totalSize());
    }
    return result;
}

/// `:fill-pointer t` means "as full as it goes"; an integer must be a
/// valid index bound.
fn fillPointerValue(given: Value, size: usize) Error!u64 {
    if (given.equalsRaw(value.T)) return size;
    if (!given.isFixnum() or given.toFixnum() < 0) return Error.TypeError;
    const n: usize = @intCast(given.toFixnum());
    if (n > size) return Error.TypeError;
    return n;
}

/// Read `:initial-contents`, one nesting level per dimension, into
/// row-major order.
fn flattenContents(
    ev: *Evaluator,
    contents: Value,
    sizes: []const usize,
    out: *std.ArrayList(Value),
) Error!void {
    if (sizes.len == 0) {
        try out.append(ev.allocator, contents);
        return;
    }
    var seen: usize = 0;
    switch (try sequenceElements(ev, contents)) {
        .list => |list| {
            var rest = list;
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                try flattenContents(ev, heap.car(rest), sizes[1..], out);
                seen += 1;
            }
            if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
        },
        .slots => |slots| for (slots) |element| {
            try flattenContents(ev, element, sizes[1..], out);
            seen += 1;
        },
        .chars => |chars| for (chars) |c| {
            try flattenContents(ev, Value.fromChar(@intCast(c)), sizes[1..], out);
            seen += 1;
        },
    }
    if (seen != sizes[0]) return Error.TypeError;
}

const SequenceView = union(enum) { list: Value, slots: []const Value, chars: []const u32 };

fn sequenceElements(ev: *Evaluator, v: Value) Error!SequenceView {
    _ = ev;
    if (v.equalsRaw(value.NIL) or v.isCons()) return .{ .list = v };
    if (heap.isString(v)) return .{ .chars = heap.asString(v).constSlice() };
    if (heap.isArray(v)) return .{ .slots = heap.arrayActive(v) };
    return Error.TypeError;
}

/// Point an array at another array's storage, checking that the whole
/// displaced extent lands inside the target.
fn displace(ev: *Evaluator, array: Value, target: Value, offset: usize) Error!void {
    _ = ev;
    if (!heap.isArray(target)) return Error.TypeError;
    const a = heap.asArray(array);
    if (offset + a.totalSize() > heap.asArray(target).totalSize()) return Error.TypeError;
    a.displaced_to = target;
    a.displaced_offset = offset;
}

// --- element access ---

fn expectArray(v: Value) Error!*heap.HeapArray {
    if (!heap.isArray(v)) return Error.TypeError;
    return heap.asArray(v);
}

/// Fold subscripts into a row-major index, bounds-checking each axis.
fn rowMajorIndex(a: *heap.HeapArray, subscripts: []const Value) Error!usize {
    if (subscripts.len != a.rank) return Error.ProgramError;
    var index: usize = 0;
    for (subscripts, a.dimensions()) |subscript, size| {
        if (!subscript.isFixnum() or subscript.toFixnum() < 0) return Error.TypeError;
        const i: usize = @intCast(subscript.toFixnum());
        if (i >= size) return Error.TypeError;
        index = index * @as(usize, @intCast(size)) + i;
    }
    return index;
}

/// `aref` reaches past a fill pointer, so a string is indexed over its
/// whole storage rather than its active length.
fn stringIndex(v: Value, subscripts: []const Value) Error!usize {
    if (subscripts.len != 1) return Error.ProgramError;
    const s = heap.asString(v);
    if (!subscripts[0].isFixnum() or subscripts[0].toFixnum() < 0) return Error.TypeError;
    const i: usize = @intCast(subscripts[0].toFixnum());
    if (i >= s.capacity) return Error.TypeError;
    return i;
}

fn arefFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len < 1) return Error.WrongArgCount;
    if (heap.isString(args[0])) {
        const code = heap.asString(args[0]).allocated()[try stringIndex(args[0], args[1..])];
        return Value.fromChar(@intCast(code));
    }
    const a = try expectArray(args[0]);
    return heap.arrayElements(args[0])[try rowMajorIndex(a, args[1..])];
}

fn setArefFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len < 2) return Error.WrongArgCount;
    const new_value = args[args.len - 1];
    const subscripts = args[1 .. args.len - 1];
    if (heap.isString(args[0])) {
        if (new_value.tag() != .char) return Error.TypeError;
        heap.asString(args[0]).allocated()[try stringIndex(args[0], subscripts)] =
            new_value.toChar();
        return new_value;
    }
    const a = try expectArray(args[0]);
    try checkElement(a.element_type, new_value);
    heap.arrayElements(args[0])[try rowMajorIndex(a, subscripts)] = new_value;
    return new_value;
}

fn rowMajorOffset(v: Value, index_v: Value, limit: usize) Error!usize {
    _ = v;
    if (!index_v.isFixnum() or index_v.toFixnum() < 0) return Error.TypeError;
    const i: usize = @intCast(index_v.toFixnum());
    if (i >= limit) return Error.TypeError;
    return i;
}

fn rowMajorArefFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (heap.isString(args[0])) {
        const s = heap.asString(args[0]);
        const code = s.allocated()[try rowMajorOffset(args[0], args[1], s.capacity)];
        return Value.fromChar(@intCast(code));
    }
    const a = try expectArray(args[0]);
    return heap.arrayElements(args[0])[try rowMajorOffset(args[0], args[1], a.totalSize())];
}

fn setRowMajorArefFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 3) return Error.WrongArgCount;
    if (heap.isString(args[0])) {
        const s = heap.asString(args[0]);
        if (args[2].tag() != .char) return Error.TypeError;
        s.allocated()[try rowMajorOffset(args[0], args[1], s.capacity)] = args[2].toChar();
        return args[2];
    }
    const a = try expectArray(args[0]);
    try checkElement(a.element_type, args[2]);
    heap.arrayElements(args[0])[try rowMajorOffset(args[0], args[1], a.totalSize())] = args[2];
    return args[2];
}

// --- introspection ---

fn isAnyArray(v: Value) bool {
    return heap.isString(v) or heap.isArray(v);
}

fn oneArg(args: []const Value) Error!Value {
    if (args.len != 1) return Error.WrongArgCount;
    return args[0];
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

fn arraypFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    return boolv(isAnyArray(try oneArg(args)));
}

fn rankOf(v: Value) Error!usize {
    if (heap.isString(v)) return 1;
    return (try expectArray(v)).rank;
}

fn vectorpFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (!isAnyArray(v)) return value.NIL;
    return boolv((try rankOf(v)) == 1);
}

fn simpleVectorPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (!heap.isArray(v)) return value.NIL;
    const a = heap.asArray(v);
    return boolv(a.rank == 1 and a.element_type == .t and !a.adjustable and
        !a.has_fill_pointer and a.displaced_to.equalsRaw(value.NIL));
}

fn bitVectorPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (!heap.isArray(v)) return value.NIL;
    const a = heap.asArray(v);
    return boolv(a.rank == 1 and a.element_type == .bit);
}

fn arrayRankFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    return Value.fromFixnum(@intCast(try rankOf(try oneArg(args))));
}

fn arrayDimensionsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    const v = try oneArg(args);
    if (heap.isString(v)) {
        return ev.heap.allocCons(Value.fromFixnum(@intCast(heap.asString(v).capacity)), value.NIL);
    }
    const a = try expectArray(v);
    var builder = ev.heap.listBuilder();
    for (a.dimensions()) |size| try builder.append(Value.fromFixnum(@intCast(size)));
    return builder.finish();
}

fn arrayDimensionFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[1].isFixnum() or args[1].toFixnum() < 0) return Error.TypeError;
    const axis: usize = @intCast(args[1].toFixnum());
    if (heap.isString(args[0])) {
        if (axis != 0) return Error.TypeError;
        return Value.fromFixnum(@intCast(heap.asString(args[0]).capacity));
    }
    const a = try expectArray(args[0]);
    if (axis >= a.rank) return Error.TypeError;
    return Value.fromFixnum(@intCast(a.dimensions()[axis]));
}

fn arrayTotalSizeFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (heap.isString(v)) return Value.fromFixnum(@intCast(heap.asString(v).capacity));
    return Value.fromFixnum(@intCast((try expectArray(v)).totalSize()));
}

fn arrayElementTypeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    const v = try oneArg(args);
    if (heap.isString(v)) return ev.interner.intern("CHARACTER");
    return elementTypeName(ev, (try expectArray(v)).element_type);
}

fn arrayDisplacementFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    const v = try oneArg(args);
    if (heap.isString(v)) return ev.setValues(&.{ value.NIL, Value.fromFixnum(0) });
    const a = try expectArray(v);
    return ev.setValues(&.{ a.displaced_to, Value.fromFixnum(@intCast(a.displaced_offset)) });
}

fn adjustableArrayPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (heap.isString(v)) return boolv(heap.asString(v).adjustable);
    return boolv((try expectArray(v)).adjustable);
}

fn hasFillPointerFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (heap.isString(v)) return boolv(heap.asString(v).has_fill_pointer);
    return boolv((try expectArray(v)).has_fill_pointer);
}

fn fillPointerFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    if (heap.isString(v)) {
        const s = heap.asString(v);
        if (!s.has_fill_pointer) return Error.TypeError;
        return Value.fromFixnum(@intCast(s.len));
    }
    const a = try expectArray(v);
    if (!a.has_fill_pointer) return Error.TypeError;
    return Value.fromFixnum(@intCast(a.fill_pointer));
}

fn setFillPointerFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    if (heap.isString(args[0])) {
        const s = heap.asString(args[0]);
        if (!s.has_fill_pointer) return Error.TypeError;
        s.len = try fillPointerValue(args[1], s.capacity);
        return args[1];
    }
    const a = try expectArray(args[0]);
    if (!a.has_fill_pointer) return Error.TypeError;
    a.fill_pointer = try fillPointerValue(args[1], a.totalSize());
    return args[1];
}

// --- fill-pointer operations ---

/// Room left past the fill pointer, and where the next element goes.
const PushTarget = struct { index: usize, capacity: usize };

fn pushTarget(v: Value) Error!PushTarget {
    if (heap.isString(v)) {
        const s = heap.asString(v);
        if (!s.has_fill_pointer) return Error.TypeError;
        return .{ .index = @intCast(s.len), .capacity = s.capacity };
    }
    const a = try expectArray(v);
    if (!a.has_fill_pointer or a.rank != 1) return Error.TypeError;
    return .{ .index = @intCast(a.fill_pointer), .capacity = a.totalSize() };
}

fn storeAt(v: Value, index: usize, element: Value) Error!void {
    if (heap.isString(v)) {
        if (element.tag() != .char) return Error.TypeError;
        heap.asString(v).allocated()[index] = element.toChar();
        return;
    }
    const a = heap.asArray(v);
    try checkElement(a.element_type, element);
    heap.arrayElements(v)[index] = element;
}

fn bumpFillPointer(v: Value, to: usize) void {
    if (heap.isString(v)) {
        heap.asString(v).len = to;
        return;
    }
    heap.asArray(v).fill_pointer = to;
}

fn vectorPushFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 2) return Error.WrongArgCount;
    const target = try pushTarget(args[1]);
    if (target.index >= target.capacity) return value.NIL;
    try storeAt(args[1], target.index, args[0]);
    bumpFillPointer(args[1], target.index + 1);
    return Value.fromFixnum(@intCast(target.index));
}

fn vectorPushExtendFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    var target = try pushTarget(args[1]);
    if (target.index >= target.capacity) {
        const extension: usize = if (args.len == 3) blk: {
            if (!args[2].isFixnum() or args[2].toFixnum() <= 0) return Error.TypeError;
            break :blk @intCast(args[2].toFixnum());
        } else @max(target.capacity, 4);
        try grow(ev, args[1], target.capacity + extension);
        target = try pushTarget(args[1]);
    }
    try storeAt(args[1], target.index, args[0]);
    bumpFillPointer(args[1], target.index + 1);
    return Value.fromFixnum(@intCast(target.index));
}

fn grow(ev: *Evaluator, v: Value, capacity: usize) Error!void {
    if (heap.isString(v)) {
        const s = heap.asString(v);
        const old = s.capacity;
        try ev.heap.resizeString(v, capacity);
        @memset(s.allocated()[old..], ' ');
        return;
    }
    const a = heap.asArray(v);
    const fill = a.fill_pointer;
    const old = a.totalSize();
    try ev.heap.resizeArray(v, &.{capacity});
    a.fill_pointer = fill;
    @memset(heap.arrayElements(v)[old..], defaultElement(a.element_type));
}

fn vectorPopFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    const v = try oneArg(args);
    const target = try pushTarget(v);
    if (target.index == 0) return Error.ProgramError;
    const index = target.index - 1;
    bumpFillPointer(v, index);
    if (heap.isString(v)) return Value.fromChar(@intCast(heap.asString(v).allocated()[index]));
    return heap.arrayElements(v)[index];
}

// --- adjust-array ---

fn adjustArrayFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const options = try parseMakeArrayOptions(ev, args[2..]);

    var sizes: std.ArrayList(usize) = .empty;
    defer sizes.deinit(ev.allocator);
    try dimensionList(ev, args[1], &sizes);

    if (heap.isString(args[0])) return adjustString(ev, args[0], sizes.items, options);
    const a = try expectArray(args[0]);
    if (sizes.items.len != a.rank) return Error.TypeError;

    // A non-adjustable array is replaced rather than changed, so the
    // caller's other references keep the array they already had.
    if (!a.adjustable) {
        var fresh = options;
        fresh.element_type = a.element_type;
        fresh.adjustable = false;
        if (fresh.initial_contents == null and fresh.displaced_to == null) {
            return copyInto(ev, args[0], sizes.items, fresh);
        }
        return makeGeneralArray(ev, sizes.items, fresh);
    }

    const old_fill = a.fill_pointer;
    const had_fill = a.has_fill_pointer;
    if (options.displaced_to) |t| {
        try ev.heap.resizeArray(args[0], sizes.items);
        try displace(ev, args[0], t, options.displaced_index_offset);
    } else if (options.initial_contents) |contents| {
        try ev.heap.resizeArray(args[0], sizes.items);
        var elements: std.ArrayList(Value) = .empty;
        defer elements.deinit(ev.allocator);
        try flattenContents(ev, contents, sizes.items, &elements);
        for (elements.items) |element| try checkElement(a.element_type, element);
        @memcpy(heap.arrayElements(args[0]), elements.items);
    } else {
        const old = try ev.allocator.dupe(Value, heap.arrayElements(args[0]));
        defer ev.allocator.free(old);
        try ev.heap.resizeArray(args[0], sizes.items);
        const slots = heap.arrayElements(args[0]);
        const fill_value = options.initial_element orelse defaultElement(a.element_type);
        if (options.initial_element) |element| try checkElement(a.element_type, element);
        @memset(slots, fill_value);
        const keep = @min(old.len, slots.len);
        @memcpy(slots[0..keep], old[0..keep]);
    }
    a.has_fill_pointer = had_fill;
    a.fill_pointer = @min(old_fill, a.totalSize());
    if (options.fill_pointer) |fp| {
        a.has_fill_pointer = true;
        a.fill_pointer = try fillPointerValue(fp, a.totalSize());
    }
    return args[0];
}

/// Adjusting a non-adjustable array yields a fresh one holding as much of
/// the original as still fits.
fn copyInto(ev: *Evaluator, source: Value, sizes: []const usize, options: MakeArrayOptions) Error!Value {
    const result = try makeGeneralArray(ev, sizes, options);
    const old = heap.arrayElements(source);
    const slots = heap.arrayElements(result);
    const keep = @min(old.len, slots.len);
    @memcpy(slots[0..keep], old[0..keep]);
    return result;
}

fn adjustString(ev: *Evaluator, v: Value, sizes: []const usize, options: MakeArrayOptions) Error!Value {
    if (sizes.len != 1) return Error.TypeError;
    const size = sizes[0];
    const s = heap.asString(v);
    if (!s.adjustable) {
        var fresh = options;
        fresh.element_type = .character;
        const result = try makeCharacterVector(ev, size, fresh);
        const keep = @min(s.capacity, size);
        @memcpy(heap.asString(result).allocated()[0..keep], s.allocated()[0..keep]);
        return result;
    }
    const old = s.capacity;
    try ev.heap.resizeString(v, size);
    if (size > old) {
        const fill: u32 = if (options.initial_element) |element| blk: {
            if (element.tag() != .char) return Error.TypeError;
            break :blk element.toChar();
        } else ' ';
        @memset(s.allocated()[old..], fill);
    }
    if (!s.has_fill_pointer) s.len = size;
    if (s.len > size) s.len = size;
    if (options.fill_pointer) |fp| {
        s.has_fill_pointer = true;
        s.len = try fillPointerValue(fp, size);
    }
    return v;
}
