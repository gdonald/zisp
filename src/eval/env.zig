const std = @import("std");
const value = @import("../runtime/value.zig");
const symbol_mod = @import("../runtime/symbol.zig");

const Value = value.Value;

pub const HASH_THRESHOLD: usize = 16;

pub const Frame = struct {
    parent: ?*Frame = null,
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
    all_frames: std.ArrayList(*Frame) = .empty,

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Env) void {
        for (self.all_frames.items) |f| {
            f.deinit(self.allocator);
            self.allocator.destroy(f);
        }
        self.all_frames.deinit(self.allocator);
        self.top_value = null;
        self.top_function = null;
    }

    fn allocFrame(self: *Env, parent: ?*Frame) !*Frame {
        const f = try self.allocator.create(Frame);
        errdefer self.allocator.destroy(f);
        f.* = .{ .parent = parent };
        try self.all_frames.append(self.allocator, f);
        return f;
    }

    pub fn pushValueFrame(self: *Env) !*Frame {
        const f = try self.allocFrame(self.top_value);
        self.top_value = f;
        return f;
    }

    pub fn popValueFrame(self: *Env) void {
        const f = self.top_value orelse return;
        self.top_value = f.parent;
    }

    pub fn pushFunctionFrame(self: *Env) !*Frame {
        const f = try self.allocFrame(self.top_function);
        self.top_function = f;
        return f;
    }

    pub fn popFunctionFrame(self: *Env) void {
        const f = self.top_function orelse return;
        self.top_function = f.parent;
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
        try self.top_value.?.bind(self.allocator, sym, val);
    }

    pub fn bindFunction(self: *Env, sym: Value, val: Value) !void {
        if (self.top_function == null) _ = try self.pushFunctionFrame();
        try self.top_function.?.bind(self.allocator, sym, val);
    }

    pub fn lookupValue(self: *const Env, sym: Value) ?Value {
        std.debug.assert(sym.isSymbol());
        var cur = self.top_value;
        while (cur) |f| : (cur = f.parent) {
            if (f.find(sym)) |v| return v;
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
            if (f.assign(sym, val)) return;
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
