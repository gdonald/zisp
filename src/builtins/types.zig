//! The type system: `typep`, `type-of`, `deftype`, `coerce`.
//!
//! A type specifier is interpreted rather than compiled. `typep` walks the
//! specifier against a value. `subtypep` is in `src/lisp/types.lisp`.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const instances = @import("instances.zig");
const package_mod = @import("../runtime/package.zig");
const equality = @import("../runtime/equality.zig");
const bignum = @import("../runtime/bignum.zig");
const function = @import("../eval/function.zig");
const eval_mod = @import("../eval/eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerTypes(ev: *Evaluator) !void {
    _ = try ev.defineNative("TYPEP", &typepFn);
    _ = try ev.defineNative("TYPE-OF", &typeOfFn);
    _ = try ev.defineNative("%PUT-DEFTYPE", &putDeftypeFn);
    _ = try ev.defineNative("COERCE", &coerceFn);

    for (std.enums.values(Class)) |class| {
        _ = try ev.interner.intern(nameOf(class));
    }
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

// --- the atomic lattice ---

/// Every atomic type the runtime can talk about. The order is arbitrary;
/// the relationships live in `parentsOf`.
const Class = enum {
    nil_type,
    null_type,
    cons,
    list,
    symbol,
    keyword,
    boolean,
    fixnum,
    bignum,
    integer,
    ratio,
    rational,
    single_float,
    double_float,
    float,
    real,
    complex,
    number,
    character,
    base_char,
    standard_char,
    simple_string,
    base_string,
    string,
    simple_bit_vector,
    bit_vector,
    simple_vector,
    vector,
    simple_array,
    array,
    sequence,
    hash_table,
    function_type,
    package_type,
    logical_pathname,
    pathname,
    stream,
    random_state,
    readtable,
    structure_object,
    atom,
    t_type,
};

fn nameOf(class: Class) []const u8 {
    return switch (class) {
        .nil_type => "NIL",
        .null_type => "NULL",
        .cons => "CONS",
        .list => "LIST",
        .symbol => "SYMBOL",
        .keyword => "KEYWORD",
        .boolean => "BOOLEAN",
        .fixnum => "FIXNUM",
        .bignum => "BIGNUM",
        .integer => "INTEGER",
        .ratio => "RATIO",
        .rational => "RATIONAL",
        .single_float => "SINGLE-FLOAT",
        .double_float => "DOUBLE-FLOAT",
        .float => "FLOAT",
        .real => "REAL",
        .complex => "COMPLEX",
        .number => "NUMBER",
        .character => "CHARACTER",
        .base_char => "BASE-CHAR",
        .standard_char => "STANDARD-CHAR",
        .simple_string => "SIMPLE-STRING",
        .base_string => "BASE-STRING",
        .string => "STRING",
        .simple_bit_vector => "SIMPLE-BIT-VECTOR",
        .bit_vector => "BIT-VECTOR",
        .simple_vector => "SIMPLE-VECTOR",
        .vector => "VECTOR",
        .simple_array => "SIMPLE-ARRAY",
        .array => "ARRAY",
        .sequence => "SEQUENCE",
        .hash_table => "HASH-TABLE",
        .function_type => "FUNCTION",
        .package_type => "PACKAGE",
        .logical_pathname => "LOGICAL-PATHNAME",
        .pathname => "PATHNAME",
        .stream => "STREAM",
        .random_state => "RANDOM-STATE",
        .readtable => "READTABLE",
        .structure_object => "STRUCTURE-OBJECT",
        .atom => "ATOM",
        .t_type => "T",
    };
}

fn classNamed(name: []const u8) ?Class {
    // An array of base characters upgrades to one of characters, so the
    // base string types are the string types.
    if (std.mem.eql(u8, name, "BASE-STRING")) return .string;
    if (std.mem.eql(u8, name, "SIMPLE-BASE-STRING")) return .simple_string;
    for (std.enums.values(Class)) |class| {
        if (std.mem.eql(u8, nameOf(class), name)) return class;
    }
    // Names the standard treats as the same type as one above.
    if (std.mem.eql(u8, name, "SHORT-FLOAT")) return .single_float;
    if (std.mem.eql(u8, name, "LONG-FLOAT")) return .double_float;
    if (std.mem.eql(u8, name, "BIT")) return null;
    return null;
}

/// The classes a class is immediately contained in. A class can have more
/// than one, which is what makes `null` both a symbol and a list.
fn parentsOf(class: Class) []const Class {
    return switch (class) {
        .nil_type => &.{},
        .null_type => &.{ .boolean, .list },
        .cons => &.{.list},
        .list => &.{.sequence},
        .symbol => &.{.atom},
        .keyword => &.{.symbol},
        .boolean => &.{.symbol},
        .fixnum => &.{.integer},
        .bignum => &.{.integer},
        .integer => &.{.rational},
        .ratio => &.{.rational},
        .rational => &.{.real},
        .single_float => &.{.float},
        .double_float => &.{.float},
        .float => &.{.real},
        .real => &.{.number},
        .complex => &.{.number},
        .number => &.{.atom},
        .character => &.{.atom},
        .base_char => &.{.character},
        .standard_char => &.{.base_char},
        .simple_string => &.{.string},
        .base_string => &.{.string},
        .string => &.{.vector},
        .simple_bit_vector => &.{.bit_vector},
        .bit_vector => &.{.vector},
        .simple_vector => &.{ .vector, .simple_array },
        .vector => &.{ .array, .sequence },
        .simple_array => &.{.array},
        .array => &.{.atom},
        .sequence => &.{.t_type},
        .hash_table => &.{.atom},
        .function_type => &.{.atom},
        .package_type => &.{.atom},
        .logical_pathname => &.{.pathname},
        .pathname => &.{.atom},
        .stream => &.{.atom},
        .random_state => &.{.atom},
        .readtable => &.{.atom},
        .structure_object => &.{.atom},
        .atom => &.{.t_type},
        .t_type => &.{},
    };
}

/// Whether `ancestor` contains `class`, directly or through the chain.
fn contains(ancestor: Class, class: Class) bool {
    if (ancestor == class) return true;
    if (ancestor == .t_type) return true;
    if (class == .nil_type) return true;
    for (parentsOf(class)) |parent| {
        if (contains(ancestor, parent)) return true;
    }
    return false;
}

/// The most specific class an object belongs to. `typep` against a class
/// is then a containment question.
fn classOf(ev: *Evaluator, v: Value) Class {
    if (v.equalsRaw(value.NIL)) return .null_type;
    if (v.isCons()) return .cons;
    if (v.isSymbol()) {
        if (v.equalsRaw(value.T)) return .boolean;
        if (symbol_mod.isKeyword(v, ev.interner)) return .keyword;
        return .symbol;
    }
    if (v.isFixnum()) return .fixnum;
    if (v.tag() == .char) return if (v.toChar() <= 0xFF) .base_char else .character;
    if (v.tag() != .heap) return .t_type;
    return switch (heap.heapType(v)) {
        .bignum => .bignum,
        .ratio => .ratio,
        .single_float => .single_float,
        .double_float => .double_float,
        .complex => .complex,
        .string => stringClassOf(v),
        .vector => if (heap.asArray(v).rank == 1) vectorClassOf(v) else .array,
        .hash_table => .hash_table,
        .function, .closure => .function_type,
        .package => .package_type,
        .pathname => if (heap.asPathname(v).is_logical) .logical_pathname else .pathname,
        .stream => .stream,
        .random_state => .random_state,
        .readtable => .readtable,
        .structure => if (instances.isStandardInstance(v)) .t_type else .structure_object,
        else => .t_type,
    };
}

/// `(type-of object)`: the name a structure or condition was defined
/// under, and otherwise the most specific atomic class in the lattice.
fn typeOfFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const v = args[0];
    if (instances.isInstance(v)) {
        const class = instances.classOf(v);
        const name = instances.classNameOf(class);
        const named = try instances.classNamed(ev, name);
        if (named != null and named.?.equalsRaw(class)) return name;
        return class;
    }
    if (heap.isStructure(v) and heap.asStructure(v).name.isSymbol()) return heap.asStructure(v).name;
    return ev.interner.intern(nameOf(classOf(ev, v)));
}

/// A string with no fill pointer and no adjustability is a simple string.
fn stringClassOf(v: Value) Class {
    const s = heap.asString(v);
    return if (s.has_fill_pointer or s.adjustable) .string else .simple_string;
}

fn vectorClassOf(v: Value) Class {
    const a = heap.asArray(v);
    if (a.element_type == .bit) return if (isSimple(v)) .simple_bit_vector else .bit_vector;
    const simple = a.element_type == .t and !a.adjustable and !a.has_fill_pointer and
        a.displaced_to.equalsRaw(value.NIL);
    return if (simple) .simple_vector else .vector;
}

// --- typep ---

/// The bounds of a numeric type specifier. A bound is exclusive when it
/// was written as a one-element list.
const Bound = struct {
    limit: ?Value = null,
    exclusive: bool = false,

    fn parse(ev: *Evaluator, v: Value) Error!Bound {
        _ = ev;
        if (v.equalsRaw(value.NIL)) return .{};
        if (v.isSymbol()) {
            if (std.mem.eql(u8, symbol_mod.symbol(v).name, "*")) return .{};
            return Error.ProgramError;
        }
        if (v.isCons()) {
            if (!heap.cdr(v).equalsRaw(value.NIL)) return Error.ProgramError;
            return .{ .limit = heap.car(v), .exclusive = true };
        }
        return .{ .limit = v };
    }
};

fn compareReals(ev: *Evaluator, a: Value, b: Value) Error!std.math.Order {
    const args = [_]Value{ a, b };
    const lower = try ev.callFunction(
        ev.env.lookupFunction(try ev.interner.intern("<")).?,
        &args,
    );
    if (!lower.equalsRaw(value.NIL)) return .lt;
    const higher = try ev.callFunction(
        ev.env.lookupFunction(try ev.interner.intern(">")).?,
        &args,
    );
    if (!higher.equalsRaw(value.NIL)) return .gt;
    return .eq;
}

fn withinBounds(ev: *Evaluator, v: Value, low: Bound, high: Bound) Error!bool {
    if (low.limit) |limit| {
        const order = try compareReals(ev, v, limit);
        if (order == .lt) return false;
        if (low.exclusive and order == .eq) return false;
    }
    if (high.limit) |limit| {
        const order = try compareReals(ev, v, limit);
        if (order == .gt) return false;
        if (high.exclusive and order == .eq) return false;
    }
    return true;
}

/// The head of a compound specifier, or null for an atomic one.
fn headName(spec: Value) ?[]const u8 {
    if (!spec.isCons()) return null;
    const head = heap.car(spec);
    if (!head.isSymbol()) return null;
    return symbol_mod.symbol(head).name;
}

fn nthArg(spec: Value, index: usize) Value {
    var rest = heap.cdr(spec);
    var i: usize = 0;
    while (i < index) : (i += 1) {
        if (!rest.isCons()) return value.NIL;
        rest = heap.cdr(rest);
    }
    if (!rest.isCons()) return value.NIL;
    return heap.car(rest);
}

/// A `deftype` expansion for `spec`, or null when the name is not one.
fn deftypeExpansion(ev: *Evaluator, spec: Value) Error!?Value {
    const name = if (spec.isSymbol()) spec else if (spec.isCons()) heap.car(spec) else return null;
    if (!name.isSymbol()) return null;
    const key = try ev.interner.intern("%DEFTYPE-EXPANDER");
    const expander = symbol_mod.plistGet(name, key) orelse return null;
    const args = if (spec.isCons()) heap.cdr(spec) else value.NIL;
    return try ev.callFunction(expander, &.{args});
}

pub fn typep(ev: *Evaluator, v: Value, spec: Value) Error!bool {
    if (spec.isSymbol()) return typepAtomic(ev, v, spec);
    if (try instances.isClassObject(ev, spec)) return instances.classTypep(ev, v, spec);
    if (!spec.isCons()) return Error.ProgramError;
    return typepCompound(ev, v, spec);
}

/// An array with no fill pointer, not adjustable and not displaced.
fn isSimple(v: Value) bool {
    if (heap.isString(v)) {
        const s = heap.asString(v);
        return !s.has_fill_pointer and !s.adjustable and !s.isDisplaced();
    }
    if (!heap.isArray(v)) return false;
    const a = heap.asArray(v);
    const displaced = !(a.displaced_to.raw == 0 or a.displaced_to.equalsRaw(value.NIL));
    return !a.adjustable and !a.has_fill_pointer and !displaced;
}

fn typepAtomic(ev: *Evaluator, v: Value, spec: Value) Error!bool {
    const name = symbol_mod.symbol(spec).name;
    if (std.mem.eql(u8, name, "SIMPLE-ARRAY")) return (heap.isString(v) or heap.isArray(v)) and isSimple(v);
    if (std.mem.eql(u8, name, "BIT")) {
        return v.isFixnum() and (v.toFixnum() == 0 or v.toFixnum() == 1);
    }
    if (std.mem.eql(u8, name, "FILE-STREAM")) {
        return heap.isStream(v) and heap.asStream(v).kind == .file;
    }
    if (std.mem.eql(u8, name, "STRING-STREAM")) {
        return heap.isStream(v) and heap.asStream(v).kind == .string;
    }
    if (std.mem.eql(u8, name, "COMPILED-FUNCTION")) return function.isCompiledFunction(v);
    if (classNamed(name)) |class| {
        if (class == .nil_type) return false;
        return contains(class, classOf(ev, v));
    }
    if (try instances.classNamed(ev, spec)) |class| {
        if (try instances.isClassObject(ev, class)) return instances.classTypep(ev, v, class);
    }
    if (try deftypeExpansion(ev, spec)) |expansion| return typep(ev, v, expansion);
    // A structure name is a type naming its own instances.
    if (heap.isStructure(v) and heap.asStructure(v).name.equalsRaw(spec)) return true;
    if (try isStructureName(ev, spec)) return false;
    return Error.ProgramError;
}

fn isStructureName(ev: *Evaluator, name: Value) Error!bool {
    const key = try ev.interner.intern("%STRUCTURE-SLOTS");
    return symbol_mod.plistGet(name, key) != null;
}

fn typepCompound(ev: *Evaluator, v: Value, spec: Value) Error!bool {
    const name = headName(spec) orelse return Error.ProgramError;

    if (std.mem.eql(u8, name, "OR")) {
        var rest = heap.cdr(spec);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            if (try typep(ev, v, heap.car(rest))) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, name, "AND")) {
        var rest = heap.cdr(spec);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            if (!try typep(ev, v, heap.car(rest))) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NOT")) return !try typep(ev, v, nthArg(spec, 0));
    if (std.mem.eql(u8, name, "MEMBER")) {
        var rest = heap.cdr(spec);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            if (equality.eql(v, heap.car(rest))) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, name, "EQL")) return equality.eql(v, nthArg(spec, 0));
    if (std.mem.eql(u8, name, "SATISFIES")) {
        const pred = nthArg(spec, 0);
        const fn_v = if (function.isFunction(pred))
            pred
        else
            ev.env.lookupFunction(pred) orelse return ev.unbound(pred, Error.UnboundFunction);
        return !(try ev.callFunction(fn_v, &.{v})).equalsRaw(value.NIL);
    }
    if (std.mem.eql(u8, name, "CONS")) {
        if (!v.isCons()) return false;
        const car_spec = nthArg(spec, 0);
        const cdr_spec = nthArg(spec, 1);
        if (!try wildOrType(ev, heap.car(v), car_spec)) return false;
        return wildOrType(ev, heap.cdr(v), cdr_spec);
    }
    if (std.mem.eql(u8, name, "MOD")) {
        const limit = nthArg(spec, 0);
        if (!bignum.isInteger(v) or !limit.isFixnum()) return false;
        return !bignum.isNegative(v) and bignum.compare(v, limit) == .lt;
    }
    if (std.mem.eql(u8, name, "UNSIGNED-BYTE") or std.mem.eql(u8, name, "SIGNED-BYTE")) {
        return byteType(ev, v, spec, name[0] == 'U');
    }
    if (numericClassNamed(name)) |class| {
        if (!contains(class, classOf(ev, v))) return false;
        const low = try Bound.parse(ev, nthArg(spec, 0));
        const high = try Bound.parse(ev, nthArg(spec, 1));
        return withinBounds(ev, v, low, high);
    }
    if (std.mem.eql(u8, name, "ARRAY") or std.mem.eql(u8, name, "SIMPLE-ARRAY") or
        std.mem.eql(u8, name, "VECTOR") or std.mem.eql(u8, name, "STRING"))
    {
        return arrayType(ev, v, spec, name);
    }
    if (try instances.classNamed(ev, spec)) |class| {
        if (try instances.isClassObject(ev, class)) return instances.classTypep(ev, v, class);
    }
    if (try deftypeExpansion(ev, spec)) |expansion| return typep(ev, v, expansion);
    return Error.ProgramError;
}

fn wildOrType(ev: *Evaluator, v: Value, spec: Value) Error!bool {
    if (spec.equalsRaw(value.NIL)) return true;
    if (spec.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(spec).name, "*")) return true;
    return typep(ev, v, spec);
}

fn numericClassNamed(name: []const u8) ?Class {
    if (std.mem.eql(u8, name, "INTEGER")) return .integer;
    if (std.mem.eql(u8, name, "RATIONAL")) return .rational;
    if (std.mem.eql(u8, name, "REAL")) return .real;
    if (std.mem.eql(u8, name, "FLOAT")) return .float;
    if (std.mem.eql(u8, name, "SINGLE-FLOAT") or std.mem.eql(u8, name, "SHORT-FLOAT")) return .single_float;
    if (std.mem.eql(u8, name, "DOUBLE-FLOAT") or std.mem.eql(u8, name, "LONG-FLOAT")) return .double_float;
    return null;
}

/// `(unsigned-byte n)` is the integers `0` to `2^n - 1`; the signed form
/// is the two's-complement range of `n` bits.
fn byteType(ev: *Evaluator, v: Value, spec: Value, unsigned: bool) Error!bool {
    if (!bignum.isInteger(v)) return false;
    const bits_spec = nthArg(spec, 0);
    if (!bits_spec.isFixnum()) {
        // `(unsigned-byte)` with no size is every non-negative integer.
        return !unsigned or !bignum.isNegative(v);
    }
    const bits: usize = @intCast(bits_spec.toFixnum());
    if (unsigned) {
        if (bignum.isNegative(v)) return false;
        return bignum.bitCountAbs(v) <= bits;
    }
    if (bits == 0) return bignum.isZero(v);
    const limit = try bignum.shiftLeft(ev.heap, Value.fromFixnum(1), bits - 1);
    if (bignum.isNegative(v)) {
        const magnitude = try bignum.negate(ev.heap, v);
        return bignum.compare(magnitude, limit) != .gt;
    }
    return bignum.compare(v, limit) == .lt;
}

fn arrayType(ev: *Evaluator, v: Value, spec: Value, name: []const u8) Error!bool {
    if (std.mem.eql(u8, name, "SIMPLE-ARRAY")) {
        if (!(heap.isString(v) or heap.isArray(v)) or !isSimple(v)) return false;
    } else {
        const base = classNamed(name).?;
        if (!contains(base, classOf(ev, v))) return false;
    }
    if (std.mem.eql(u8, name, "STRING")) {
        const size = nthArg(spec, 0);
        if (!size.isFixnum()) return true;
        return heap.asString(v).len == @as(u64, @intCast(size.toFixnum()));
    }
    const element = nthArg(spec, 0);
    if (!element.equalsRaw(value.NIL) and !isWildcard(element)) {
        if (!try elementTypeMatches(ev, v, element)) return false;
    }
    const dims = nthArg(spec, 1);
    if (dims.equalsRaw(value.NIL) or isWildcard(dims)) return true;
    // A vector's second argument is its length, where an array's is the
    // list of dimensions.
    if (std.mem.eql(u8, name, "VECTOR")) {
        if (!dims.isFixnum()) return false;
        return rankOf(v) == 1 and dimensionAt(v, 0) == @as(u64, @intCast(dims.toFixnum()));
    }
    return dimensionsMatch(v, dims);
}

fn isWildcard(v: Value) bool {
    return v.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(v).name, "*");
}

/// Whether `v`'s element type is what `spec` upgrades to, which is what
/// an array type specifier with an element type means to `typep`.
fn elementTypeMatches(ev: *Evaluator, v: Value, given: Value) Error!bool {
    const upgrade = ev.env.lookupFunction(try ev.interner.intern("UPGRADED-ARRAY-ELEMENT-TYPE"));
    const spec = if (upgrade) |f| try ev.callFunction(f, &.{given}) else given;
    const actual = if (heap.isString(v))
        try ev.interner.intern("CHARACTER")
    else switch (heap.asArray(v).element_type) {
        .t => value.T,
        .character => try ev.interner.intern("CHARACTER"),
        .bit => try ev.interner.intern("BIT"),
        .unsigned_byte_8 => value.NIL,
    };
    if (actual.equalsRaw(value.NIL)) {
        // The byte element type is a compound specifier, compared as text.
        return spec.isCons() and std.mem.eql(u8, headName(spec) orelse "", "UNSIGNED-BYTE");
    }
    return equality.equal(actual, spec);
}

fn dimensionsMatch(v: Value, dims: Value) bool {
    if (dims.isFixnum()) {
        const rank: u64 = @intCast(dims.toFixnum());
        return rankOf(v) == rank;
    }
    var rest = dims;
    var axis: usize = 0;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const want = heap.car(rest);
        if (axis >= rankOf(v)) return false;
        if (!isWildcard(want)) {
            if (!want.isFixnum()) return false;
            if (dimensionAt(v, axis) != @as(u64, @intCast(want.toFixnum()))) return false;
        }
        axis += 1;
    }
    return axis == rankOf(v);
}

fn rankOf(v: Value) u64 {
    if (heap.isString(v)) return 1;
    return heap.asArray(v).rank;
}

fn dimensionAt(v: Value, axis: usize) u64 {
    if (heap.isString(v)) return heap.asString(v).capacity;
    return heap.asArray(v).dimensions()[axis];
}

fn typepFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    return boolv(try typep(ev, args[0], args[1]));
}

/// `deftype` stores its expander on the name's property list, which is
/// where `typep` and `subtypep` look for it.
fn putDeftypeFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const key = try ev.interner.intern("%DEFTYPE-EXPANDER");
    try symbol_mod.plistPut(ev.heap, args[0], key, args[1]);
    return args[0];
}

// --- coerce ---

fn coerceFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const spec = args[1];
    // Already of the type asked for, so nothing to do.
    if (typep(ev, args[0], spec) catch false) return args[0];

    const name = if (spec.isSymbol())
        symbol_mod.symbol(spec).name
    else
        headName(spec) orelse return Error.TypeError;

    // What `concatenate` builds one of, given the same specifier.
    const sequence_types = [_][]const u8{
        "LIST",          "VECTOR",      "STRING",             "SIMPLE-VECTOR",
        "SIMPLE-STRING", "BASE-STRING", "SIMPLE-BASE-STRING", "ARRAY",
    };
    for (sequence_types) |candidate| {
        if (std.mem.eql(u8, name, candidate)) {
            return callNamed(ev, "CONCATENATE", &.{ spec, args[0] });
        }
    }
    if (std.mem.eql(u8, name, "CHARACTER")) return callNamed(ev, "CHARACTER", &.{args[0]});
    if (std.mem.eql(u8, name, "FLOAT") or std.mem.eql(u8, name, "SINGLE-FLOAT") or
        std.mem.eql(u8, name, "SHORT-FLOAT"))
    {
        return callNamed(ev, "FLOAT", &.{args[0]});
    }
    if (std.mem.eql(u8, name, "DOUBLE-FLOAT") or std.mem.eql(u8, name, "LONG-FLOAT")) {
        return callNamed(ev, "FLOAT", &.{ args[0], try ev.heap.allocDoubleFloat(0) });
    }
    if (std.mem.eql(u8, name, "COMPLEX")) return callNamed(ev, "COMPLEX", &.{args[0]});
    if (std.mem.eql(u8, name, "FUNCTION")) return callNamed(ev, "SYMBOL-FUNCTION", &.{args[0]});
    if (std.mem.eql(u8, name, "T")) return args[0];
    return Error.TypeError;
}

fn callNamed(ev: *Evaluator, name: []const u8, args: []const Value) Error!Value {
    const sym = try ev.interner.intern(name);
    const fn_v = ev.env.lookupFunction(sym) orelse return ev.unbound(sym, Error.UnboundFunction);
    return ev.callFunction(fn_v, args);
}
