//! Saved images: everything a session holds, written to a file a later
//! session starts from. `docs/image-format.md` describes the layout.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const package_mod = @import("../runtime/package.zig");
const mark_mod = @import("../runtime/mark.zig");
const function = @import("../eval/function.zig");
const env_mod = @import("../eval/env.zig");
const eval_mod = @import("../eval/eval.zig");
const bytecode = @import("../compiler/bytecode.zig");
const fasl = @import("../compiler/fasl.zig");
const hash_tables = @import("hash_tables.zig");
const streams = @import("streams.zig");
const reader_mod = @import("../reader.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;
const Frame = env_mod.Frame;
const Code = bytecode.Code;

pub const MAGIC = "ZISPIMG\x00";
pub const MAJOR: u16 = 2;
pub const MINOR: u16 = 0;
const NONE: u32 = 0xFFFFFFFF;

const SectionKind = enum(u32) { natives = 1, code = 2, packages = 3, objects = 4, contents = 5, state = 6, _ };

const Tag = enum(u8) {
    bignum = 2,
    ratio = 3,
    double_float = 5,
    complex = 6,
    string = 8,
    symbol = 9,
    cons = 10,
    array = 11,
    hash_table = 12,
    native = 13,
    closure = 14,
    compiled = 15,
    funcallable = 16,
    frame = 17,
    structure = 18,
    package = 19,
    pathname = 20,
    stream = 21,
    random_state = 22,
    readtable = 23,
    weak_pointer = 24,
    _,
};

/// A reference to an object in the image: its index with the tag no
/// live value carries, so every other value can be written as itself.
const REF_TAG: u64 = 7;

fn refTo(index: u32) u64 {
    return (@as(u64, index) << 3) | REF_TAG;
}

pub fn register(ev: *Evaluator) !void {
    const save = try ev.interner.internExtension("SAVE-IMAGE");
    symbol_mod.symbol(save).function_cell = try ev.makeNative("SAVE-IMAGE", &saveImageFn);
    const walk = try ev.interner.internExtension("%WALK-HEAP");
    const walker = try ev.makeNative("%WALK-HEAP", &walkHeapFn);
    function.asFunction(walker).preserves_values = true;
    symbol_mod.symbol(walk).function_cell = walker;
    _ = try ev.defineNative("%IMAGE-ROUND-TRIP", &imageRoundTripFn);
}

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

// --- enumerating the heap ---

const Entry = union(enum) {
    object: Value,
    frame: *Frame,
};

/// What a walk reached, in the order it reached it.
const Walk = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    indices: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    frame_indices: std.AutoHashMapUnmanaged(usize, u32) = .empty,

    fn deinit(self: *Walk) void {
        self.entries.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.frame_indices.deinit(self.allocator);
    }

    fn object(context: *anyopaque, v: Value) std.mem.Allocator.Error!void {
        const self: *Walk = @ptrCast(@alignCast(context));
        try self.indices.put(self.allocator, v.raw, @intCast(self.entries.items.len));
        try self.entries.append(self.allocator, .{ .object = v });
    }

    fn frame(context: *anyopaque, f: *Frame) std.mem.Allocator.Error!void {
        const self: *Walk = @ptrCast(@alignCast(context));
        try self.frame_indices.put(self.allocator, @intFromPtr(f), @intCast(self.entries.items.len));
        try self.entries.append(self.allocator, .{ .frame = f });
    }
};

/// Walk everything reachable from `roots` with the collector's marker,
/// recording each object, symbol and frame the first time it is reached.
fn walkFrom(ev: *Evaluator, roots: []const Value, descend_symbols: bool, walk: *Walk) !void {
    var marker = mark_mod.Marker.init(ev.allocator, ev.heap);
    defer marker.deinit();
    marker.visitor = .{
        .context = walk,
        .object = &Walk.object,
        .frame = &Walk.frame,
        .descend_symbols = descend_symbols,
        .follow_code = true,
    };
    // The worklist is taken from its end, so the roots go in last first
    // and the walk starts from the first one.
    var i = roots.len;
    while (i > 0) {
        i -= 1;
        try marker.push(roots[i]);
    }
    defer ev.heap.objects.clearMarks();
    try marker.run();
}

/// `(ext:%walk-heap root)`: how many objects are reachable from `root`,
/// not counting what is reachable only through a symbol, and how many
/// symbols, as two values.
fn walkHeapFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var walk: Walk = .{ .allocator = ev.allocator };
    defer walk.deinit();
    try walkFrom(ev, args[0..1], false, &walk);
    var objects: i64 = 0;
    var symbols: i64 = 0;
    for (walk.entries.items) |entry| switch (entry) {
        .object => |v| if (v.isSymbol()) {
            symbols += 1;
        } else {
            objects += 1;
        },
        .frame => objects += 1,
    };
    return ev.setValues(&.{ Value.fromFixnum(objects), Value.fromFixnum(symbols) });
}

// --- writing ---

const Writer = struct {
    ev: *Evaluator,
    allocator: std.mem.Allocator,
    walk: Walk,
    out: std.ArrayListUnmanaged(u8) = .empty,
    codes: std.ArrayListUnmanaged(*const Code) = .empty,
    code_numbers: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    natives: std.ArrayListUnmanaged(u32) = .empty,
    native_numbers: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    packages: []const *package_mod.Package = &.{},
    /// Write symbols by name alone, leaving their cells out, for a graph
    /// whose walk stopped at symbols.
    symbols_by_name: bool = false,
    hosts: Value = .{ .raw = 0 },

    fn deinit(self: *Writer) void {
        self.walk.deinit();
        self.out.deinit(self.allocator);
        self.codes.deinit(self.allocator);
        self.code_numbers.deinit(self.allocator);
        self.natives.deinit(self.allocator);
        self.native_numbers.deinit(self.allocator);
    }

    fn int(self: *Writer, comptime T: type, n: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, n, .little);
        try self.out.appendSlice(self.allocator, &bytes);
    }

    fn text(self: *Writer, s: []const u8) !void {
        try self.int(u32, @intCast(s.len));
        try self.out.appendSlice(self.allocator, s);
    }

    fn pad(self: *Writer) !void {
        while (self.out.items.len % 8 != 0) try self.out.append(self.allocator, 0);
    }

    fn section(self: *Writer, kind: SectionKind) !usize {
        try self.int(u32, @backingInt(kind));
        try self.int(u32, 0);
        const at = self.out.items.len;
        try self.int(u64, 0);
        return at;
    }

    fn endSection(self: *Writer, at: usize) !void {
        std.mem.writeInt(u64, self.out.items[at..][0..8], self.out.items.len - at - 8, .little);
        try self.pad();
    }

    /// A reference to `v`: the value itself when it refers to nothing,
    /// and its index otherwise.
    fn ref(self: *Writer, v: Value) !void {
        if (v.isCons() or v.isSymbol() or v.tag() == .heap) {
            const index = self.walk.indices.get(v.raw) orelse return Error.TypeError;
            return self.int(u64, refTo(index));
        }
        try self.int(u64, v.raw);
    }

    fn frameRef(self: *Writer, f: ?*Frame) !void {
        const frame = f orelse return self.int(u32, NONE);
        try self.int(u32, self.walk.frame_indices.get(@intFromPtr(frame)).?);
    }

    fn packageIndex(self: *Writer, pkg: *package_mod.Package) u32 {
        for (self.packages, 0..) |p, i| if (p == pkg) return @intCast(i);
        return NONE;
    }

    fn codeNumber(self: *Writer, code: *const Code) !u32 {
        const slot = try self.code_numbers.getOrPut(self.allocator, @intFromPtr(code));
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(self.codes.items.len);
            try self.codes.append(self.allocator, code);
        }
        return slot.value_ptr.*;
    }

    fn nativeNumber(self: *Writer, v: Value) !u32 {
        const slot = try self.native_numbers.getOrPut(self.allocator, v.raw);
        if (!slot.found_existing) {
            const registered = for (self.ev.natives.items, 0..) |n, i| {
                if (n.equalsRaw(v)) break i;
            } else return Error.TypeError;
            slot.value_ptr.* = @intCast(self.natives.items.len);
            try self.natives.append(self.allocator, @intCast(registered));
        }
        return slot.value_ptr.*;
    }

    /// The global value of `sym`: the one outside every dynamic binding
    /// in effect.
    fn globalValue(self: *Writer, sym: Value) Value {
        for (self.ev.dynamic_stack.items) |entry| {
            if (entry.sym.equalsRaw(sym)) return entry.saved;
        }
        return symbol_mod.symbol(sym).value_cell;
    }

    fn writeObject(self: *Writer, entry: Entry) !void {
        switch (entry) {
            .frame => |f| {
                try self.int(u8, @backingInt(Tag.frame));
                try self.frameRef(f.parent);
                const bindings = try f.sortedBindings(self.allocator);
                defer self.allocator.free(bindings);
                try self.int(u32, @intCast(bindings.len));
                for (bindings) |b| {
                    try self.ref(b.sym);
                    try self.ref(b.value);
                }
            },
            .object => |v| {
                if (v.isSymbol()) return self.writeSymbol(v);
                if (v.isCons()) {
                    try self.int(u8, @backingInt(Tag.cons));
                    try self.ref(heap.car(v));
                    return self.ref(heap.cdr(v));
                }
                try self.writeHeapObject(v);
            },
        }
    }

    fn writeSymbol(self: *Writer, v: Value) !void {
        const sym = symbol_mod.symbol(v);
        try self.int(u8, @backingInt(Tag.symbol));
        try self.int(u32, if (sym.home) |pkg| self.packageIndex(pkg) else NONE);
        try self.text(sym.name);
        try self.int(u8, @as(u8, @intFromBool(sym.special)) | (@as(u8, @intFromBool(sym.constant)) << 1) | (@as(u8, @intFromBool(self.symbols_by_name)) << 2));
        if (self.symbols_by_name) return;
        try self.ref(self.globalValue(v));
        try self.ref(sym.function_cell);
        try self.ref(sym.plist);
    }

    fn writeHeapObject(self: *Writer, v: Value) !void {
        switch (heap.heapType(v)) {
            .bignum => {
                const big = heap.asBignum(v);
                try self.int(u8, @backingInt(Tag.bignum));
                try self.int(u8, @intFromBool(!big.positive));
                try self.int(u32, @intCast(big.len));
                for (big.limbs[0..big.len]) |limb| try self.int(u64, limb);
            },
            .ratio => {
                try self.int(u8, @backingInt(Tag.ratio));
                try self.ref(heap.asRatio(v).numerator);
                try self.ref(heap.asRatio(v).denominator);
            },
            .double_float => {
                try self.int(u8, @backingInt(Tag.double_float));
                try self.int(u64, @bitCast(heap.asDoubleFloat(v).value));
            },
            .complex => {
                try self.int(u8, @backingInt(Tag.complex));
                try self.ref(heap.asComplex(v).realpart);
                try self.ref(heap.asComplex(v).imagpart);
            },
            .string => {
                const s = heap.asString(v);
                try self.int(u8, @backingInt(Tag.string));
                try self.int(u64, s.len);
                try self.int(u8, @as(u8, @intFromBool(s.has_fill_pointer)) | (@as(u8, @intFromBool(s.adjustable)) << 1) | (@as(u8, @intFromBool(s.isDisplaced())) << 2));
                if (s.isDisplaced()) {
                    try self.ref(s.displaced_to);
                    const target = heap.asString(s.displaced_to);
                    try self.int(u64, @intCast((@intFromPtr(s.codes) - @intFromPtr(target.codes)) / @sizeOf(u32)));
                } else {
                    try self.int(u64, s.capacity);
                    for (s.codes[0..s.capacity]) |c| try self.int(u32, c);
                }
            },
            .vector => {
                const a = heap.asArray(v);
                try self.int(u8, @backingInt(Tag.array));
                try self.int(u8, @backingInt(a.element_type));
                try self.int(u32, a.rank);
                for (a.dimensions()) |d| try self.int(u64, d);
                const displaced = !(a.displaced_to.raw == 0 or a.displaced_to.equalsRaw(value.NIL));
                try self.int(u8, @as(u8, @intFromBool(a.has_fill_pointer)) | (@as(u8, @intFromBool(a.adjustable)) << 1) | (@as(u8, @intFromBool(displaced)) << 2));
                try self.int(u64, a.fill_pointer);
                if (displaced) {
                    try self.ref(a.displaced_to);
                    try self.int(u64, a.displaced_offset);
                } else {
                    try self.int(u64, a.storage_len);
                    for (a.storage[0..a.storage_len]) |element| try self.ref(element);
                }
            },
            .hash_table => {
                const t = heap.asHashTable(v);
                try self.int(u8, @backingInt(Tag.hash_table));
                try self.int(u8, @backingInt(t.hash_test));
                try self.int(u64, t.requested_size);
                try self.ref(t.rehash_size);
                try self.ref(t.rehash_threshold);
                try self.int(u64, t.live_count);
                for (t.entries.items) |e| {
                    if (!e.live) continue;
                    try self.ref(e.key);
                    try self.ref(e.value);
                }
            },
            .function, .closure => try self.writeFunction(v),
            .structure => {
                const s = heap.asStructure(v);
                try self.int(u8, @backingInt(Tag.structure));
                try self.ref(s.name);
                try self.int(u64, s.len);
                for (s.slice()) |slot| try self.ref(slot);
            },
            .package => {
                try self.int(u8, @backingInt(Tag.package));
                try self.int(u32, self.packageIndex(package_mod.asPackage(v)));
            },
            .pathname => {
                const pn = heap.asPathname(v);
                try self.int(u8, @backingInt(Tag.pathname));
                for ([_]Value{ pn.host, pn.device, pn.directory, pn.name, pn.type_, pn.version }) |c| try self.ref(c);
                try self.int(u8, @intFromBool(pn.is_logical));
            },
            .stream => {
                const st = heap.asStream(v);
                try self.int(u8, @backingInt(Tag.stream));
                try self.int(u8, @backingInt(st.kind));
                try self.int(u8, @backingInt(st.direction));
                try self.int(u8, @backingInt(st.element));
                try self.int(u8, @backingInt(st.external_format));
                try self.ref(st.path);
                try self.ref(st.target);
            },
            .random_state => {
                try self.int(u8, @backingInt(Tag.random_state));
                for (heap.asRandomState(v).state) |word| try self.int(u64, word);
            },
            .readtable => {
                const rt = heap.asReadtable(v);
                const table: *const reader_mod.Readtable = @ptrCast(@alignCast(rt.handlers));
                const standard = reader_mod.reader.defaultReadtable();
                if (!std.mem.eql(u8, std.mem.asBytes(table), std.mem.asBytes(standard))) return Error.TypeError;
                try self.int(u8, @backingInt(Tag.readtable));
                try self.int(u64, rt.case);
            },
            .weak_pointer => {
                try self.int(u8, @backingInt(Tag.weak_pointer));
                try self.ref(heap.asWeakPointer(v).referent);
            },
            else => return Error.TypeError,
        }
    }

    fn writeFunction(self: *Writer, v: Value) !void {
        const f = function.asFunction(v);
        const flags: u8 = @as(u8, @intFromBool(f.preserves_values)) | (@as(u8, @intFromBool(f.keeps_caller)) << 1);
        switch (f.kind) {
            .native => {
                try self.int(u8, @backingInt(Tag.native));
                try self.int(u32, try self.nativeNumber(v));
                try self.int(u8, flags);
            },
            .closure => {
                const c = f.payload.closure;
                try self.int(u8, @backingInt(Tag.closure));
                try self.text(f.name orelse "");
                try self.int(u8, flags | (@as(u8, @intFromBool(f.name != null)) << 2) | (@as(u8, @intFromBool(c.is_macro)) << 3));
                try self.ref(c.params);
                try self.ref(c.body);
                try self.frameRef(c.captured_env);
                try self.frameRef(c.captured_fenv);
            },
            .compiled => {
                try self.int(u8, @backingInt(Tag.compiled));
                try self.int(u32, try self.codeNumber(f.payload.compiled.code));
                try self.int(u8, flags);
                const env = f.closedOver();
                try self.int(u32, @intCast(env.len));
                for (env) |held| try self.ref(held);
            },
            .funcallable => {
                const inst = f.payload.funcallable;
                try self.int(u8, @backingInt(Tag.funcallable));
                try self.int(u8, flags);
                try self.ref(inst.class);
                try self.ref(inst.slots);
                try self.ref(inst.wrapper);
                try self.ref(inst.function);
            },
        }
    }

    fn writeCode(self: *Writer, code: *const Code) !void {
        const at = try self.section(.code);
        try self.text(code.name orelse "");
        try self.int(u8, @as(u8, @intFromBool(code.name != null)) | (@as(u8, @intFromBool(code.takes_extra)) << 1) | (@as(u8, @intFromBool(code.check_args)) << 2));
        for ([_]u32{ code.required, code.optional, code.locals, code.max_stack, @intCast(code.caches.len) }) |n| try self.int(u32, n);
        try self.int(u32, @intCast(code.words.len));
        try self.pad();
        for (code.words) |w| try self.int(u32, w);
        try self.int(u32, @intCast(code.constants.len));
        for (code.constants) |c| try self.ref(c);
        try self.int(u32, @intCast(code.jump_tables.len));
        for (code.jump_tables) |table| {
            try self.int(u32, @intCast(table.len));
            for (table) |offset| try self.int(u32, offset);
        }
        try self.int(u32, @intCast(code.slot_names.len));
        for (code.slot_names) |n| try self.ref(n);
        try self.int(u32, @intCast(code.positions.len));
        for (code.positions) |pos| {
            try self.int(u32, pos.pc);
            try self.int(u32, pos.line);
            try self.int(u32, pos.column);
        }
        try self.text(code.source_file orelse "");
        try self.endSection(at);
    }

    /// Number every compiled body and native the walk reached, in the
    /// order it reached them.
    fn numberCodeAndNatives(self: *Writer) !void {
        for (self.walk.entries.items) |entry| switch (entry) {
            .object => |v| if (function.isFunction(v)) {
                const f = function.asFunction(v);
                if (f.kind == .compiled) _ = try self.codeNumber(f.payload.compiled.code);
                if (f.kind == .native) _ = try self.nativeNumber(v);
            },
            else => {},
        };
    }

    fn writeNatives(self: *Writer) !void {
        try self.int(u32, @intCast(self.natives.items.len));
        for (self.natives.items) |registered| {
            try self.int(u32, registered);
            try self.text(function.asFunction(self.ev.natives.items[registered]).name orelse "");
        }
    }

    fn writeObjects(self: *Writer) !void {
        try self.int(u32, @intCast(self.walk.entries.items.len));
        for (self.walk.entries.items) |entry| try self.writeObject(entry);
    }

    /// The whole session: the packages, everything reachable from their
    /// symbols, and the state.
    fn build(self: *Writer, roots: []const Value) ![]const u8 {
        try walkFrom(self.ev, roots, true, &self.walk);
        try self.numberCodeAndNatives();

        try self.out.appendSlice(self.allocator, MAGIC);
        try self.out.appendSlice(self.allocator, &.{ 1, 0, 0, 0 });
        try self.int(u16, MAJOR);
        try self.int(u16, MINOR);
        try self.int(u32, fasl.instruction_set);
        try self.int(u32, @intCast(5 + self.codes.items.len));
        try self.int(u64, 0);

        const natives_at = try self.section(.natives);
        try self.writeNatives();
        try self.endSection(natives_at);
        for (self.codes.items) |code| try self.writeCode(code);

        const packages_at = try self.section(.packages);
        try self.int(u32, @intCast(self.packages.len));
        for (self.packages) |pkg| {
            try self.text(pkg.name);
            try self.int(u8, @intFromBool(pkg.deleted));
            try self.int(u32, @intCast(pkg.nicknames.items.len));
            for (pkg.nicknames.items) |nick| try self.text(nick);
            try self.int(u32, @intCast(pkg.use_list.items.len));
            for (pkg.use_list.items) |used| try self.int(u32, self.packageIndex(used));
        }
        try self.endSection(packages_at);

        const objects_at = try self.section(.objects);
        try self.writeObjects();
        try self.endSection(objects_at);

        const contents_at = try self.section(.contents);
        for (self.packages) |pkg| {
            const present = try sortedPresent(self.allocator, pkg);
            defer self.allocator.free(present);
            try self.int(u32, @intCast(present.len));
            for (present) |p| {
                try self.ref(p.sym);
                try self.text(p.name);
                try self.int(u8, @as(u8, @intFromBool(p.external)) | (@as(u8, @intFromBool(pkg.isShadowing(p.name))) << 1));
            }
        }
        try self.endSection(contents_at);

        const state_at = try self.section(.state);
        try self.int(u32, self.packageIndex(self.ev.interner.currentPackage()));
        const policy = self.ev.policy;
        for ([_]u2{ policy.speed, policy.safety, policy.debug, policy.space }) |q| try self.int(u8, q);
        try self.ref(self.hosts);
        try self.endSection(state_at);

        std.mem.writeInt(u64, self.out.items[24..32], self.out.items.len, .little);
        return self.out.items;
    }
};

const Present = struct { name: []const u8, sym: Value, external: bool };

fn lessPresent(_: void, a: Present, b: Present) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn sortedPresent(allocator: std.mem.Allocator, pkg: *package_mod.Package) ![]Present {
    var list: std.ArrayListUnmanaged(Present) = .empty;
    var it = pkg.internal.iterator();
    while (it.next()) |kv| try list.append(allocator, .{ .name = kv.key_ptr.*, .sym = kv.value_ptr.*, .external = false });
    var ex = pkg.external.iterator();
    while (ex.next()) |kv| try list.append(allocator, .{ .name = kv.key_ptr.*, .sym = kv.value_ptr.*, .external = true });
    const items = try list.toOwnedSlice(allocator);
    std.mem.sort(Present, items, {}, lessPresent);
    return items;
}

/// The logical pathname hosts as an association list, ordered by name.
fn hostsList(ev: *Evaluator, held: anytype) !Value {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(ev.allocator);
    var it = ev.logical_hosts.keyIterator();
    while (it.next()) |k| try names.append(ev.allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    const start = held.items().len;
    for (names.items) |n| {
        try held.push(try ev.heap.allocCons(try ev.heap.allocString(n), ev.logical_hosts.get(n).?));
    }
    return ev.heap.list(held.items()[start..]);
}

/// The whole session, as an image.
fn saveSession(ev: *Evaluator, allocator: std.mem.Allocator) ![]u8 {
    var held = ev.heap.protect();
    defer held.close();
    try held.push(try hostsList(ev, &held));
    const hosts = held.items()[0];

    var roots: std.ArrayListUnmanaged(Value) = .empty;
    defer roots.deinit(allocator);
    const packages = ev.interner.registry.list.items;
    for (packages) |pkg| {
        const present = try sortedPresent(allocator, pkg);
        defer allocator.free(present);
        for (present) |p| try roots.append(allocator, p.sym);
    }
    for (ev.dynamic_stack.items) |entry| try roots.append(allocator, entry.saved);
    try roots.append(allocator, hosts);

    var w: Writer = .{ .ev = ev, .allocator = allocator, .walk = .{ .allocator = allocator }, .packages = packages, .hosts = hosts };
    defer w.deinit();
    const bytes = try w.build(roots.items);
    return allocator.dupe(u8, bytes);
}

/// `(ext:save-image pathname)`: write the session to the file. True.
fn saveImageFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    const path = try heap.stringUtf8Alloc(ev.allocator, if (heap.isString(args[0])) args[0] else return ev.typeMismatch(args[0], "STRING"));
    defer ev.allocator.free(path);
    const bytes = try saveSession(ev, ev.allocator);
    defer ev.allocator.free(bytes);
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.FileError;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, io, &buf);
    fw.interface.writeAll(bytes) catch return Error.FileError;
    fw.interface.flush() catch return Error.FileError;
    return value.T;
}

// --- reading ---

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    endian: std.builtin.Endian = .little,

    fn int(self: *Reader, comptime T: type) Error!T {
        if (self.at + @sizeOf(T) > self.bytes.len) return Error.FileError;
        const n = std.mem.readInt(T, self.bytes[self.at..][0..@sizeOf(T)], self.endian);
        self.at += @sizeOf(T);
        return n;
    }

    fn text(self: *Reader) Error![]const u8 {
        const n = try self.int(u32);
        if (self.at + n > self.bytes.len) return Error.FileError;
        defer self.at += n;
        return self.bytes[self.at .. self.at + n];
    }

    fn alignTo(self: *Reader, n: usize) void {
        self.at = std.mem.alignForward(usize, self.at, n);
    }
};

/// What a section of one kind holds, found in a first pass so the parts
/// can be read in the order they depend on each other.
const Sections = struct {
    natives: ?usize = null,
    codes: std.ArrayListUnmanaged(usize) = .empty,
    packages: ?usize = null,
    objects: ?usize = null,
    contents: ?usize = null,
    state: ?usize = null,
};

const Loader = struct {
    ev: *Evaluator,
    scratch: std.mem.Allocator,
    r: Reader,
    natives: []Value = &.{},
    codes: []*Code = &.{},
    code_constants: [][]u64 = &.{},
    code_slots: [][]u64 = &.{},
    packages: []*package_mod.Package = &.{},
    frames: std.AutoHashMapUnmanaged(u32, *Frame) = .empty,
    base: usize = 0,
    count: u32 = 0,
    /// Where each object's fields start, for the second pass.
    starts: []usize = &.{},
    tags: []Tag = &.{},

    fn object(self: *Loader, held: anytype, index: u32) Error!Value {
        if (index >= self.count) return Error.FileError;
        return held.items()[self.base + index];
    }

    fn resolve(self: *Loader, held: anytype, raw: u64) Error!Value {
        if (raw & 7 == REF_TAG) return self.object(held, @intCast(raw >> 3));
        return .{ .raw = raw };
    }

    fn frameAt(self: *Loader, index: u32) Error!?*Frame {
        if (index == NONE) return null;
        return self.frames.get(index) orelse Error.FileError;
    }

    fn readRef(self: *Loader, held: anytype) Error!Value {
        return self.resolve(held, try self.r.int(u64));
    }
};

fn readNatives(l: *Loader) Error!void {
    const n = try l.r.int(u32);
    l.natives = try l.scratch.alloc(Value, n);
    for (l.natives) |*slot| {
        const registered = try l.r.int(u32);
        const name = try l.r.text();
        if (registered >= l.ev.natives.items.len) return Error.FileError;
        const native = l.ev.natives.items[registered];
        const native_name = function.asFunction(native).name orelse "";
        if (!std.mem.eql(u8, native_name, name)) return Error.FaslVersion;
        slot.* = native;
    }
}

fn readCode(l: *Loader) Error!*Code {
    const keep = l.ev.heap.allocator;
    const name = try l.r.text();
    const flags = try l.r.int(u8);
    var counts: [5]u32 = undefined;
    for (&counts) |*c| c.* = try l.r.int(u32);
    const word_count = try l.r.int(u32);
    l.r.alignTo(8);
    const words = try keep.alloc(u32, word_count);
    for (words) |*w| w.* = try l.r.int(u32);
    const constants = try keep.alloc(Value, try l.r.int(u32));
    const constant_refs = try l.scratch.alloc(u64, constants.len);
    for (constant_refs) |*c| c.* = try l.r.int(u64);
    @memset(constants, value.NIL);
    const tables = try keep.alloc([]const u32, try l.r.int(u32));
    for (tables) |*table| {
        const offsets = try keep.alloc(u32, try l.r.int(u32));
        for (offsets) |*o| o.* = try l.r.int(u32);
        table.* = offsets;
    }
    const slot_names = try keep.alloc(Value, try l.r.int(u32));
    const slot_refs = try l.scratch.alloc(u64, slot_names.len);
    for (slot_refs) |*s| s.* = try l.r.int(u64);
    @memset(slot_names, .{ .raw = 0 });
    const positions = try keep.alloc(bytecode.Position, try l.r.int(u32));
    for (positions) |*pos| pos.* = .{ .pc = try l.r.int(u32), .line = try l.r.int(u32), .column = try l.r.int(u32) };
    const file = try l.r.text();
    const caches = try keep.alloc(bytecode.CallCache, counts[4]);
    @memset(caches, .{});
    const code = try keep.create(Code);
    code.* = .{
        .words = words,
        .constants = constants,
        .jump_tables = tables,
        .name = if (flags & 1 != 0) try keep.dupe(u8, name) else null,
        .required = counts[0],
        .optional = counts[1],
        .takes_extra = flags & 2 != 0,
        .check_args = flags & 4 != 0,
        .locals = counts[2],
        .max_stack = counts[3],
        .slot_names = slot_names,
        .caches = caches,
        .positions = positions,
        .source_file = if (file.len > 0) try keep.dupe(u8, file) else null,
    };
    return code;
}

fn readPackages(l: *Loader) Error!void {
    const n = try l.r.int(u32);
    l.packages = try l.scratch.alloc(*package_mod.Package, n);
    const registry = &l.ev.interner.registry;
    const Use = struct { pkg: *package_mod.Package, used: []u32 };
    var uses: std.ArrayListUnmanaged(Use) = .empty;
    for (l.packages) |*slot| {
        const name = try l.r.text();
        const deleted = try l.r.int(u8) != 0;
        const pkg = registry.find(name) orelse registry.create(name) catch return Error.PackageError;
        pkg.deleted = deleted;
        slot.* = pkg;
        const nick_count = try l.r.int(u32);
        for (0..nick_count) |_| registry.addNickname(pkg, try l.r.text()) catch return Error.PackageError;
        const used = try l.scratch.alloc(u32, try l.r.int(u32));
        for (used) |*u| u.* = try l.r.int(u32);
        try uses.append(l.scratch, .{ .pkg = pkg, .used = used });
    }
    for (uses.items) |u| {
        for (u.used) |i| {
            if (i >= l.packages.len) return Error.FileError;
            if (!u.pkg.usesPackage(l.packages[i])) u.pkg.addUse(l.packages[i]) catch return Error.PackageError;
        }
    }
}

/// Make every object, leaving what refers to other objects to be filled
/// in by `linkObjects`.
fn makeObjects(l: *Loader, held: anytype) Error!void {
    const ev = l.ev;
    l.count = try l.r.int(u32);
    l.base = held.items().len;
    l.starts = try l.scratch.alloc(usize, l.count);
    l.tags = try l.scratch.alloc(Tag, l.count);
    for (0..l.count) |i| {
        const tag: Tag = @fromBackingInt(@intCast(try l.r.int(u8)));
        l.tags[i] = tag;
        l.starts[i] = l.r.at;
        const made: Value = switch (tag) {
            .bignum => blk: {
                const negative = try l.r.int(u8) == 1;
                const limbs = try ev.heap.allocator.alloc(std.math.big.Limb, try l.r.int(u32));
                for (limbs) |*limb| limb.* = @intCast(try l.r.int(u64));
                break :blk try ev.heap.allocBignum(.{ .limbs = limbs, .positive = !negative });
            },
            .double_float => try ev.heap.allocDoubleFloat(@bitCast(try l.r.int(u64))),
            .ratio, .complex => blk: {
                l.r.at += 16;
                break :blk if (tag == .ratio)
                    try ev.heap.allocRatio(Value.fromFixnum(0), Value.fromFixnum(1))
                else
                    try ev.heap.allocComplex(Value.fromFixnum(0), Value.fromFixnum(1));
            },
            .string => blk: {
                const len = try l.r.int(u64);
                const flags = try l.r.int(u8);
                if (flags & 4 != 0) {
                    l.r.at += 16;
                    break :blk try ev.heap.allocStringWithCapacity(0, 0);
                }
                const capacity = try l.r.int(u64);
                const s = try ev.heap.allocStringWithCapacity(@intCast(len), @intCast(capacity));
                const str = heap.asString(s);
                for (str.codes[0..capacity]) |*c| c.* = try l.r.int(u32);
                str.has_fill_pointer = flags & 1 != 0;
                str.adjustable = flags & 2 != 0;
                break :blk s;
            },
            .symbol => blk: {
                const home = try l.r.int(u32);
                const name = try l.r.text();
                const flags = try l.r.int(u8);
                if (flags & 4 == 0) l.r.at += 24;
                const sym = if (home == NONE)
                    try ev.interner.makeUninterned(name)
                else if (home < l.packages.len)
                    try ev.interner.internLocal(l.packages[home], name)
                else
                    return Error.FileError;
                if (flags & 4 == 0) {
                    symbol_mod.symbol(sym).special = flags & 1 != 0;
                    symbol_mod.symbol(sym).constant = flags & 2 != 0;
                }
                break :blk sym;
            },
            .cons => blk: {
                l.r.at += 16;
                break :blk try ev.heap.allocCons(value.NIL, value.NIL);
            },
            .array => blk: {
                const element: heap.ElementType = @fromBackingInt(@intCast(try l.r.int(u8)));
                const rank = try l.r.int(u32);
                const dims = try l.scratch.alloc(usize, rank);
                for (dims) |*d| d.* = @intCast(try l.r.int(u64));
                const flags = try l.r.int(u8);
                const fill = try l.r.int(u64);
                const a = try ev.heap.allocArray(if (flags & 4 != 0) dims[0..0] else dims, element);
                const array = heap.asArray(a);
                if (flags & 4 != 0) {
                    l.r.at += 16;
                } else {
                    const n = try l.r.int(u64);
                    if (n != array.storage_len) return Error.FileError;
                    l.r.at += 8 * n;
                }
                array.has_fill_pointer = flags & 1 != 0;
                array.adjustable = flags & 2 != 0;
                array.fill_pointer = fill;
                break :blk a;
            },
            .hash_table => blk: {
                const hash_test: heap.HashTest = @fromBackingInt(@intCast(try l.r.int(u8)));
                const size = try l.r.int(u64);
                l.r.at += 16;
                const n = try l.r.int(u64);
                l.r.at += 16 * n;
                break :blk try ev.heap.allocHashTableWith(hash_test, size, value.NIL, value.NIL);
            },
            .native => blk: {
                const index = try l.r.int(u32);
                const flags = try l.r.int(u8);
                if (index >= l.natives.len) return Error.FileError;
                const f = function.asFunction(l.natives[index]);
                f.preserves_values = flags & 1 != 0;
                f.keeps_caller = flags & 2 != 0;
                break :blk l.natives[index];
            },
            .closure => blk: {
                const name = try l.r.text();
                const flags = try l.r.int(u8);
                l.r.at += 16 + 8;
                const c = try function.allocClosure(
                    ev.heap.allocator,
                    if (flags & 4 != 0) try ev.heap.allocator.dupe(u8, name) else null,
                    value.NIL,
                    value.NIL,
                    null,
                    null,
                );
                const f = function.asFunction(c);
                f.preserves_values = flags & 1 != 0;
                f.keeps_caller = flags & 2 != 0;
                f.payload.closure.is_macro = flags & 8 != 0;
                break :blk c;
            },
            .compiled => blk: {
                const number = try l.r.int(u32);
                const flags = try l.r.int(u8);
                const n = try l.r.int(u32);
                l.r.at += 8 * n;
                if (number >= l.codes.len) return Error.FileError;
                const nils = try l.scratch.alloc(Value, n);
                @memset(nils, value.NIL);
                const c = try function.allocCompiled(ev.heap, l.codes[number], nils);
                function.asFunction(c).keeps_caller = flags & 2 != 0;
                break :blk c;
            },
            .funcallable => blk: {
                const flags = try l.r.int(u8);
                l.r.at += 32;
                const c = try function.allocFuncallable(ev.heap.allocator, value.NIL, value.NIL, value.NIL);
                function.asFunction(c).keeps_caller = flags & 2 != 0;
                break :blk c;
            },
            .frame => blk: {
                l.r.at += 4;
                const n = try l.r.int(u32);
                l.r.at += 16 * n;
                const f = try ev.env.frameAllocator().create(Frame);
                f.* = .{ .captured = true };
                try ev.env.captured_frames.append(ev.allocator, f);
                try l.frames.put(l.scratch, @intCast(i), f);
                break :blk value.NIL;
            },
            .structure => blk: {
                l.r.at += 8;
                const n = try l.r.int(u64);
                l.r.at += 8 * n;
                const nils = try l.scratch.alloc(Value, n);
                @memset(nils, value.NIL);
                break :blk try ev.heap.allocStructure(value.NIL, nils);
            },
            .package => blk: {
                const index = try l.r.int(u32);
                if (index >= l.packages.len) return Error.FileError;
                break :blk l.packages[index].toValue();
            },
            .pathname => blk: {
                l.r.at += 48 + 1;
                break :blk try ev.heap.allocPathname(.{
                    .host = value.NIL,
                    .device = value.NIL,
                    .directory = value.NIL,
                    .name = value.NIL,
                    .type_ = value.NIL,
                    .version = value.NIL,
                });
            },
            .stream => blk: {
                const kind: heap.StreamKind = @fromBackingInt(@intCast(try l.r.int(u8)));
                const direction: heap.StreamDirection = @fromBackingInt(@intCast(try l.r.int(u8)));
                const element: heap.StreamElement = @fromBackingInt(@intCast(try l.r.int(u8)));
                const format: heap.ExternalFormat = @fromBackingInt(@intCast(try l.r.int(u8)));
                l.r.at += 16;
                var st = streams.emptyStream(kind, direction);
                st.element = element;
                st.external_format = format;
                // A console stream talks to this session's terminal, and
                // any other comes back closed.
                st.is_open = kind == .console;
                break :blk try ev.heap.allocStream(st);
            },
            .random_state => blk: {
                var state: [4]u64 = undefined;
                for (&state) |*word| word.* = try l.r.int(u64);
                break :blk try ev.heap.allocRandomState(state);
            },
            .readtable => blk: {
                const case = try l.r.int(u64);
                const bytes = try ev.heap.allocator.alignedAlloc(u8, .of(reader_mod.Readtable), @sizeOf(reader_mod.Readtable));
                const table: *reader_mod.Readtable = @ptrCast(bytes.ptr);
                table.* = reader_mod.reader.defaultReadtable().*;
                break :blk try ev.heap.allocReadtable(bytes, case);
            },
            .weak_pointer => blk: {
                l.r.at += 8;
                break :blk try ev.heap.allocWeakPointer(value.NIL);
            },
            _ => return Error.FaslVersion,
        };
        try held.push(made);
    }
}

/// Fill in every reference, now that every object it can name exists.
fn linkObjects(l: *Loader, held: anytype) Error!void {
    const ev = l.ev;
    const end = l.r.at;
    defer l.r.at = end;
    for (0..l.count) |i| {
        l.r.at = l.starts[i];
        const target = try l.object(held, @intCast(i));
        switch (l.tags[i]) {
            .ratio => {
                const r = heap.asRatio(target);
                r.numerator = try l.readRef(held);
                r.denominator = try l.readRef(held);
                heap.writeBarrier(ev.heap, target, r.numerator);
                heap.writeBarrier(ev.heap, target, r.denominator);
            },
            .complex => {
                const z = heap.asComplex(target);
                z.realpart = try l.readRef(held);
                z.imagpart = try l.readRef(held);
                heap.writeBarrier(ev.heap, target, z.realpart);
                heap.writeBarrier(ev.heap, target, z.imagpart);
            },
            .string => {
                const len = try l.r.int(u64);
                const flags = try l.r.int(u8);
                if (flags & 4 == 0) continue;
                const to = try l.readRef(held);
                const offset = try l.r.int(u64);
                if (!heap.isString(to)) return Error.FileError;
                const s = heap.asString(target);
                s.displaced_to = to;
                s.codes = heap.asString(to).codes + offset;
                s.len = len;
                s.capacity = len;
                s.has_fill_pointer = flags & 1 != 0;
                s.adjustable = flags & 2 != 0;
                heap.writeBarrier(ev.heap, target, to);
            },
            .symbol => {
                _ = try l.r.int(u32);
                _ = try l.r.text();
                if (try l.r.int(u8) & 4 != 0) continue;
                const sym = symbol_mod.symbol(target);
                sym.value_cell = try l.readRef(held);
                sym.function_cell = try l.readRef(held);
                sym.plist = try l.readRef(held);
            },
            .cons => {
                heap.setCar(ev.heap, target, try l.readRef(held));
                heap.setCdr(ev.heap, target, try l.readRef(held));
            },
            .array => {
                _ = try l.r.int(u8);
                const rank = try l.r.int(u32);
                const dims = try l.scratch.alloc(u64, rank);
                for (dims) |*d| d.* = try l.r.int(u64);
                const flags = try l.r.int(u8);
                _ = try l.r.int(u64);
                const a = heap.asArray(target);
                if (flags & 4 != 0) {
                    const to = try l.readRef(held);
                    const offset = try l.r.int(u64);
                    if (!heap.isArray(to)) return Error.FileError;
                    a.displaced_to = to;
                    a.displaced_offset = offset;
                    a.storage = heap.asArray(to).storage + offset;
                    @memcpy(a.dims[0..rank], dims);
                    var total: u64 = 1;
                    for (dims) |d| total *= d;
                    a.storage_len = total;
                    heap.writeBarrier(ev.heap, target, to);
                } else {
                    const n = try l.r.int(u64);
                    for (0..n) |k| heap.setSlot(ev.heap, target, k, try l.readRef(held));
                }
            },
            // A key is hashed on what it holds, so the tables are filled
            // once everything else is.
            .hash_table => {},
            .closure => {
                _ = try l.r.text();
                _ = try l.r.int(u8);
                const c = &function.asFunction(target).payload.closure;
                c.params = try l.readRef(held);
                c.body = try l.readRef(held);
                c.captured_env = try l.frameAt(try l.r.int(u32));
                c.captured_fenv = try l.frameAt(try l.r.int(u32));
            },
            .compiled => {
                _ = try l.r.int(u32);
                _ = try l.r.int(u8);
                const n = try l.r.int(u32);
                const env = function.asFunction(target).closedOver();
                if (env.len != n) return Error.FileError;
                for (env) |*slot| {
                    slot.* = try l.readRef(held);
                    heap.writeBarrier(ev.heap, target, slot.*);
                }
            },
            .funcallable => {
                _ = try l.r.int(u8);
                const inst = &function.asFunction(target).payload.funcallable;
                inst.class = try l.readRef(held);
                inst.slots = try l.readRef(held);
                inst.wrapper = try l.readRef(held);
                inst.function = try l.readRef(held);
            },
            .frame => {
                const f = l.frames.get(@intCast(i)).?;
                f.parent = try l.frameAt(try l.r.int(u32));
                const n = try l.r.int(u32);
                for (0..n) |_| {
                    const sym = try l.readRef(held);
                    const val = try l.readRef(held);
                    if (!sym.isSymbol()) return Error.FileError;
                    try f.bind(ev.env.frameAllocator(), sym, val);
                }
            },
            .structure => {
                const s = heap.asStructure(target);
                s.name = try l.readRef(held);
                heap.writeBarrier(ev.heap, target, s.name);
                const n = try l.r.int(u64);
                for (0..n) |k| heap.setSlot(ev.heap, target, k, try l.readRef(held));
            },
            .pathname => {
                const pn = heap.asPathname(target);
                inline for (.{ "host", "device", "directory", "name", "type_", "version" }) |field| {
                    @field(pn, field) = try l.readRef(held);
                    heap.writeBarrier(ev.heap, target, @field(pn, field));
                }
                pn.is_logical = try l.r.int(u8) != 0;
            },
            .stream => {
                l.r.at += 4;
                const st = heap.asStream(target);
                st.path = try l.readRef(held);
                st.target = try l.readRef(held);
                heap.writeBarrier(ev.heap, target, st.path);
                heap.writeBarrier(ev.heap, target, st.target);
            },
            .weak_pointer => {
                heap.asWeakPointer(target).referent = try l.readRef(held);
            },
            else => {},
        }
    }
    for (0..l.count) |i| {
        if (l.tags[i] != .hash_table) continue;
        l.r.at = l.starts[i];
        const target = try l.object(held, @intCast(i));
        _ = try l.r.int(u8);
        _ = try l.r.int(u64);
        const t = heap.asHashTable(target);
        t.rehash_size = try l.readRef(held);
        t.rehash_threshold = try l.readRef(held);
        heap.writeBarrier(ev.heap, target, t.rehash_size);
        heap.writeBarrier(ev.heap, target, t.rehash_threshold);
        const n = try l.r.int(u64);
        for (0..n) |_| {
            const key = try l.readRef(held);
            const val = try l.readRef(held);
            try hash_tables.put(ev, target, key, val);
        }
    }
}

fn fillCode(l: *Loader, held: anytype, code_refs: []const CodeRefs) Error!void {
    for (l.codes, code_refs) |code, refs| {
        for (refs.constants, 0..) |raw, k| code.constants[k] = try l.resolve(held, raw);
        const names = @constCast(code.slot_names);
        for (refs.slots, 0..) |raw, k| names[k] = if (raw == 0) .{ .raw = 0 } else try l.resolve(held, raw);
        try l.ev.registerCode(code);
    }
}

const CodeRefs = struct { constants: []u64, slots: []u64 };

fn readContents(l: *Loader, held: anytype) Error!void {
    for (l.packages) |pkg| {
        const n = try l.r.int(u32);
        for (0..n) |_| {
            const sym = try l.readRef(held);
            const name = try l.r.text();
            const flags = try l.r.int(u8);
            if (!sym.isSymbol()) return Error.FileError;
            const owned = symbol_mod.symbol(sym).name;
            const key = if (std.mem.eql(u8, owned, name)) owned else try l.ev.interner.registry.dupeName(name);
            pkg.removePresent(key);
            if (flags & 1 != 0) try pkg.addExternal(key, sym) else try pkg.addInternal(key, sym);
            if (flags & 2 != 0) try pkg.shadowing.put(pkg.allocator, key, sym);
        }
    }
}

fn readState(l: *Loader, held: anytype) Error!void {
    const ev = l.ev;
    const current = try l.r.int(u32);
    if (current < l.packages.len) ev.interner.setCurrentPackage(l.packages[current]);
    ev.policy = .{
        .speed = @intCast(try l.r.int(u8)),
        .safety = @intCast(try l.r.int(u8)),
        .debug = @intCast(try l.r.int(u8)),
        .space = @intCast(try l.r.int(u8)),
    };
    var hosts = try l.readRef(held);
    while (hosts.isCons()) : (hosts = heap.cdr(hosts)) {
        const pair = heap.car(hosts);
        const name = try heap.stringUtf8Alloc(ev.allocator, heap.car(pair));
        try ev.logical_hosts.put(ev.allocator, name, heap.cdr(pair));
    }
}

/// Read the image `bytes` into this evaluator, which has its natives
/// registered and nothing else loaded.
pub fn load(ev: *Evaluator, bytes: []const u8) Error!void {
    if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..8], MAGIC)) return Error.FileError;
    var arena = std.heap.ArenaAllocator.init(ev.allocator);
    defer arena.deinit();
    var l: Loader = .{ .ev = ev, .scratch = arena.allocator(), .r = .{ .bytes = bytes, .at = 8 } };
    l.r.endian = switch (bytes[8]) {
        1 => .little,
        2 => .big,
        else => return Error.FileError,
    };
    l.r.at = 12;
    const major = try l.r.int(u16);
    _ = try l.r.int(u16);
    const iset = try l.r.int(u32);
    if (major != MAJOR or iset != fasl.instruction_set) return Error.FaslVersion;
    const section_count = try l.r.int(u32);
    _ = try l.r.int(u64);

    var sections: Sections = .{};
    for (0..section_count) |_| {
        const kind: SectionKind = @fromBackingInt(@intCast(try l.r.int(u32)));
        _ = try l.r.int(u32);
        const length = try l.r.int(u64);
        const start = l.r.at;
        if (start + length > bytes.len) return Error.FileError;
        switch (kind) {
            .natives => sections.natives = start,
            .code => try sections.codes.append(l.scratch, start),
            .packages => sections.packages = start,
            .objects => sections.objects = start,
            .contents => sections.contents = start,
            .state => sections.state = start,
            _ => {},
        }
        l.r.at = std.mem.alignForward(usize, start + length, 8);
    }

    var held = ev.heap.protect();
    defer held.close();
    const previous = ev.eval_depth;
    ev.eval_depth += 1;
    defer ev.eval_depth = previous;

    l.r.at = sections.natives orelse return Error.FileError;
    try readNatives(&l);
    l.codes = try l.scratch.alloc(*Code, sections.codes.items.len);
    const code_refs = try l.scratch.alloc(CodeRefs, sections.codes.items.len);
    for (sections.codes.items, 0..) |at, i| {
        l.r.at = at;
        l.codes[i] = try readCode(&l);
        l.r.at = at;
        code_refs[i] = try codeReferences(&l);
    }
    l.r.at = sections.packages orelse return Error.FileError;
    try readPackages(&l);
    l.r.at = sections.objects orelse return Error.FileError;
    try makeObjects(&l, &held);
    try linkObjects(&l, &held);
    try fillCode(&l, &held, code_refs);
    l.r.at = sections.contents orelse return Error.FileError;
    try readContents(&l, &held);
    if (sections.state) |at| {
        l.r.at = at;
        try readState(&l, &held);
    }
}

/// The constant and slot-name references of the code section at the
/// reader's position.
fn codeReferences(l: *Loader) Error!CodeRefs {
    _ = try l.r.text();
    _ = try l.r.int(u8);
    for (0..5) |_| _ = try l.r.int(u32);
    const word_count = try l.r.int(u32);
    l.r.alignTo(8);
    l.r.at += 4 * word_count;
    const constants = try l.scratch.alloc(u64, try l.r.int(u32));
    for (constants) |*c| c.* = try l.r.int(u64);
    const tables = try l.r.int(u32);
    for (0..tables) |_| {
        const n = try l.r.int(u32);
        l.r.at += 4 * n;
    }
    const slots = try l.scratch.alloc(u64, try l.r.int(u32));
    for (slots) |*s| s.* = try l.r.int(u64);
    return .{ .constants = constants, .slots = slots };
}

// --- one object graph, for the round-trip tests ---

/// `(%image-round-trip object)`: what is reachable from `object`, not
/// going through symbols, written the way an image writes it and read
/// back as fresh objects. A symbol comes back as the symbol of that name.
fn imageRoundTripFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var w: Writer = .{
        .ev = ev,
        .allocator = ev.allocator,
        .walk = .{ .allocator = ev.allocator },
        .packages = ev.interner.registry.list.items,
        .symbols_by_name = true,
    };
    defer w.deinit();
    try walkFrom(ev, args[0..1], false, &w.walk);
    try w.numberCodeAndNatives();
    const natives_at = w.out.items.len;
    try w.writeNatives();
    var code_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer code_starts.deinit(ev.allocator);
    for (w.codes.items) |code| {
        try w.pad();
        try code_starts.append(ev.allocator, w.out.items.len + 16);
        try w.writeCode(code);
    }
    try w.pad();
    const objects_at = w.out.items.len;
    try w.writeObjects();

    var arena = std.heap.ArenaAllocator.init(ev.allocator);
    defer arena.deinit();
    var l: Loader = .{ .ev = ev, .scratch = arena.allocator(), .r = .{ .bytes = w.out.items, .at = natives_at } };
    l.packages = @constCast(ev.interner.registry.list.items);
    try readNatives(&l);
    l.codes = try l.scratch.alloc(*Code, code_starts.items.len);
    const code_refs = try l.scratch.alloc(CodeRefs, code_starts.items.len);
    for (code_starts.items, 0..) |at, i| {
        l.r.at = at;
        l.codes[i] = try readCode(&l);
        l.r.at = at;
        code_refs[i] = try codeReferences(&l);
    }
    var held = ev.heap.protect();
    defer held.close();
    const previous = ev.eval_depth;
    ev.eval_depth += 1;
    defer ev.eval_depth = previous;
    l.r.at = objects_at;
    try makeObjects(&l, &held);
    try linkObjects(&l, &held);
    try fillCode(&l, &held, code_refs);
    const index = w.walk.indices.get(args[0].raw) orelse return args[0];
    return l.object(&held, index);
}

/// Read the image file at `path` into `ev`.
pub fn loadPath(ev: *Evaluator, path: []const u8) Error!void {
    const io = ev.io orelse return Error.FileError;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, ev.allocator, .unlimited) catch return Error.FileError;
    defer ev.allocator.free(bytes);
    return load(ev, bytes);
}
