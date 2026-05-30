const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

pub const Symbol = struct {
    name: []const u8,
    value_cell: Value,
    function_cell: Value,
    plist: Value,
    // package field to be added once packages exist
};

pub const Interner = struct {
    table: std.StringHashMap(*Symbol),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Interner {
        return .{
            .table = std.StringHashMap(*Symbol).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Interner) void {
        self.table.deinit();
        self.arena.deinit();
    }

    /// Returns the canonical Value for the symbol with this name. Allocates a
    /// fresh symbol the first time the name is seen. The name is copied; the
    /// caller does not need to keep the input alive.
    pub fn intern(self: *Interner, sym_name: []const u8) !Value {
        if (self.table.get(sym_name)) |sym| {
            return Value.fromSymbolAddr(@intFromPtr(sym));
        }

        const arena_alloc = self.arena.allocator();
        const name_copy = try arena_alloc.dupe(u8, sym_name);
        const sym = try arena_alloc.create(Symbol);
        sym.* = .{
            .name = name_copy,
            .value_cell = value.SPECIAL_UNBOUND,
            .function_cell = value.SPECIAL_UNBOUND,
            .plist = value.NIL,
        };
        try self.table.put(name_copy, sym);
        return Value.fromSymbolAddr(@intFromPtr(sym));
    }

    pub fn lookup(self: *Interner, sym_name: []const u8) ?Value {
        if (self.table.get(sym_name)) |sym| {
            return Value.fromSymbolAddr(@intFromPtr(sym));
        }
        return null;
    }

    pub fn count(self: *const Interner) u32 {
        return self.table.count();
    }
};

pub fn symbol(v: Value) *Symbol {
    return @ptrFromInt(v.toSymbolAddr());
}

pub fn name(v: Value) []const u8 {
    return symbol(v).name;
}

/// Pre-intern symbols every Lisp implementation needs at boot. Populates
/// `value.NIL` and `value.T` so identity checks work via raw equality.
pub fn initStandardSymbols(interner: *Interner) !void {
    value.NIL = try interner.intern("NIL");
    value.T = try interner.intern("T");

    // NIL and T are self-evaluating
    symbol(value.NIL).value_cell = value.NIL;
    symbol(value.T).value_cell = value.T;

    // Patch the plists of the bootstrap symbols — their first intern happened
    // before value.NIL was real, so they got fixnum-0 as plist by accident.
    symbol(value.NIL).plist = value.NIL;
    symbol(value.T).plist = value.NIL;

    // Lambda-list keywords and core special forms
    inline for (&[_][]const u8{
        "QUOTE",
        "QUASIQUOTE",
        "UNQUOTE",
        "UNQUOTE-SPLICING",
        "LAMBDA",
        "FUNCTION",
        "IF",
        "PROGN",
        "SETQ",
        "LET",
        "LET*",
        "&REST",
        "&OPTIONAL",
        "&KEY",
        "&BODY",
        "&AUX",
        "&WHOLE",
        "&ENVIRONMENT",
        "&ALLOW-OTHER-KEYS",
    }) |n| {
        _ = try interner.intern(n);
    }
}
