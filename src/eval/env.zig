const std = @import("std");
const value = @import("../runtime/value.zig");
const symbol_mod = @import("../runtime/symbol.zig");

const Value = value.Value;

pub const HASH_THRESHOLD: usize = 16;

pub const Frame = struct {
    parent: ?*Frame = null,
    /// Set when a closure captured this frame. A tail call may not reuse
    /// such a frame: the closure still reads the bindings it holds.
    captured: bool = false,
    symbols: std.ArrayList(Value) = .empty,
    values: std.ArrayList(Value) = .empty,
    map: ?std.AutoHashMapUnmanaged(u64, Value) = null,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.values.deinit(allocator);
        if (self.map) |*m| m.deinit(allocator);
    }

    pub fn reset(self: *Frame) void {
        self.symbols.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        if (self.map) |*m| m.clearRetainingCapacity();
    }

    pub fn count(self: *const Frame) usize {
        if (self.map) |m| return m.count();
        return self.symbols.items.len;
    }

    pub fn bind(self: *Frame, allocator: std.mem.Allocator, sym: Value, val: Value) !void {
        std.debug.assert(sym.isSymbol());
        if (self.map) |*m| {
            try m.put(allocator, sym.raw, val);
            return;
        }
        for (self.symbols.items, 0..) |s, i| {
            if (s.equalsRaw(sym)) {
                self.values.items[i] = val;
                return;
            }
        }
        try self.symbols.append(allocator, sym);
        try self.values.append(allocator, val);
        if (self.symbols.items.len > HASH_THRESHOLD) {
            try self.promote(allocator);
        }
    }

    fn promote(self: *Frame, allocator: std.mem.Allocator) !void {
        var m: std.AutoHashMapUnmanaged(u64, Value) = .{};
        try m.ensureTotalCapacity(allocator, @intCast(self.symbols.items.len));
        for (self.symbols.items, self.values.items) |s, v| {
            m.putAssumeCapacity(s.raw, v);
        }
        self.symbols.deinit(allocator);
        self.values.deinit(allocator);
        self.symbols = .empty;
        self.values = .empty;
        self.map = m;
    }

    pub fn find(self: *const Frame, sym: Value) ?Value {
        std.debug.assert(sym.isSymbol());
        if (self.map) |m| {
            return m.get(sym.raw);
        }
        for (self.symbols.items, 0..) |s, i| {
            if (s.equalsRaw(sym)) return self.values.items[i];
        }
        return null;
    }

    pub fn slotFor(self: *Frame, sym: Value) ?*Value {
        std.debug.assert(sym.isSymbol());
        if (self.map) |*m| return m.getPtr(sym.raw);
        for (self.symbols.items, 0..) |s, i| {
            if (s.equalsRaw(sym)) return &self.values.items[i];
        }
        return null;
    }

    pub fn assign(self: *Frame, sym: Value, val: Value) bool {
        std.debug.assert(sym.isSymbol());
        if (self.map) |*m| {
            if (m.getPtr(sym.raw)) |slot| {
                slot.* = val;
                return true;
            }
            return false;
        }
        for (self.symbols.items, 0..) |s, i| {
            if (s.equalsRaw(sym)) {
                self.values.items[i] = val;
                return true;
            }
        }
        return false;
    }

    pub fn isHashed(self: *const Frame) bool {
        return self.map != null;
    }
};

pub const Env = struct {
    allocator: std.mem.Allocator,
    top_value: ?*Frame = null,
    top_function: ?*Frame = null,
    /// Frames a closure captured. They outlive the scope that pushed them,
    /// so the env owns them until it is torn down. Every other frame is
    /// freed when its scope pops it.
    captured_frames: std.ArrayList(*Frame) = .empty,
    /// Chains a call in flight set aside while it runs. They are not
    /// reachable from `top_value` or `top_function` for as long as the
    /// call lasts, so a root scan reads them from here.
    saved_chains: std.ArrayList(?*Frame) = .empty,
    /// Frames whose scope ended, linked through `parent`, kept with the
    /// capacity their binding lists grew to so the next scope reuses them.
    free_frames: ?*Frame = null,
    /// Where every frame and its bindings live. A frame is never freed on
    /// its own: one whose scope ends goes back on `free_frames`, and one a
    /// closure captured lasts as long as the env.
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{ .allocator = allocator, .frame_arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Env) void {
        self.captured_frames.deinit(self.allocator);
        self.saved_chains.deinit(self.allocator);
        self.frame_arena.deinit();
        self.free_frames = null;
        self.top_value = null;
        self.top_function = null;
    }

    /// What a frame's bindings are allocated from.
    pub fn frameAllocator(self: *Env) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    /// Set a chain aside for the duration of a call, and remember it
    /// where a root scan can find it.
    pub fn saveChains(self: *Env) !usize {
        const mark = self.saved_chains.items.len;
        try self.saved_chains.append(self.allocator, self.top_value);
        try self.saved_chains.append(self.allocator, self.top_function);
        return mark;
    }

    pub fn restoreChains(self: *Env, mark: usize) void {
        self.top_value = self.saved_chains.items[mark];
        self.top_function = self.saved_chains.items[mark + 1];
        self.saved_chains.shrinkRetainingCapacity(mark);
    }

    fn allocFrame(self: *Env, parent: ?*Frame) !*Frame {
        if (self.free_frames) |f| {
            self.free_frames = f.parent;
            f.parent = parent;
            return f;
        }
        const f = try self.frameAllocator().create(Frame);
        f.* = .{ .parent = parent };
        return f;
    }

    /// Give back a frame whose scope has ended, unless a closure captured
    /// it.
    pub fn releaseFrame(self: *Env, f: *Frame) void {
        if (f.captured) return;
        f.reset();
        f.parent = self.free_frames;
        self.free_frames = f;
    }

    /// Mark a chain as captured, stopping at the first frame already
    /// marked, since everything above it is marked too.
    pub fn retainChain(self: *Env, head: ?*Frame) !void {
        var current = head;
        while (current) |f| : (current = f.parent) {
            if (f.captured) return;
            try self.captured_frames.append(self.allocator, f);
            f.captured = true;
        }
    }

    /// Mark both current chains as captured, for a closure made here.
    pub fn captureCurrent(self: *Env) !void {
        try self.retainChain(self.top_value);
        try self.retainChain(self.top_function);
    }

    pub fn pushValueFrame(self: *Env) !*Frame {
        const f = try self.allocFrame(self.top_value);
        self.top_value = f;
        return f;
    }

    pub fn popValueFrame(self: *Env) void {
        const f = self.top_value orelse return;
        self.top_value = f.parent;
        self.releaseFrame(f);
    }

    pub fn pushFunctionFrame(self: *Env) !*Frame {
        const f = try self.allocFrame(self.top_function);
        self.top_function = f;
        return f;
    }

    pub fn popFunctionFrame(self: *Env) void {
        const f = self.top_function orelse return;
        self.top_function = f.parent;
        self.releaseFrame(f);
    }

    pub fn setValueChain(self: *Env, head: ?*Frame) ?*Frame {
        const prev = self.top_value;
        self.top_value = head;
        return prev;
    }

    pub fn setFunctionChain(self: *Env, head: ?*Frame) ?*Frame {
        const prev = self.top_function;
        self.top_function = head;
        return prev;
    }

    pub fn bindValue(self: *Env, sym: Value, val: Value) !void {
        if (self.top_value == null) _ = try self.pushValueFrame();
        try self.top_value.?.bind(self.frameAllocator(), sym, val);
    }

    pub fn bindFunction(self: *Env, sym: Value, val: Value) !void {
        if (self.top_function == null) _ = try self.pushFunctionFrame();
        try self.top_function.?.bind(self.frameAllocator(), sym, val);
    }

    pub fn lookupValue(self: *const Env, sym: Value) ?Value {
        std.debug.assert(sym.isSymbol());
        var cur = self.top_value;
        while (cur) |f| : (cur = f.parent) {
            if (f.find(sym)) |v| {
                if (v.equalsRaw(value.SPECIAL_DYNAMIC)) break;
                return v;
            }
        }
        const s = symbol_mod.symbol(sym);
        if (s.value_cell.equalsRaw(value.SPECIAL_UNBOUND)) return null;
        return s.value_cell;
    }

    pub fn lookupFunction(self: *const Env, sym: Value) ?Value {
        std.debug.assert(sym.isSymbol());
        var cur = self.top_function;
        while (cur) |f| : (cur = f.parent) {
            if (f.find(sym)) |v| return v;
        }
        const s = symbol_mod.symbol(sym);
        if (s.function_cell.equalsRaw(value.SPECIAL_UNBOUND)) return null;
        return s.function_cell;
    }

    pub fn assignValue(self: *Env, sym: Value, val: Value) void {
        std.debug.assert(sym.isSymbol());
        var cur = self.top_value;
        while (cur) |f| : (cur = f.parent) {
            if (f.slotFor(sym)) |slot| {
                if (slot.equalsRaw(value.SPECIAL_DYNAMIC)) break;
                slot.* = val;
                return;
            }
        }
        symbol_mod.symbol(sym).value_cell = val;
    }

    pub fn assignFunction(self: *Env, sym: Value, val: Value) void {
        std.debug.assert(sym.isSymbol());
        var cur = self.top_function;
        while (cur) |f| : (cur = f.parent) {
            if (f.assign(sym, val)) return;
        }
        symbol_mod.symbol(sym).function_cell = val;
    }

    pub fn defineGlobalValue(self: *const Env, sym: Value, val: Value) void {
        _ = self;
        std.debug.assert(sym.isSymbol());
        symbol_mod.symbol(sym).value_cell = val;
    }

    pub fn defineGlobalFunction(self: *const Env, sym: Value, val: Value) void {
        _ = self;
        std.debug.assert(sym.isSymbol());
        symbol_mod.symbol(sym).function_cell = val;
    }
};
