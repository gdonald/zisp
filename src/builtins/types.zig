//! The type system: `typep`, `subtypep`, `deftype`, `coerce`.
//!
//! A type specifier is interpreted rather than compiled. `typep` walks the
//! specifier against a value; `subtypep` reduces both sides to a small
//! lattice of atomic classes plus numeric intervals and compares those.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
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
    _ = try ev.defineNative("%PUT-DEFTYPE", &putDeftypeFn);
    _ = try ev.defineNative("COERCE", &coerceFn);
    function.asFunction(try ev.defineNative("SUBTYPEP", &subtypepFn)).preserves_values = true;

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
    for (std.enums.values(Class)) |class| {
        if (std.mem.eql(u8, nameOf(class), name)) return class;
    }
    // Names the standard treats as the same type as one above.
    if (std.mem.eql(u8, name, "SIMPLE-BASE-STRING")) return .base_string;
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

/// Two classes overlap when some class lies in both, which is how `null`
/// keeps `symbol` and `list` from being disjoint.
fn overlaps(a: Class, b: Class) bool {
    if (contains(a, b) or contains(b, a)) return true;
    for (std.enums.values(Class)) |candidate| {
        if (candidate == .nil_type) continue;
        if (contains(a, candidate) and contains(b, candidate)) return true;
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
        .structure => .structure_object,
        else => .t_type,
    };
}

/// A string with no fill pointer and no adjustability is a simple string.
fn stringClassOf(v: Value) Class {
    const s = heap.asString(v);
    return if (s.has_fill_pointer or s.adjustable) .string else .simple_string;
}

fn vectorClassOf(v: Value) Class {
    const a = heap.asArray(v);
    if (a.element_type == .bit) return .bit_vector;
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
    if (!spec.isCons()) return Error.ProgramError;
    return typepCompound(ev, v, spec);
}

fn typepAtomic(ev: *Evaluator, v: Value, spec: Value) Error!bool {
    const name = symbol_mod.symbol(spec).name;
    if (std.mem.eql(u8, name, "BIT")) {
        return v.isFixnum() and (v.toFixnum() == 0 or v.toFixnum() == 1);
    }
    if (classNamed(name)) |class| {
        if (class == .nil_type) return false;
        return contains(class, classOf(ev, v));
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
    const base = classNamed(name).?;
    if (!contains(base, classOf(ev, v))) return false;
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

fn elementTypeMatches(ev: *Evaluator, v: Value, spec: Value) Error!bool {
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

// --- subtypep ---

/// A type specifier reduced to something comparable: an atomic class,
/// optionally narrowed to a numeric interval.
const Reduced = struct {
    class: Class,
    low: Bound = .{},
    high: Bound = .{},
    /// Set when the specifier carried more than the class and interval,
    /// so a containment answer would be a guess.
    approximate: bool = false,
};

/// The pair `subtypep` returns: the answer, and whether it is certain.
const Answer = struct { yes: bool, certain: bool };

const UNCERTAIN = Answer{ .yes = false, .certain = false };

fn reduce(ev: *Evaluator, spec: Value) Error!?Reduced {
    if (spec.isSymbol()) {
        const name = symbol_mod.symbol(spec).name;
        if (std.mem.eql(u8, name, "BIT")) {
            return Reduced{
                .class = .integer,
                .low = .{ .limit = Value.fromFixnum(0) },
                .high = .{ .limit = Value.fromFixnum(1) },
            };
        }
        if (classNamed(name)) |class| return Reduced{ .class = class };
        if (try deftypeExpansion(ev, spec)) |expansion| return reduce(ev, expansion);
        if (try isStructureName(ev, spec)) return Reduced{ .class = .structure_object, .approximate = true };
        return null;
    }
    if (!spec.isCons()) return null;
    const name = headName(spec) orelse return null;

    if (numericClassNamed(name)) |class| {
        return try normalizeIntegerBounds(ev, .{
            .class = class,
            .low = try Bound.parse(ev, nthArg(spec, 0)),
            .high = try Bound.parse(ev, nthArg(spec, 1)),
        });
    }
    if (std.mem.eql(u8, name, "MOD")) {
        const limit = nthArg(spec, 0);
        if (!limit.isFixnum()) return null;
        return try normalizeIntegerBounds(ev, .{
            .class = .integer,
            .low = .{ .limit = Value.fromFixnum(0) },
            .high = .{ .limit = limit, .exclusive = true },
        });
    }
    if (std.mem.eql(u8, name, "UNSIGNED-BYTE") or std.mem.eql(u8, name, "SIGNED-BYTE")) {
        return try reduceByte(ev, spec, name[0] == 'U');
    }
    if (classNamed(name)) |class| {
        // An array or string specifier with arguments narrows the class in
        // ways the interval model cannot express.
        const bare = heap.cdr(spec).equalsRaw(value.NIL);
        return Reduced{ .class = class, .approximate = !bare };
    }
    if (try deftypeExpansion(ev, spec)) |expansion| return reduce(ev, expansion);
    return null;
}

/// An exclusive bound on an integer type names the same set as the
/// inclusive bound one step in, and comparing two intervals is only
/// straightforward once both are written the same way.
fn normalizeIntegerBounds(ev: *Evaluator, r: Reduced) Error!Reduced {
    if (!contains(.integer, r.class)) return r;
    var out = r;
    if (out.low.exclusive) {
        if (out.low.limit) |limit| {
            if (!bignum.isInteger(limit)) return out;
            out.low = .{ .limit = try bignum.add(ev.heap, limit, Value.fromFixnum(1)) };
        }
    }
    if (out.high.exclusive) {
        if (out.high.limit) |limit| {
            if (!bignum.isInteger(limit)) return out;
            out.high = .{ .limit = try bignum.sub(ev.heap, limit, Value.fromFixnum(1)) };
        }
    }
    return out;
}

fn reduceByte(ev: *Evaluator, spec: Value, unsigned: bool) Error!?Reduced {
    const bits_spec = nthArg(spec, 0);
    if (!bits_spec.isFixnum()) {
        if (!unsigned) return Reduced{ .class = .integer };
        return Reduced{ .class = .integer, .low = .{ .limit = Value.fromFixnum(0) } };
    }
    const bits: usize = @intCast(bits_spec.toFixnum());
    if (unsigned) {
        const limit = try bignum.shiftLeft(ev.heap, Value.fromFixnum(1), bits);
        return Reduced{
            .class = .integer,
            .low = .{ .limit = Value.fromFixnum(0) },
            .high = .{ .limit = try bignum.sub(ev.heap, limit, Value.fromFixnum(1)) },
        };
    }
    if (bits == 0) {
        return Reduced{
            .class = .integer,
            .low = .{ .limit = Value.fromFixnum(0) },
            .high = .{ .limit = Value.fromFixnum(0) },
        };
    }
    const limit = try bignum.shiftLeft(ev.heap, Value.fromFixnum(1), bits - 1);
    return Reduced{
        .class = .integer,
        .low = .{ .limit = try bignum.negate(ev.heap, limit) },
        .high = .{ .limit = try bignum.sub(ev.heap, limit, Value.fromFixnum(1)) },
    };
}

/// Whether the interval of `inner` sits inside that of `outer`. An absent
/// bound is unbounded, so it contains any bound on the same side.
fn intervalWithin(ev: *Evaluator, inner: Reduced, outer: Reduced) Error!bool {
    if (outer.low.limit) |outer_low| {
        const inner_low = inner.low.limit orelse return false;
        const order = try compareReals(ev, inner_low, outer_low);
        if (order == .lt) return false;
        if (order == .eq and outer.low.exclusive and !inner.low.exclusive) return false;
    }
    if (outer.high.limit) |outer_high| {
        const inner_high = inner.high.limit orelse return false;
        const order = try compareReals(ev, inner_high, outer_high);
        if (order == .gt) return false;
        if (order == .eq and outer.high.exclusive and !inner.high.exclusive) return false;
    }
    return true;
}

fn hasInterval(r: Reduced) bool {
    return r.low.limit != null or r.high.limit != null;
}

pub fn subtypep(ev: *Evaluator, a_spec: Value, b_spec: Value) Error!Answer {
    if (equality.equal(a_spec, b_spec)) return .{ .yes = true, .certain = true };

    // The combinators reduce to questions about their parts.
    if (try combinatorAnswer(ev, a_spec, b_spec)) |answer| return answer;

    const a = try reduce(ev, a_spec) orelse return UNCERTAIN;
    const b = try reduce(ev, b_spec) orelse return UNCERTAIN;
    if (a.class == .nil_type) return .{ .yes = true, .certain = true };
    if (b.class == .t_type) return .{ .yes = true, .certain = true };

    if (!contains(b.class, a.class)) {
        // A narrowed class cannot reach outside the class it narrows, so
        // the containment question is settled either way.
        if (a.approximate or b.approximate) return UNCERTAIN;
        return .{ .yes = false, .certain = true };
    }
    if (a.approximate or b.approximate) return UNCERTAIN;
    if (!hasInterval(b)) return .{ .yes = true, .certain = true };
    if (!hasInterval(a) and hasInterval(b)) return .{ .yes = false, .certain = true };
    return .{ .yes = try intervalWithin(ev, a, b), .certain = true };
}

/// `or`, `and` and `not` on either side, reduced to their parts. Returns
/// null when neither side is a combinator.
fn combinatorAnswer(ev: *Evaluator, a_spec: Value, b_spec: Value) Error!?Answer {
    if (headName(a_spec)) |name| {
        // Every branch of a union must fit for the union to fit.
        if (std.mem.eql(u8, name, "OR")) {
            var rest = heap.cdr(a_spec);
            var certain = true;
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                const answer = try subtypep(ev, heap.car(rest), b_spec);
                if (answer.certain and !answer.yes) return Answer{ .yes = false, .certain = true };
                if (!answer.certain) certain = false;
            }
            return Answer{ .yes = certain, .certain = certain };
        }
        // One branch of an intersection fitting is enough.
        if (std.mem.eql(u8, name, "AND")) {
            var rest = heap.cdr(a_spec);
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                const answer = try subtypep(ev, heap.car(rest), b_spec);
                if (answer.certain and answer.yes) return Answer{ .yes = true, .certain = true };
            }
            return UNCERTAIN;
        }
        if (std.mem.eql(u8, name, "NOT")) return UNCERTAIN;
    }
    if (headName(b_spec)) |name| {
        // Fitting one branch of a union is enough to fit the union.
        if (std.mem.eql(u8, name, "OR")) {
            var rest = heap.cdr(b_spec);
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                const answer = try subtypep(ev, a_spec, heap.car(rest));
                if (answer.certain and answer.yes) return Answer{ .yes = true, .certain = true };
            }
            return UNCERTAIN;
        }
        // Fitting an intersection means fitting every branch.
        if (std.mem.eql(u8, name, "AND")) {
            var rest = heap.cdr(b_spec);
            var certain = true;
            while (rest.isCons()) : (rest = heap.cdr(rest)) {
                const answer = try subtypep(ev, a_spec, heap.car(rest));
                if (answer.certain and !answer.yes) return Answer{ .yes = false, .certain = true };
                if (!answer.certain) certain = false;
            }
            return Answer{ .yes = certain, .certain = certain };
        }
        if (std.mem.eql(u8, name, "NOT")) {
            // `A ⊆ (not B)` holds when A and B share nothing, which the
            // lattice can answer for two plain classes.
            const a = try reduce(ev, a_spec) orelse return UNCERTAIN;
            const b = try reduce(ev, nthArg(b_spec, 0)) orelse return UNCERTAIN;
            if (a.approximate or b.approximate or hasInterval(a) or hasInterval(b)) return UNCERTAIN;
            if (!overlaps(a.class, b.class)) return Answer{ .yes = true, .certain = true };
            return UNCERTAIN;
        }
    }
    return null;
}

fn subtypepFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2 or args.len > 3) return Error.WrongArgCount;
    const answer = try subtypep(ev, args[0], args[1]);
    return ev.setValues(&.{ boolv(answer.yes), boolv(answer.certain) });
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

    if (std.mem.eql(u8, name, "LIST") or std.mem.eql(u8, name, "VECTOR") or
        std.mem.eql(u8, name, "STRING") or std.mem.eql(u8, name, "SIMPLE-VECTOR") or
        std.mem.eql(u8, name, "SIMPLE-STRING") or std.mem.eql(u8, name, "ARRAY"))
    {
        return callNamed(ev, "CONCATENATE", &.{ spec, args[0] });
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
