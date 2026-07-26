const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");

const Value = value.Value;

pub const Error = error{
    PackageExists,
    NoSuchPackage,
    SymbolConflict,
    NotPresent,
} || std.mem.Allocator.Error;

/// Where a name was found relative to the package it was looked up in.
pub const Status = enum { internal, external, inherited };

pub const Found = struct {
    sym: Value,
    status: Status,
};

/// A package maps names to symbols. `internal` and `external` are disjoint:
/// a present symbol lives in exactly one of them. `shadowing` records the
/// subset of present symbols that suppress inherited names of the same text.
pub const Package = struct {
    header: heap.HeapHeader,
    allocator: std.mem.Allocator,
    name: []const u8,
    nicknames: std.ArrayListUnmanaged([]const u8) = .empty,
    internal: std.StringHashMapUnmanaged(Value) = .empty,
    external: std.StringHashMapUnmanaged(Value) = .empty,
    shadowing: std.StringHashMapUnmanaged(Value) = .empty,
    use_list: std.ArrayListUnmanaged(*Package) = .empty,
    used_by: std.ArrayListUnmanaged(*Package) = .empty,
    deleted: bool = false,

    pub fn toValue(self: *Package) Value {
        return Value.fromHeapAddr(@intFromPtr(self));
    }

    pub fn deinit(self: *Package) void {
        self.nicknames.deinit(self.allocator);
        self.internal.deinit(self.allocator);
        self.external.deinit(self.allocator);
        self.shadowing.deinit(self.allocator);
        self.use_list.deinit(self.allocator);
        self.used_by.deinit(self.allocator);
    }

    /// Symbol present directly in this package, ignoring inheritance.
    pub fn findPresent(self: *Package, sym_name: []const u8) ?Found {
        if (self.external.get(sym_name)) |s| return .{ .sym = s, .status = .external };
        if (self.internal.get(sym_name)) |s| return .{ .sym = s, .status = .internal };
        return null;
    }

    /// Full CLHS lookup: present symbols win, then symbols inherited from
    /// the external lists of used packages.
    pub fn findSymbol(self: *Package, sym_name: []const u8) ?Found {
        if (self.findPresent(sym_name)) |f| return f;
        for (self.use_list.items) |used| {
            if (used.external.get(sym_name)) |s| return .{ .sym = s, .status = .inherited };
        }
        return null;
    }

    pub fn addInternal(self: *Package, sym_name: []const u8, sym: Value) !void {
        try self.internal.put(self.allocator, sym_name, sym);
    }

    pub fn addExternal(self: *Package, sym_name: []const u8, sym: Value) !void {
        try self.external.put(self.allocator, sym_name, sym);
    }

    pub fn removePresent(self: *Package, sym_name: []const u8) void {
        _ = self.internal.remove(sym_name);
        _ = self.external.remove(sym_name);
        _ = self.shadowing.remove(sym_name);
    }

    pub fn isShadowing(self: *Package, sym_name: []const u8) bool {
        return self.shadowing.contains(sym_name);
    }

    pub fn usesPackage(self: *Package, other: *Package) bool {
        for (self.use_list.items) |used| {
            if (used == other) return true;
        }
        return false;
    }

    pub fn addUse(self: *Package, other: *Package) !void {
        if (self.usesPackage(other)) return;
        try self.use_list.append(self.allocator, other);
        try other.used_by.append(self.allocator, self);
    }

    pub fn removeUse(self: *Package, other: *Package) void {
        removeFromList(&self.use_list, other);
        removeFromList(&other.used_by, self);
    }

    fn removeFromList(list: *std.ArrayListUnmanaged(*Package), target: *Package) void {
        var idx: usize = 0;
        while (idx < list.items.len) : (idx += 1) {
            if (list.items[idx] == target) {
                _ = list.orderedRemove(idx);
                return;
            }
        }
    }
};

pub fn asPackage(v: Value) *Package {
    return @ptrFromInt(v.toHeapAddr());
}

pub fn isPackage(v: Value) bool {
    return v.isHeap() and heap.heapType(v) == .package;
}

/// Owns every package and resolves names and nicknames to them.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Names and nicknames both map here.
    table: std.StringHashMapUnmanaged(*Package) = .empty,
    list: std.ArrayListUnmanaged(*Package) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.list.items) |pkg| {
            pkg.deinit();
            self.allocator.destroy(pkg);
        }
        self.list.deinit(self.allocator);
        self.table.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Copy a name into registry-owned storage. Package and symbol names
    /// outlive the buffers callers read them from.
    pub fn dupeName(self: *Registry, text: []const u8) ![]const u8 {
        return try self.arena.allocator().dupe(u8, text);
    }

    pub fn find(self: *Registry, pkg_name: []const u8) ?*Package {
        return self.table.get(pkg_name);
    }

    pub fn create(self: *Registry, pkg_name: []const u8) Error!*Package {
        if (self.table.get(pkg_name) != null) return Error.PackageExists;
        const owned = try self.dupeName(pkg_name);
        const pkg = try self.allocator.create(Package);
        pkg.* = .{
            .header = .{ .type_tag = .package, .size = @sizeOf(Package) },
            .allocator = self.allocator,
            .name = owned,
        };
        try self.table.put(self.allocator, owned, pkg);
        try self.list.append(self.allocator, pkg);
        return pkg;
    }

    pub fn addNickname(self: *Registry, pkg: *Package, nick: []const u8) Error!void {
        if (self.table.get(nick)) |existing| {
            if (existing == pkg) return;
            return Error.PackageExists;
        }
        const owned = try self.dupeName(nick);
        try self.table.put(self.allocator, owned, pkg);
        try pkg.nicknames.append(self.allocator, owned);
    }

    /// Drops the package from name resolution and severs its use links. The
    /// object itself stays allocated so symbols keep a valid home pointer.
    pub fn delete(self: *Registry, pkg: *Package) void {
        _ = self.table.remove(pkg.name);
        for (pkg.nicknames.items) |nick| _ = self.table.remove(nick);
        while (pkg.use_list.items.len != 0) {
            pkg.removeUse(pkg.use_list.items[0]);
        }
        while (pkg.used_by.items.len != 0) {
            pkg.used_by.items[0].removeUse(pkg);
        }
        pkg.deleted = true;
    }
};
