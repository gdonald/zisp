const std = @import("std");
const value = @import("value.zig");
const pretty = @import("pretty.zig");
const circle = @import("circle.zig");
const Value = value.Value;

pub const Cons = extern struct {
    car: Value,
    cdr: Value,
};

comptime {
    std.debug.assert(@sizeOf(Cons) == 16);
    std.debug.assert(@alignOf(Cons) >= 8);
}

pub const HeapType = enum(u8) {
    string = 0,
    vector = 1,
    hash_table = 2,
    function = 3,
    bignum = 4,
    package = 5,
    pathname = 6,
    stream = 7,
    ratio = 8,
    complex = 9,
    single_float = 10,
    double_float = 11,
    weak_pointer = 12,
    closure = 13,
    structure = 14,
    random_state = 15,
    _,
};

pub const HeapHeader = packed struct(u64) {
    type_tag: HeapType,
    mark: bool = false,
    forwarded: bool = false,
    pinned: bool = false,
    _reserved: u5 = 0,
    size: u48,
};

comptime {
    std.debug.assert(@sizeOf(HeapHeader) == 8);
}

pub const HeapObject = extern struct {
    header: HeapHeader,
};

/// String: one codepoint per element, so indexing and in-place update are
/// constant time at any character width. Storage is held indirectly so an
/// adjustable string can be reallocated without moving the object every
/// other value points at. `len` is the active length, which is the fill
/// pointer when the string has one.
pub const HeapString = extern struct {
    header: HeapHeader,
    len: u64,
    capacity: u64,
    codes: [*]u32,
    has_fill_pointer: bool,
    adjustable: bool,
    _pad: [6]u8 = .{0} ** 6,

    pub fn slice(self: *HeapString) []u32 {
        return self.codes[0..self.len];
    }
    pub fn constSlice(self: *const HeapString) []const u32 {
        return self.codes[0..self.len];
    }
    /// Everything the storage can hold, past the fill pointer included.
    pub fn allocated(self: *HeapString) []u32 {
        return self.codes[0..self.capacity];
    }
};

/// Single-precision float box. The fixed `_pad` keeps `value` 8-byte
/// aligned so the GC can scan headers uniformly.
pub const HeapSingleFloat = extern struct {
    header: HeapHeader,
    value: f32,
    _pad: u32 = 0,
};

pub const HeapDoubleFloat = extern struct {
    header: HeapHeader,
    value: f64,
};

/// Exact ratio of two fixnums — for now this only stores the lexeme's
/// literal numerator/denominator. Arithmetic will normalize and promote
/// to bignum when needed.
pub const HeapRatio = extern struct {
    header: HeapHeader,
    /// Both are integers, fixnum or bignum. The denominator is greater
    /// than one and shares no factor with the numerator, so every ratio is
    /// in lowest terms and no ratio ever holds a whole number.
    numerator: Value,
    denominator: Value,
};

/// Stub vector — flat `Value` array. Specialized element types
/// (`(simple-array (unsigned-byte 8) ...)`, etc.) come later; the reader only needs the
/// general T-vector path for `#(...)` literals.
/// What an array's elements are constrained to. Storage is a `Value` slot
/// per element whatever the type; the tag restricts what may be written
/// and is what `array-element-type` reports.
pub const ElementType = enum(u8) { t = 0, character = 1, bit = 2, unsigned_byte_8 = 3 };

/// Array of any rank, including vectors. Dimensions and elements are held
/// indirectly so `adjust-array` can resize either without moving the
/// object. A displaced array has no storage of its own and indexes into
/// its target, which may itself be displaced.
pub const HeapArray = extern struct {
    header: HeapHeader,
    rank: u32,
    element_type: ElementType,
    adjustable: bool,
    has_fill_pointer: bool,
    _pad: u8 = 0,
    /// Active length of a vector with a fill pointer; unread otherwise.
    fill_pointer: u64,
    displaced_to: Value,
    displaced_offset: u64,
    dims: [*]u64,
    storage: [*]Value,
    storage_len: u64,

    pub fn dimensions(self: *const HeapArray) []u64 {
        return self.dims[0..self.rank];
    }

    pub fn totalSize(self: *const HeapArray) usize {
        var total: usize = 1;
        for (self.dimensions()) |d| total *= @intCast(d);
        return total;
    }

    /// Elements a sequence operation sees: up to the fill pointer when
    /// there is one, the whole array otherwise.
    pub fn activeLen(self: *const HeapArray) usize {
        if (self.has_fill_pointer) return @intCast(self.fill_pointer);
        return self.totalSize();
    }
};

/// What a stream is attached to.
pub const StreamKind = enum(u8) { file, string, console, pretty };

/// Which operations a stream allows.
pub const StreamDirection = enum(u8) { input, output, io, probe };

/// What a stream's elements are.
pub const StreamElement = enum(u8) { character, unsigned_byte_8, signed_byte_16 };

/// How characters are encoded in a file stream's bytes.
pub const ExternalFormat = enum(u8) { utf8, latin1 };

/// Stream. A file's contents are read in whole on open and written back
/// on close, so a stream holds its bytes rather than a live cursor into
/// the operating system.
pub const HeapStream = struct {
    header: HeapHeader,
    kind: StreamKind,
    direction: StreamDirection,
    element: StreamElement,
    external_format: ExternalFormat,
    is_open: bool,
    /// Where a file stream writes back to, and what `pathname` reports.
    path: Value,
    /// Bytes still to be read, and how far reading has got.
    input: []const u8,
    position: usize,
    /// Bytes written so far, and where the next write lands.
    output: std.ArrayListUnmanaged(u8),
    write_position: usize,
    /// A character handed back by `unread-char`.
    pending: ?u21,
    /// Set when the file this stream renamed should be removed on close.
    delete_on_close: Value,
    /// Recorded layout tokens, for a pretty stream. The text they refer
    /// to lives in `output`, so a token holds an offset and a length
    /// rather than a slice that reallocation could invalidate.
    tokens: std.ArrayListUnmanaged(PrettyToken),
    /// The stream a pretty stream writes to once it has laid itself out.
    target: Value,
    /// How many logical blocks are open.
    block_depth: u32,
    /// Labels for `*print-circle*`, when it is on.
    circle: ?*circle.State,
};

/// A layout token as a stream records it. Text is a span of `output`.
pub const PrettyToken = union(enum) {
    text: struct { start: u32, len: u32 },
    newline: pretty.NewlineKind,
    indent: struct { kind: pretty.IndentKind, amount: i64 },
    block_start: struct { prefix: Span, per_line: Span, suffix: Span },
    block_end: Span,
};

pub const Span = struct { start: u32, len: u32 };

/// The generator behind `random`. The four words are a Xoshiro256++
/// state, held inline so `make-random-state` can copy one.
pub const HeapRandomState = extern struct {
    header: HeapHeader,
    state: [4]u64,
};

/// Complex number. Both parts are reals of the same kind: either both
/// rational, or both floats of the same format. A rational complex whose
/// imaginary part is zero is collapsed to the real, so one never exists.
pub const HeapComplex = extern struct {
    header: HeapHeader,
    realpart: Value,
    imagpart: Value,
};

/// Arbitrary-precision integer: `std.math.big.int.Const` split into
/// fields. The limbs are allocated separately so a collector can trace the
/// block as a leaf.
pub const HeapBignum = extern struct {
    header: HeapHeader,
    limbs: [*]const std.math.big.Limb,
    len: u64,
    positive: bool,
    _pad: [7]u8 = .{0} ** 7,

    pub fn toConst(self: *const HeapBignum) std.math.big.int.Const {
        return .{ .limbs = self.limbs[0..self.len], .positive = self.positive };
    }
};

/// Physical pathname, held as its six components. A namestring is
/// rendered from them on demand rather than stored, so a pathname built
/// by `make-pathname` and one parsed from text are the same thing.
/// The six components, as the constructors pass them around.
pub const Pathname = struct {
    host: Value,
    device: Value,
    directory: Value,
    name: Value,
    type_: Value,
    version: Value,
    is_logical: bool = false,
};

pub const HeapPathname = extern struct {
    header: HeapHeader,
    host: Value,
    device: Value,
    /// `(:absolute ...)` or `(:relative ...)`, or NIL.
    directory: Value,
    name: Value,
    type_: Value,
    version: Value,
    /// True when the host names a logical host, which changes both the
    /// namestring syntax and what `translate-logical-pathname` does.
    is_logical: bool,
    _pad: [7]u8 = .{0} ** 7,
};

/// `defstruct` instance: the structure name symbol plus a flat slot array.
/// Slot names and their order live on the name symbol's plist, so an
/// instance carries only its values.
pub const HeapStructure = extern struct {
    header: HeapHeader,
    name: Value,
    len: u64,
    pub fn data(self: *HeapStructure) [*]Value {
        const base: [*]u8 = @ptrCast(self);
        return @ptrCast(@alignCast(base + @sizeOf(HeapStructure)));
    }
    pub fn slice(self: *HeapStructure) []Value {
        return self.data()[0..self.len];
    }
    pub fn constSlice(self: *const HeapStructure) []const Value {
        const base: [*]const u8 = @ptrCast(self);
        const ptr: [*]const Value = @ptrCast(@alignCast(base + @sizeOf(HeapStructure)));
        return ptr[0..self.len];
    }
};

/// Which equality predicate a hash table compares keys with.
pub const HashTest = enum(u8) { eq, eql, equal, equalp };

/// One key/value pair. A removed pair is left in place and skipped, so the
/// indices held in the bucket lists stay valid.
pub const HashEntry = struct {
    key: Value,
    value: Value,
    live: bool,
};

/// Chained hash table. Entries keep insertion order in one list, and the
/// bucket map holds the indices that share a hash code. Lookups compare
/// with the table's test rather than by raw bits, so `equal` and `equalp`
/// tables work on structure.
pub const HeapHashTable = struct {
    header: HeapHeader,
    hash_test: HashTest,
    /// The `:size` the table was made with, reported by `hash-table-size`.
    requested_size: u64,
    rehash_size: Value,
    rehash_threshold: Value,
    live_count: u64,
    entries: std.ArrayListUnmanaged(HashEntry),
    buckets: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)),
};

/// All allocation flows through this. For now a bump arena is supplied from
/// outside; a real GC heap will replace the underlying allocator later.
pub const Heap = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    pub fn allocCons(self: *Heap, car_v: Value, cdr_v: Value) !Value {
        const cell = try self.allocator.create(Cons);
        cell.* = .{ .car = car_v, .cdr = cdr_v };
        return Value.fromConsAddr(@intFromPtr(cell));
    }

    /// A string decoded from UTF-8. This is the constructor for text that
    /// arrives as bytes: source literals, file contents, symbol names.
    /// Invalid bytes are taken as Latin-1 so no input is rejected here.
    pub fn allocString(self: *Heap, bytes: []const u8) !Value {
        const v = try self.allocStringUninitialized(utf8Length(bytes));
        var out = asString(v).slice();
        var i: usize = 0;
        var o: usize = 0;
        while (i < bytes.len) : (o += 1) {
            const width = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            if (i + width > bytes.len) {
                out[o] = bytes[i];
                i += 1;
                continue;
            }
            out[o] = std.unicode.utf8Decode(bytes[i .. i + width]) catch bytes[i];
            i += if (std.unicode.utf8Decode(bytes[i .. i + width])) |_| width else |_| 1;
        }
        return v;
    }

    /// How many characters `bytes` decodes to under the same rule.
    fn utf8Length(bytes: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (count += 1) {
            const width = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            if (i + width > bytes.len) {
                i += 1;
                continue;
            }
            i += if (std.unicode.utf8Decode(bytes[i .. i + width])) |_| width else |_| 1;
        }
        return count;
    }

    /// A string of `len` characters whose contents the caller fills in.
    pub fn allocStringUninitialized(self: *Heap, len: usize) !Value {
        return self.allocStringWithCapacity(len, len);
    }

    /// A string whose storage holds `capacity` characters, of which the
    /// first `len` are live. Room past `len` is what `vector-push-extend`
    /// fills in.
    pub fn allocStringWithCapacity(self: *Heap, len: usize, capacity: usize) !Value {
        const obj = try self.allocator.create(HeapString);
        const codes = try self.allocator.alloc(u32, capacity);
        obj.* = .{
            .header = .{ .type_tag = .string, .size = @sizeOf(HeapString) },
            .len = len,
            .capacity = capacity,
            .codes = codes.ptr,
            .has_fill_pointer = false,
            .adjustable = false,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    /// A string holding exactly these codepoints.
    pub fn allocStringFromChars(self: *Heap, codes: []const u32) !Value {
        const v = try self.allocStringUninitialized(codes.len);
        if (codes.len != 0) @memcpy(asString(v).slice(), codes);
        return v;
    }

    /// Replace a string's storage, keeping the object identity every other
    /// value already points at.
    pub fn resizeString(self: *Heap, v: Value, capacity: usize) !void {
        const s = asString(v);
        const codes = try self.allocator.alloc(u32, capacity);
        const keep = @min(s.capacity, capacity);
        @memcpy(codes[0..keep], s.codes[0..keep]);
        s.codes = codes.ptr;
        s.capacity = capacity;
    }

    pub fn allocSingleFloat(self: *Heap, x: f32) !Value {
        const obj = try self.allocator.create(HeapSingleFloat);
        obj.* = .{
            .header = .{ .type_tag = .single_float, .size = @sizeOf(HeapSingleFloat) },
            .value = x,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocDoubleFloat(self: *Heap, x: f64) !Value {
        const obj = try self.allocator.create(HeapDoubleFloat);
        obj.* = .{
            .header = .{ .type_tag = .double_float, .size = @sizeOf(HeapDoubleFloat) },
            .value = x,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocRatio(self: *Heap, num: Value, den: Value) !Value {
        const obj = try self.allocator.create(HeapRatio);
        obj.* = .{
            .header = .{ .type_tag = .ratio, .size = @sizeOf(HeapRatio) },
            .numerator = num,
            .denominator = den,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocHashTable(self: *Heap) !Value {
        return self.allocHashTableWith(.eql, 16, value.NIL, value.NIL);
    }

    pub fn allocHashTableWith(
        self: *Heap,
        hash_test: HashTest,
        requested_size: u64,
        rehash_size: Value,
        rehash_threshold: Value,
    ) !Value {
        const obj = try self.allocator.create(HeapHashTable);
        obj.* = .{
            .header = .{ .type_tag = .hash_table, .size = @sizeOf(HeapHashTable) },
            .hash_test = hash_test,
            .requested_size = requested_size,
            .rehash_size = rehash_size,
            .rehash_threshold = rehash_threshold,
            .live_count = 0,
            .entries = .empty,
            .buckets = .{},
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    /// A simple vector: rank one, element type T, no fill pointer, not
    /// adjustable, not displaced.
    pub fn allocVector(self: *Heap, elements: []const Value) !Value {
        const v = try self.allocArray(&.{elements.len}, .t);
        @memcpy(asArray(v).storage[0..elements.len], elements);
        return v;
    }

    /// An array of the given dimensions with its own storage, every slot
    /// left as NIL.
    pub fn allocArray(self: *Heap, sizes: []const usize, element_type: ElementType) !Value {
        const obj = try self.allocator.create(HeapArray);
        const dims = try self.allocator.alloc(u64, sizes.len);
        var total: usize = 1;
        for (sizes, dims) |size, *d| {
            d.* = size;
            total *= size;
        }
        const storage = try self.allocator.alloc(Value, total);
        @memset(storage, value.NIL);
        obj.* = .{
            .header = .{ .type_tag = .vector, .size = @sizeOf(HeapArray) },
            .rank = @intCast(sizes.len),
            .element_type = element_type,
            .adjustable = false,
            .has_fill_pointer = false,
            .fill_pointer = 0,
            .displaced_to = value.NIL,
            .displaced_offset = 0,
            .dims = dims.ptr,
            .storage = storage.ptr,
            .storage_len = total,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    /// Give an array new dimensions, preserving the elements that still
    /// fit in row-major order.
    pub fn resizeArray(self: *Heap, v: Value, sizes: []const usize) !void {
        const a = asArray(v);
        const dims = try self.allocator.alloc(u64, sizes.len);
        var total: usize = 1;
        for (sizes, dims) |size, *d| {
            d.* = size;
            total *= size;
        }
        const storage = try self.allocator.alloc(Value, total);
        @memset(storage, value.NIL);
        if (a.displaced_to.equalsRaw(value.NIL)) {
            const keep = @min(a.storage_len, total);
            @memcpy(storage[0..keep], a.storage[0..keep]);
        }
        a.rank = @intCast(sizes.len);
        a.dims = dims.ptr;
        a.storage = storage.ptr;
        a.storage_len = total;
        a.displaced_to = value.NIL;
        a.displaced_offset = 0;
    }

    /// Wrap a `Const` whose limbs the heap allocator already owns.
    pub fn allocBignum(self: *Heap, n: std.math.big.int.Const) !Value {
        const obj = try self.allocator.create(HeapBignum);
        obj.* = .{
            .header = .{ .type_tag = .bignum, .size = @sizeOf(HeapBignum) },
            .limbs = n.limbs.ptr,
            .len = n.limbs.len,
            .positive = n.positive,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocStream(self: *Heap, stream: HeapStream) !Value {
        const obj = try self.allocator.create(HeapStream);
        obj.* = stream;
        obj.header = .{ .type_tag = .stream, .size = @sizeOf(HeapStream) };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocRandomState(self: *Heap, state: [4]u64) !Value {
        const obj = try self.allocator.create(HeapRandomState);
        obj.* = .{
            .header = .{ .type_tag = .random_state, .size = @sizeOf(HeapRandomState) },
            .state = state,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocComplex(self: *Heap, realpart: Value, imagpart: Value) !Value {
        const obj = try self.allocator.create(HeapComplex);
        obj.* = .{
            .header = .{ .type_tag = .complex, .size = @sizeOf(HeapComplex) },
            .realpart = realpart,
            .imagpart = imagpart,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocPathname(self: *Heap, components: Pathname) !Value {
        const obj = try self.allocator.create(HeapPathname);
        obj.* = .{
            .header = .{ .type_tag = .pathname, .size = @sizeOf(HeapPathname) },
            .host = components.host,
            .device = components.device,
            .directory = components.directory,
            .name = components.name,
            .type_ = components.type_,
            .version = components.version,
            .is_logical = components.is_logical,
        };
        return Value.fromHeapAddr(@intFromPtr(obj));
    }

    pub fn allocStructure(self: *Heap, name: Value, slots: []const Value) !Value {
        const total = @sizeOf(HeapStructure) + slots.len * @sizeOf(Value);
        const buf = try self.allocator.alignedAlloc(u8, .of(HeapStructure), total);
        const obj: *HeapStructure = @ptrCast(buf.ptr);
        obj.* = .{
            .header = .{ .type_tag = .structure, .size = @intCast(total) },
            .name = name,
            .len = slots.len,
        };
        if (slots.len != 0) @memcpy(obj.slice(), slots);
        return Value.fromHeapAddr(@intFromPtr(obj));
    }
};

/// Inspect the type tag of a heap-allocated value.
pub fn heapType(v: Value) HeapType {
    const obj: *const HeapObject = @ptrFromInt(v.toHeapAddr());
    return obj.header.type_tag;
}

pub fn asString(v: Value) *HeapString {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asSingleFloat(v: Value) *HeapSingleFloat {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asDoubleFloat(v: Value) *HeapDoubleFloat {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asRatio(v: Value) *HeapRatio {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asArray(v: Value) *HeapArray {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isArray(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .vector;
}

/// The elements a sequence operation sees: the array's storage clipped to
/// its fill pointer when it has one.
pub fn arrayActive(v: Value) []Value {
    return arrayElements(v)[0..asArray(v).activeLen()];
}

/// The storage slots an array's elements live in, following any chain of
/// displacement to the array that owns them.
pub fn arrayElements(v: Value) []Value {
    const a = asArray(v);
    const total = a.totalSize();
    var base = a;
    var offset: usize = 0;
    while (!base.displaced_to.equalsRaw(value.NIL)) {
        offset += @intCast(base.displaced_offset);
        base = asArray(base.displaced_to);
    }
    return base.storage[offset .. offset + total];
}

pub fn asBignum(v: Value) *HeapBignum {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn asStream(v: Value) *HeapStream {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isStream(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .stream;
}

pub fn asRandomState(v: Value) *HeapRandomState {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isRandomState(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .random_state;
}

pub fn asComplex(v: Value) *HeapComplex {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isComplex(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .complex;
}

pub fn isSingleFloat(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .single_float;
}

pub fn isDoubleFloat(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .double_float;
}

pub fn isRatio(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .ratio;
}

pub fn isBignum(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .bignum;
}

pub fn asPathname(v: Value) *HeapPathname {
    return @ptrFromInt(v.toHeapAddr());
}

/// A string's characters encoded as UTF-8, for the boundaries that deal
/// in bytes: filesystem paths, package names, symbol names.
pub fn stringUtf8Alloc(allocator: std.mem.Allocator, v: Value) ![]u8 {
    const codes = asString(v).constSlice();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (codes) |code| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(code), &buf) catch {
            try out.append(allocator, '?');
            continue;
        };
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn isString(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .string;
}

pub fn isPathname(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .pathname;
}

pub fn asStructure(v: Value) *HeapStructure {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isStructure(v: Value) bool {
    return v.tag() == .heap and heapType(v) == .structure;
}

pub fn asHashTable(v: Value) *HeapHashTable {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn car(v: Value) Value {
    const cell: *const Cons = @ptrFromInt(v.toConsAddr());
    return cell.car;
}

pub fn cdr(v: Value) Value {
    const cell: *const Cons = @ptrFromInt(v.toConsAddr());
    return cell.cdr;
}

pub fn setCar(v: Value, new_car: Value) void {
    const cell: *Cons = @ptrFromInt(v.toConsAddr());
    cell.car = new_car;
}

pub fn setCdr(v: Value, new_cdr: Value) void {
    const cell: *Cons = @ptrFromInt(v.toConsAddr());
    cell.cdr = new_cdr;
}
