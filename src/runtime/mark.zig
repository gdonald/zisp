//! The mark phase.
//!
//! Reachable objects have their mark bit set, which lives in a bitmap on
//! the region that owns them rather than in the object, so a cons needs
//! no header. The traversal runs off an explicit worklist so a deep
//! structure cannot overflow the host stack.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const symbol_mod = @import("symbol.zig");
const function = @import("../eval/function.zig");
const gc = @import("gc.zig");
const env_mod = @import("../eval/env.zig");

const Value = value.Value;
const Heap = heap.Heap;

/// The address a value refers to, or null when it refers to nothing the
/// collector can reclaim.
fn referentAddress(v: Value) ?usize {
    if (v.isCons()) return v.toConsAddr();
    if (v.tag() == .heap) return v.toHeapAddr();
    return null;
}

/// How much of the heap a mark phase covers. A young one stops at an
/// object the tenured space holds: what such an object refers to in the
/// nursery is reached through its card instead, so the walk costs what
/// the program has just made rather than everything it has kept.
pub const Reach = enum { young, everything };

/// The state one mark phase carries: the objects still to visit, and the
/// symbols already descended into.
///
/// Symbols live in the interner's arena rather than the collected heap,
/// so they have no mark bit and need their own record of what has been
/// seen. Without it a symbol whose value cell holds itself would loop.
pub const Marker = struct {
    allocator: std.mem.Allocator,
    heap: *Heap,
    reach: Reach = .everything,
    worklist: std.ArrayListUnmanaged(Value) = .empty,
    /// Environment frames still to visit. A frame is not a heap object,
    /// so a closure that captured one keeps it alive through here.
    frames: std.ArrayListUnmanaged(*env_mod.Frame) = .empty,
    visited_frames: std.AutoHashMapUnmanaged(usize, void) = .empty,
    visited_symbols: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Objects outside the collected heap that have been descended
    /// into. Anything inside it records that in its mark bit instead.
    visited: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Weak pointers the walk reached. What they refer to is not marked
    /// through them, so each is looked at again once the walk is done.
    weak: std.ArrayListUnmanaged(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator, h: *Heap) Marker {
        return .{ .allocator = allocator, .heap = h };
    }

    pub fn deinit(self: *Marker) void {
        self.worklist.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.visited_frames.deinit(self.allocator);
        self.visited_symbols.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.weak.deinit(self.allocator);
    }

    /// What is being scanned, for the report when a root turns out to
    /// hold something already reclaimed.
    pub var source: []const u8 = "unknown";

    /// Add a root. Nothing is traversed until `run`.
    pub fn push(self: *Marker, v: Value) !void {
        if (gc.checked) {
            const address = if (v.isCons())
                v.toConsAddr()
            else if (v.tag() == .heap)
                v.toHeapAddr()
            else
                0;
            if (address != 0 and self.heap.objects.owns(address) and gc.isPoisoned(address)) {
                std.debug.panic("{s} holds a reclaimed object at 0x{x}", .{ source, address });
            }
        }
        try self.worklist.append(self.allocator, v);
    }

    /// Add an environment frame and everything it binds.
    pub fn pushFrame(self: *Marker, frame: ?*env_mod.Frame) !void {
        const f = frame orelse return;
        try self.frames.append(self.allocator, f);
    }

    /// Visit everything reachable from what has been pushed.
    pub fn run(self: *Marker) !void {
        while (self.worklist.items.len > 0 or self.frames.items.len > 0) {
            while (self.worklist.pop()) |v| try self.visit(v);
            while (self.frames.pop()) |frame| try self.visitFrame(frame);
        }
    }

    fn visitFrame(self: *Marker, frame: *env_mod.Frame) !void {
        const slot = try self.visited_frames.getOrPut(self.allocator, @intFromPtr(frame));
        if (slot.found_existing) return;
        for (frame.symbols.items) |sym| try self.push(sym);
        for (frame.values.items) |v| try self.push(v);
        if (frame.map) |map| {
            var it = map.valueIterator();
            while (it.next()) |v| try self.push(v.*);
        }
        try self.pushFrame(frame.parent);
    }

    /// Mark one value and queue whatever it points at.
    fn visit(self: *Marker, v: Value) !void {
        if (v.isSymbol()) return self.visitSymbol(v);
        const address = if (v.isCons())
            v.toConsAddr()
        else if (v.tag() == .heap)
            v.toHeapAddr()
        else
            return;

        if (self.heap.objects.owns(address)) {
            if (self.reach == .young and !self.heap.objects.inNursery(address)) return;
            // The mark bit doubles as the record of what has been
            // descended into, so a cycle stops on its second visit.
            if (self.heap.objects.isMarked(address)) return;
            _ = self.heap.objects.mark(address);
        } else if (try self.wasVisited(address)) {
            // An object the collected heap does not own, a closure among
            // them, carries no mark bit and sits on no card, so it is
            // followed whatever the reach.
            return;
        }

        if (v.isCons()) {
            try self.push(heap.car(v));
            try self.push(heap.cdr(v));
            return;
        }
        try self.visitHeapObject(v);
    }

    /// Queue what one object refers to without marking the object
    /// itself. A young collection wants this of every object on a dirty
    /// card: the card says the object holds a young reference, and the
    /// object itself is not what is being collected.
    pub fn pushSlots(self: *Marker, v: Value) !void {
        if (v.isCons()) {
            try self.push(heap.car(v));
            try self.push(heap.cdr(v));
            return;
        }
        try self.visitHeapObject(v);
    }

    /// Whether an object outside the collected heap, which has no mark
    /// bit to record it, has already been descended into.
    fn wasVisited(self: *Marker, address: usize) !bool {
        const slot = try self.visited.getOrPut(self.allocator, address);
        return slot.found_existing;
    }

    fn visitSymbol(self: *Marker, v: Value) !void {
        const slot = try self.visited_symbols.getOrPut(self.allocator, v.raw);
        if (slot.found_existing) return;
        const sym = symbol_mod.symbol(v);
        try self.push(sym.value_cell);
        try self.push(sym.function_cell);
        try self.push(sym.plist);
    }

    fn visitHeapObject(self: *Marker, v: Value) !void {
        switch (heap.heapType(v)) {
            // Nothing inside these points at another object.
            .bignum, .single_float, .double_float, .random_state, .package, .readtable => {},
            // A displaced string's storage belongs to its target.
            .string => {
                const text = heap.asString(v);
                if (text.isDisplaced()) try self.push(text.displaced_to);
            },
            .ratio => {
                const r = heap.asRatio(v);
                try self.push(r.numerator);
                try self.push(r.denominator);
            },
            .complex => {
                const z = heap.asComplex(v);
                try self.push(z.realpart);
                try self.push(z.imagpart);
            },
            .pathname => {
                const p = heap.asPathname(v);
                for ([_]Value{ p.host, p.device, p.directory, p.name, p.type_, p.version }) |c| {
                    try self.push(c);
                }
            },
            .vector => {
                const a = heap.asArray(v);
                try self.push(a.displaced_to);
                // A displaced array does not own its storage, and the
                // array it points at will be walked in its own right.
                if (a.displaced_to.equalsRaw(value.NIL)) {
                    for (a.storage[0..a.storage_len]) |element| try self.push(element);
                }
            },
            .structure => {
                const s = heap.asStructure(v);
                try self.push(s.name);
                for (s.slice()) |element| try self.push(element);
            },
            .hash_table => {
                const table = heap.asHashTable(v);
                for (table.entries.items) |entry| {
                    try self.push(entry.key);
                    try self.push(entry.value);
                }
            },
            .stream => {
                const s = heap.asStream(v);
                try self.push(s.path);
                try self.push(s.target);
                try self.push(s.delete_on_close);
            },
            .function, .closure => try self.visitFunction(v),
            // A weak pointer keeps nothing alive, so what it refers to
            // is not pushed. It is looked at again after the walk.
            .weak_pointer => try self.weak.append(self.allocator, v),
            else => {},
        }
    }

    /// Break every weak pointer whose referent the walk did not reach.
    ///
    /// A young walk marked the nursery alone, so only a referent there
    /// can be told apart from one the walk simply stopped at.
    pub fn breakDeadWeakPointers(self: *Marker) void {
        for (self.weak.items) |v| {
            const pointer = heap.asWeakPointer(v);
            const address = referentAddress(pointer.referent) orelse continue;
            if (!self.heap.objects.owns(address)) continue;
            if (self.reach == .young and !self.heap.objects.inNursery(address)) continue;
            if (self.heap.objects.isMarked(address)) continue;
            pointer.referent = value.BROKEN;
        }
    }

    fn visitFunction(self: *Marker, v: Value) !void {
        const f = function.asFunction(v);
        if (f.kind != .closure) return;
        try self.push(f.payload.closure.params);
        try self.push(f.payload.closure.body);
        try self.pushFrame(f.payload.closure.captured_env);
        try self.pushFrame(f.payload.closure.captured_fenv);
    }
};
