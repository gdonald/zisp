//! Binary fasls: what `compile-file` compiled, written so `load` can
//! rebuild it without reading source. `docs/fasl-format.md` describes
//! the layout.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const bytecode = @import("bytecode.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;
const Code = bytecode.Code;

pub const MAGIC = "ZISPFASL";
pub const MAJOR: u16 = 1;
pub const MINOR: u16 = 0;
const HEADER_SIZE = 32;
const NONE: u32 = 0xFFFFFFFF;

const SectionKind = enum(u32) { code = 1, objects = 2, top_level = 3, _ };

const Tag = enum(u8) {
    fixnum = 1,
    bignum = 2,
    ratio = 3,
    single_float = 4,
    double_float = 5,
    complex = 6,
    character = 7,
    string = 8,
    symbol = 9,
    cons = 10,
    vector = 11,
    compiled_function = 12,
    pathname = 13,
    bit_vector = 14,
    byte_vector = 15,
    _,
};

/// A hash of the opcode names in order. Adding, removing or reordering
/// an instruction changes it, and a fasl written under another one is
/// refused.
pub const instruction_set: u32 = blk: {
    @setEvalBranchQuota(100_000);
    var hash: u32 = 2166136261;
    for (@typeInfo(bytecode.Op).@"enum".field_names) |name| {
        for (name) |c| hash = (hash ^ c) *% 16777619;
        hash = (hash ^ ',') *% 16777619;
    }
    break :blk hash;
};

pub fn isBinary(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, MAGIC);
}

/// Why a fasl could not be written in this format: some literal it
/// holds has no tag here.
pub const WriteError = Error || error{Unencodable};

const Entry = union(enum) {
    object: Value,
    /// A string the file needs that is not an object of the program's:
    /// a symbol's name or its package's.
    name: []const u8,
};

pub const Writer = struct {
    ev: *Evaluator,
    allocator: std.mem.Allocator,
    endian: std.builtin.Endian,
    codes: std.ArrayListUnmanaged(*const Code) = .empty,
    code_numbers: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    indices: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    names: std.StringHashMapUnmanaged(u32) = .empty,
    /// Conses and vectors whose elements still need entries.
    pending: std.ArrayListUnmanaged(Value) = .empty,
    out: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Writer) void {
        self.codes.deinit(self.allocator);
        self.code_numbers.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.out.deinit(self.allocator);
    }

    fn codeNumber(self: *Writer, code: *const Code) WriteError!u32 {
        const slot = try self.code_numbers.getOrPut(self.allocator, @intFromPtr(code));
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(self.codes.items.len);
            try self.codes.append(self.allocator, code);
        }
        return slot.value_ptr.*;
    }

    fn nameIndex(self: *Writer, text: []const u8) WriteError!u32 {
        const slot = try self.names.getOrPut(self.allocator, text);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(self.entries.items.len);
            try self.entries.append(self.allocator, .{ .name = text });
        }
        return slot.value_ptr.*;
    }

    fn add(self: *Writer, v: Value) WriteError!u32 {
        const index: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{ .object = v });
        try self.indices.put(self.allocator, v.raw, index);
        return index;
    }

    /// The index `v` has in the objects section, giving it one, and the
    /// objects it is made of, when it has none yet.
    fn objectIndex(self: *Writer, v: Value) WriteError!u32 {
        if (self.indices.get(v.raw)) |index| return index;
        if (v.isFixnum() or v.isChar()) return self.add(v);
        if (v.isSymbol()) {
            const sym = symbol_mod.symbol(v);
            if (sym.home) |pkg| _ = try self.nameIndex(pkg.name);
            _ = try self.nameIndex(sym.name);
            return self.add(v);
        }
        if (v.isCons()) {
            const index = try self.add(v);
            try self.pending.append(self.allocator, v);
            return index;
        }
        if (v.tag() != .heap) return error.Unencodable;
        switch (heap.heapType(v)) {
            .bignum, .single_float, .double_float => return self.add(v),
            .ratio => {
                _ = try self.objectIndex(heap.asRatio(v).numerator);
                _ = try self.objectIndex(heap.asRatio(v).denominator);
                return self.add(v);
            },
            .complex => {
                _ = try self.objectIndex(heap.asComplex(v).realpart);
                _ = try self.objectIndex(heap.asComplex(v).imagpart);
                return self.add(v);
            },
            .string => {
                const text = heap.asString(v);
                if (text.isDisplaced() or text.has_fill_pointer or text.adjustable) return error.Unencodable;
                return self.add(v);
            },
            .vector => {
                const array = heap.asArray(v);
                const displaced = !(array.displaced_to.raw == 0 or array.displaced_to.equalsRaw(value.NIL));
                if (array.rank != 1 or array.adjustable or array.has_fill_pointer or displaced) return error.Unencodable;
                if (array.element_type == .character) return error.Unencodable;
                const index = try self.add(v);
                if (array.element_type == .t) try self.pending.append(self.allocator, v);
                return index;
            },
            .function => {
                if (!function.isCompiled(v)) return error.Unencodable;
                const f = function.asFunction(v);
                if (f.payload.compiled.env_len != 0) return error.Unencodable;
                _ = try self.codeNumber(f.payload.compiled.code);
                return self.add(v);
            },
            else => return error.Unencodable,
        }
    }

    fn drainPending(self: *Writer) WriteError!void {
        while (self.pending.pop()) |v| {
            if (v.isCons()) {
                _ = try self.objectIndex(heap.car(v));
                _ = try self.objectIndex(heap.cdr(v));
            } else {
                const array = heap.asArray(v);
                for (array.storage[0..array.totalSize()]) |element| _ = try self.objectIndex(element);
            }
        }
    }

    fn int(self: *Writer, comptime T: type, n: T) WriteError!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, n, self.endian);
        try self.out.appendSlice(self.allocator, &bytes);
    }

    fn pad(self: *Writer) WriteError!void {
        while (self.out.items.len % 8 != 0) try self.out.append(self.allocator, 0);
    }

    /// Start a section, returning where its length goes.
    fn section(self: *Writer, kind: SectionKind) WriteError!usize {
        try self.int(u32, @backingInt(kind));
        try self.int(u32, 0);
        const at = self.out.items.len;
        try self.int(u64, 0);
        return at;
    }

    fn endSection(self: *Writer, length_at: usize) WriteError!void {
        const length: u64 = self.out.items.len - length_at - 8;
        std.mem.writeInt(u64, self.out.items[length_at..][0..8], length, self.endian);
        try self.pad();
    }

    fn indexOf(self: *Writer, v: Value) u32 {
        return self.indices.get(v.raw).?;
    }

    fn writeCode(self: *Writer, code: *const Code) WriteError!void {
        const at = try self.section(.code);
        try self.int(u32, if (code.name) |n| self.names.get(n).? else NONE);
        try self.int(u32, code.required);
        try self.int(u32, code.optional);
        try self.int(u32, @as(u32, @intFromBool(code.takes_extra)) | (@as(u32, @intFromBool(code.check_args)) << 1));
        try self.int(u32, code.locals);
        try self.int(u32, code.max_stack);
        try self.int(u32, @intCast(code.caches.len));
        try self.int(u32, @intCast(code.words.len));
        try self.int(u32, @intCast(code.constants.len));
        try self.int(u32, @intCast(code.jump_tables.len));
        try self.int(u32, @intCast(code.slot_names.len));
        try self.int(u32, @intCast(code.positions.len));
        try self.int(u32, if (code.source_file) |file| self.names.get(file).? else NONE);
        try self.int(u32, 0);
        for (code.words) |w| try self.int(u32, w);
        for (code.constants) |c| try self.int(u32, self.indexOf(c));
        for (code.jump_tables) |table| {
            try self.int(u32, @intCast(table.len));
            for (table) |offset| try self.int(u32, offset);
        }
        for (code.slot_names) |n| try self.int(u32, if (n.raw == 0) NONE else self.indexOf(n));
        for (code.positions) |pos| {
            try self.int(u32, pos.pc);
            try self.int(u32, pos.line);
            try self.int(u32, pos.column);
        }
        try self.endSection(at);
    }

    fn writeObject(self: *Writer, entry: Entry) WriteError!void {
        switch (entry) {
            .name => |text| try self.writeText(text),
            .object => |v| {
                if (v.isFixnum()) {
                    try self.tag(.fixnum);
                    try self.int(i64, v.toFixnum());
                } else if (v.isChar()) {
                    try self.tag(.character);
                    try self.int(u32, v.toChar());
                } else if (v.isSymbol()) {
                    const sym = symbol_mod.symbol(v);
                    try self.tag(.symbol);
                    try self.int(u32, if (sym.home) |pkg| self.names.get(pkg.name).? else NONE);
                    try self.int(u32, self.names.get(sym.name).?);
                } else if (v.isCons()) {
                    try self.tag(.cons);
                    try self.int(u32, self.indexOf(heap.car(v)));
                    try self.int(u32, self.indexOf(heap.cdr(v)));
                } else switch (heap.heapType(v)) {
                    .bignum => {
                        const big = heap.asBignum(v);
                        try self.tag(.bignum);
                        try self.out.append(self.allocator, @intFromBool(!big.positive));
                        try self.int(u32, @intCast(big.len));
                        for (big.limbs[0..big.len]) |limb| try self.int(u64, limb);
                    },
                    .single_float => {
                        try self.tag(.single_float);
                        try self.int(u32, @bitCast(heap.asSingleFloat(v).value));
                    },
                    .double_float => {
                        try self.tag(.double_float);
                        try self.int(u64, @bitCast(heap.asDoubleFloat(v).value));
                    },
                    .ratio => {
                        try self.tag(.ratio);
                        try self.int(u32, self.indexOf(heap.asRatio(v).numerator));
                        try self.int(u32, self.indexOf(heap.asRatio(v).denominator));
                    },
                    .complex => {
                        try self.tag(.complex);
                        try self.int(u32, self.indexOf(heap.asComplex(v).realpart));
                        try self.int(u32, self.indexOf(heap.asComplex(v).imagpart));
                    },
                    .string => {
                        const codes = heap.asString(v).constSlice();
                        try self.tag(.string);
                        try self.int(u32, @intCast(codes.len));
                        for (codes) |c| try self.int(u32, c);
                    },
                    .vector => {
                        const array = heap.asArray(v);
                        const elements = array.storage[0..array.totalSize()];
                        switch (array.element_type) {
                            .t => {
                                try self.tag(.vector);
                                try self.int(u32, @intCast(elements.len));
                                for (elements) |element| try self.int(u32, self.indexOf(element));
                            },
                            .bit, .unsigned_byte_8 => {
                                try self.tag(if (array.element_type == .bit) .bit_vector else .byte_vector);
                                try self.int(u32, @intCast(elements.len));
                                for (elements) |element| try self.out.append(self.allocator, @intCast(element.toFixnum()));
                            },
                            .character => unreachable,
                        }
                    },
                    .function => {
                        try self.tag(.compiled_function);
                        try self.int(u32, self.code_numbers.get(@intFromPtr(function.asFunction(v).payload.compiled.code)).?);
                    },
                    else => unreachable,
                }
            },
        }
    }

    fn writeText(self: *Writer, text: []const u8) WriteError!void {
        try self.tag(.string);
        const view = std.unicode.Utf8View.init(text) catch return error.Unencodable;
        var count: u32 = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |_| count += 1;
        try self.int(u32, count);
        it = view.iterator();
        while (it.nextCodepoint()) |c| try self.int(u32, c);
    }

    fn tag(self: *Writer, t: Tag) WriteError!void {
        try self.out.append(self.allocator, @backingInt(t));
    }

    /// The fasl for `top_level`, the code of each top-level form in
    /// order.
    pub fn build(self: *Writer, top_level: []const *const Code) WriteError![]const u8 {
        for (top_level) |code| _ = try self.codeNumber(code);
        var next: usize = 0;
        while (next < self.codes.items.len) : (next += 1) {
            const code = self.codes.items[next];
            if (code.name) |n| _ = try self.nameIndex(n);
            if (code.source_file) |file| _ = try self.nameIndex(file);
            for (code.constants) |c| _ = try self.objectIndex(c);
            for (code.slot_names) |n| {
                if (n.raw != 0) _ = try self.objectIndex(n);
            }
            try self.drainPending();
        }

        try self.out.appendSlice(self.allocator, MAGIC);
        try self.out.append(self.allocator, if (self.endian == .little) 1 else 2);
        try self.out.appendSlice(self.allocator, &.{ 0, 0, 0 });
        try self.int(u16, MAJOR);
        try self.int(u16, MINOR);
        try self.int(u32, instruction_set);
        try self.int(u32, @intCast(self.codes.items.len + 2));
        try self.int(u64, 0);

        for (self.codes.items) |code| try self.writeCode(code);
        const objects_at = try self.section(.objects);
        try self.int(u32, @intCast(self.entries.items.len));
        for (self.entries.items) |entry| try self.writeObject(entry);
        try self.endSection(objects_at);
        const top_at = try self.section(.top_level);
        try self.int(u32, @intCast(top_level.len));
        for (top_level) |code| try self.int(u32, self.code_numbers.get(@intFromPtr(code)).?);
        try self.endSection(top_at);

        std.mem.writeInt(u64, self.out.items[24..32], self.out.items.len, self.endian);
        return self.out.items;
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    endian: std.builtin.Endian,

    fn int(self: *Reader, comptime T: type) Error!T {
        if (self.at + @sizeOf(T) > self.bytes.len) return Error.FileError;
        const n = std.mem.readInt(T, self.bytes[self.at..][0..@sizeOf(T)], self.endian);
        self.at += @sizeOf(T);
        return n;
    }

    fn byte(self: *Reader) Error!u8 {
        if (self.at >= self.bytes.len) return Error.FileError;
        self.at += 1;
        return self.bytes[self.at - 1];
    }
};

/// A code object read from a fasl, with the indices its constants and
/// slot names are to be filled from.
const PendingCode = struct {
    code: *Code,
    constants: []u32,
    slot_names: []u32,
    slot_values: []Value,
    name: u32,
    file: u32,
};

/// Load the binary fasl `bytes`: rebuild its code and objects and run
/// its top-level forms in order.
pub fn load(ev: *Evaluator, bytes: []const u8) Error!void {
    if (bytes.len < HEADER_SIZE or !isBinary(bytes)) return Error.FileError;
    const endian: std.builtin.Endian = switch (bytes[8]) {
        1 => .little,
        2 => .big,
        else => return Error.FileError,
    };
    var r: Reader = .{ .bytes = bytes, .at = 12, .endian = endian };
    const major = try r.int(u16);
    _ = try r.int(u16);
    const iset = try r.int(u32);
    if (major != MAJOR or iset != instruction_set) return Error.FaslVersion;
    const sections = try r.int(u32);
    _ = try r.int(u64);

    var arena = std.heap.ArenaAllocator.init(ev.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const keep = ev.heap.allocator;

    var codes: std.ArrayListUnmanaged(PendingCode) = .empty;
    var objects_at: ?usize = null;
    var top_level: []u32 = &.{};

    for (0..sections) |_| {
        const kind: SectionKind = @fromBackingInt(@intCast(try r.int(u32)));
        _ = try r.int(u32);
        const length = try r.int(u64);
        const start = r.at;
        if (start + length > bytes.len) return Error.FileError;
        switch (kind) {
            .code => try codes.append(scratch, try readCode(&r, keep, scratch)),
            .objects => objects_at = start,
            .top_level => {
                const n = try r.int(u32);
                top_level = try scratch.alloc(u32, n);
                for (top_level) |*number| number.* = try r.int(u32);
            },
            _ => {},
        }
        r.at = std.mem.alignForward(usize, start + length, 8);
    }

    var held = ev.heap.protect();
    defer held.close();
    if (objects_at) |at| {
        r.at = at;
        try readObjects(ev, &r, codes.items, &held, scratch);
    }
    const objects = held.items();

    for (codes.items) |pending| {
        for (pending.constants, 0..) |i, k| pending.code.constants[k] = try objectAt(objects, i);
        for (pending.slot_names, 0..) |i, k| {
            pending.slot_values[k] = if (i == NONE) .{ .raw = 0 } else try objectAt(objects, i);
        }
        if (pending.name != NONE) pending.code.name = try stringAt(objects, pending.name, keep);
        if (pending.file != NONE) pending.code.source_file = try stringAt(objects, pending.file, keep);
        try ev.registerCode(pending.code);
    }

    for (top_level) |number| {
        if (number >= codes.items.len) return Error.FileError;
        const fn_v = try function.allocCompiled(ev.heap, codes.items[number].code, &.{});
        try held.push(fn_v);
        _ = try ev.callFunction(fn_v, &.{});
    }
}

fn stringAt(objects: []const Value, i: u32, keep: std.mem.Allocator) Error![]const u8 {
    const v = try objectAt(objects, i);
    if (!heap.isString(v)) return Error.FileError;
    return heap.stringUtf8Alloc(keep, v);
}

fn objectAt(objects: []const Value, i: u32) Error!Value {
    if (i >= objects.len) return Error.FileError;
    return objects[i];
}

fn readCode(r: *Reader, keep: std.mem.Allocator, scratch: std.mem.Allocator) Error!PendingCode {
    const name = try r.int(u32);
    const required = try r.int(u32);
    const optional = try r.int(u32);
    const flags = try r.int(u32);
    const locals = try r.int(u32);
    const max_stack = try r.int(u32);
    const sites = try r.int(u32);
    const word_count = try r.int(u32);
    const constant_count = try r.int(u32);
    const table_count = try r.int(u32);
    const slot_count = try r.int(u32);
    const position_count = try r.int(u32);
    const file = try r.int(u32);
    _ = try r.int(u32);
    const words = try keep.alloc(u32, word_count);
    for (words) |*w| w.* = try r.int(u32);
    const constant_indices = try scratch.alloc(u32, constant_count);
    for (constant_indices) |*i| i.* = try r.int(u32);
    const tables = try keep.alloc([]const u32, table_count);
    for (tables) |*table| {
        const n = try r.int(u32);
        const offsets = try keep.alloc(u32, n);
        for (offsets) |*offset| offset.* = try r.int(u32);
        table.* = offsets;
    }
    const slot_indices = try scratch.alloc(u32, slot_count);
    for (slot_indices) |*i| i.* = try r.int(u32);
    const positions = try keep.alloc(bytecode.Position, position_count);
    for (positions) |*pos| pos.* = .{ .pc = try r.int(u32), .line = try r.int(u32), .column = try r.int(u32) };

    const constants = try keep.alloc(Value, constant_count);
    @memset(constants, value.NIL);
    const slot_names = try keep.alloc(Value, slot_count);
    @memset(slot_names, .{ .raw = 0 });
    const caches = try keep.alloc(bytecode.CallCache, sites);
    @memset(caches, .{});
    const code = try keep.create(Code);
    code.* = .{
        .words = words,
        .constants = constants,
        .jump_tables = tables,
        .name = null,
        .required = required,
        .optional = optional,
        .takes_extra = flags & 1 != 0,
        .check_args = flags & 2 != 0,
        .positions = positions,
        .locals = locals,
        .max_stack = max_stack,
        .slot_names = slot_names,
        .caches = caches,
    };
    return .{ .code = code, .constants = constant_indices, .slot_names = slot_indices, .slot_values = slot_names, .name = name, .file = file };
}

/// Make every object, then fill in what each cons and vector refers to,
/// which may be an object made after it.
fn readObjects(ev: *Evaluator, r: *Reader, codes: []const PendingCode, held: anytype, scratch: std.mem.Allocator) Error!void {
    const count = try r.int(u32);
    const base = held.items().len;
    const Link = struct { object: u32, refs: []u32 };
    var links: std.ArrayListUnmanaged(Link) = .empty;
    for (0..count) |i| {
        const tag: Tag = @fromBackingInt(@intCast(try r.byte()));
        const made: Value = switch (tag) {
            .fixnum => blk: {
                const n = try r.int(i64);
                if (n < value.FIXNUM_MIN or n > value.FIXNUM_MAX) return Error.FileError;
                break :blk Value.fromFixnum(n);
            },
            .character => blk: {
                const c = try r.int(u32);
                if (c > 0x10FFFF) return Error.FileError;
                break :blk Value.fromChar(@intCast(c));
            },
            .bignum => blk: {
                const negative = try r.byte() == 1;
                const n = try r.int(u32);
                // The bignum takes the limbs over, so they come from
                // the allocator the heap frees them with.
                const limbs = try ev.heap.allocator.alloc(std.math.big.Limb, n);
                for (limbs) |*limb| limb.* = @intCast(try r.int(u64));
                break :blk try ev.heap.allocBignum(.{ .limbs = limbs, .positive = !negative });
            },
            .single_float => try ev.heap.allocSingleFloat(@bitCast(try r.int(u32))),
            .double_float => try ev.heap.allocDoubleFloat(@bitCast(try r.int(u64))),
            .ratio, .complex => blk: {
                const a = try objectAt(held.items()[base..], try r.int(u32));
                const b = try objectAt(held.items()[base..], try r.int(u32));
                break :blk if (tag == .ratio) try ev.heap.allocRatio(a, b) else try ev.heap.allocComplex(a, b);
            },
            .string => blk: {
                const n = try r.int(u32);
                const chars = try scratch.alloc(u32, n);
                for (chars) |*c| c.* = try r.int(u32);
                break :blk try ev.heap.allocStringFromChars(chars);
            },
            .symbol => blk: {
                const package_index = try r.int(u32);
                const name = try objectAt(held.items()[base..], try r.int(u32));
                const text = try heap.stringUtf8Alloc(scratch, name);
                if (package_index == NONE) break :blk try ev.interner.makeUninterned(text);
                const package_name = try heap.stringUtf8Alloc(scratch, try objectAt(held.items()[base..], package_index));
                const pkg = ev.interner.registry.find(package_name) orelse return Error.NoSuchPackage;
                break :blk try ev.interner.internIn(pkg, text);
            },
            .cons => blk: {
                const refs = try scratch.alloc(u32, 2);
                refs[0] = try r.int(u32);
                refs[1] = try r.int(u32);
                try links.append(scratch, .{ .object = @intCast(i), .refs = refs });
                break :blk try ev.heap.allocCons(value.NIL, value.NIL);
            },
            .vector => blk: {
                const n = try r.int(u32);
                const refs = try scratch.alloc(u32, n);
                for (refs) |*ref| ref.* = try r.int(u32);
                try links.append(scratch, .{ .object = @intCast(i), .refs = refs });
                const nils = try scratch.alloc(Value, n);
                @memset(nils, value.NIL);
                break :blk try ev.heap.allocVector(nils);
            },
            .bit_vector, .byte_vector => blk: {
                const n = try r.int(u32);
                const v = try ev.heap.allocArray(&.{n}, if (tag == .bit_vector) .bit else .unsigned_byte_8);
                const array = heap.asArray(v);
                for (0..n) |k| array.storage[k] = Value.fromFixnum(try r.byte());
                break :blk v;
            },
            .compiled_function => blk: {
                const number = try r.int(u32);
                if (number >= codes.len) return Error.FileError;
                break :blk try function.allocCompiled(ev.heap, codes[number].code, &.{});
            },
            .pathname => return Error.FileError,
            _ => return Error.FileError,
        };
        try held.push(made);
    }
    const objects = held.items()[base..];
    for (links.items) |link| {
        const target = objects[link.object];
        if (target.isCons()) {
            heap.setCar(ev.heap, target, try objectAt(objects, link.refs[0]));
            heap.setCdr(ev.heap, target, try objectAt(objects, link.refs[1]));
        } else {
            for (link.refs, 0..) |ref, k| heap.setSlot(ev.heap, target, k, try objectAt(objects, ref));
        }
    }
}
