const std = @import("std");
const value = @import("value.zig");
const package = @import("package.zig");
const heap = @import("heap.zig");
const Value = value.Value;
const Package = package.Package;

pub const Symbol = struct {
    name: []const u8,
    value_cell: Value,
    function_cell: Value,
    plist: Value,
    /// Home package, or null for an uninterned symbol.
    home: ?*Package = null,
    /// Set by `defvar`/`defparameter`/`declaim special`. Controls whether
    /// `let` binds the value cell dynamically or a lexical frame slot.
    special: bool = false,
    /// `defconstant` and keywords: the value cell may not be rebound.
    constant: bool = false,
};

pub const CL_PACKAGE_NAME = "COMMON-LISP";
pub const CL_USER_PACKAGE_NAME = "COMMON-LISP-USER";
pub const KEYWORD_PACKAGE_NAME = "KEYWORD";
/// Where what this implementation adds to the standard lives. Named as
/// CMUCL names it, since that is where the shape of these comes from.
pub const EXT_PACKAGE_NAME = "EXTENSIONS";

/// Narrow a registry result whose non-allocation failures are impossible
/// at the call site.
fn onlyAllocFailure(result: anytype) std.mem.Allocator.Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

pub const Interner = struct {
    arena: std.heap.ArenaAllocator,
    registry: package.Registry,
    cl: *Package = undefined,
    cl_user: *Package = undefined,
    ext: *Package = undefined,
    keyword: *Package = undefined,
    /// The `*PACKAGE*` symbol, once interned. Its value cell is the single
    /// source of truth for the current package, so a dynamic rebinding of
    /// `*package*` is visible to the reader immediately.
    package_symbol: Value = .{ .raw = 0 },

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Interner {
        var self: Interner = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .registry = package.Registry.init(allocator),
        };
        errdefer self.deinit();
        try self.initPackages();
        return self;
    }

    pub fn deinit(self: *Interner) void {
        self.registry.deinit();
        self.arena.deinit();
    }

    /// Create the three standard packages. Must run before any interning.
    /// A fresh registry cannot report a name clash, so the only failure
    /// mode left is allocation.
    pub fn initPackages(self: *Interner) std.mem.Allocator.Error!void {
        self.cl = try onlyAllocFailure(self.registry.create(CL_PACKAGE_NAME));
        try onlyAllocFailure(self.registry.addNickname(self.cl, "CL"));
        self.cl_user = try onlyAllocFailure(self.registry.create(CL_USER_PACKAGE_NAME));
        try onlyAllocFailure(self.registry.addNickname(self.cl_user, "CL-USER"));
        self.keyword = try onlyAllocFailure(self.registry.create(KEYWORD_PACKAGE_NAME));
        self.ext = try onlyAllocFailure(self.registry.create(EXT_PACKAGE_NAME));
        try onlyAllocFailure(self.registry.addNickname(self.ext, "EXT"));
        try self.cl_user.addUse(self.cl);
        try self.cl_user.addUse(self.ext);
    }

    pub fn currentPackage(self: *Interner) *Package {
        if (self.package_symbol.raw != 0) {
            const cell = symbol(self.package_symbol).value_cell;
            if (cell.isHeap() and package.isPackage(cell)) return package.asPackage(cell);
        }
        return self.cl_user;
    }

    pub fn setCurrentPackage(self: *Interner, pkg: *Package) void {
        symbol(self.package_symbol).value_cell = pkg.toValue();
    }

    fn allocSymbol(self: *Interner, sym_name: []const u8, home: ?*Package) !Value {
        const arena_alloc = self.arena.allocator();
        const name_copy = try arena_alloc.dupe(u8, sym_name);
        const sym = try arena_alloc.create(Symbol);
        sym.* = .{
            .name = name_copy,
            .value_cell = value.SPECIAL_UNBOUND,
            .function_cell = value.SPECIAL_UNBOUND,
            .plist = value.NIL,
            .home = home,
        };
        return Value.fromSymbolAddr(@intFromPtr(sym));
    }

    /// Intern into an explicit package, following CLHS inheritance rules:
    /// an accessible inherited symbol satisfies the request.
    pub fn internIn(self: *Interner, pkg: *Package, sym_name: []const u8) !Value {
        if (pkg.findSymbol(sym_name)) |found| return found.sym;
        return self.internLocal(pkg, sym_name);
    }

    /// Intern into an explicit package ignoring inheritance, so the result
    /// is always present in `pkg`. This is what `shadow` needs.
    pub fn internLocal(self: *Interner, pkg: *Package, sym_name: []const u8) !Value {
        if (pkg.findPresent(sym_name)) |found| return found.sym;
        const sym = try self.allocSymbol(sym_name, pkg);
        const owned = symbol(sym).name;
        if (pkg == self.keyword) {
            symbol(sym).value_cell = sym;
            symbol(sym).constant = true;
            try pkg.addExternal(owned, sym);
        } else {
            try pkg.addInternal(owned, sym);
        }
        return sym;
    }

    /// Intern a name this implementation adds to the standard, as an
    /// `EXTENSIONS` external symbol.
    pub fn internExtension(self: *Interner, sym_name: []const u8) !Value {
        const sym = try self.internLocal(self.ext, sym_name);
        const owned = symbol(sym).name;
        if (self.ext.findPresent(sym_name)) |found| {
            if (found.status == .internal) {
                _ = self.ext.internal.remove(owned);
                try self.ext.addExternal(owned, sym);
            }
        }
        return sym;
    }

    /// Intern a name the Zig side owns: a `COMMON-LISP` external symbol.
    /// Every builtin, special-form name, and lambda-list keyword lands here.
    pub fn intern(self: *Interner, sym_name: []const u8) !Value {
        if (self.cl.findPresent(sym_name)) |found| {
            if (found.status == .internal) {
                const owned_name = symbol(found.sym).name;
                _ = self.cl.internal.remove(owned_name);
                try self.cl.addExternal(owned_name, found.sym);
            }
            return found.sym;
        }
        const sym = try self.allocSymbol(sym_name, self.cl);
        try self.cl.addExternal(symbol(sym).name, sym);
        return sym;
    }

    pub fn internKeyword(self: *Interner, sym_name: []const u8) !Value {
        return self.internIn(self.keyword, sym_name);
    }

    /// Intern into whatever `*package*` currently names. This is what the
    /// reader does for an unqualified name.
    pub fn internCurrent(self: *Interner, sym_name: []const u8) !Value {
        return self.internIn(self.currentPackage(), sym_name);
    }

    /// Allocate a fresh symbol that is not entered in any package.
    /// Two uninterned symbols are never eq, even with equal names.
    pub fn makeUninterned(self: *Interner, sym_name: []const u8) !Value {
        return self.allocSymbol(sym_name, null);
    }

    /// Resolve a name the way an unqualified read would: through the
    /// current package and everything it uses.
    pub fn lookup(self: *Interner, sym_name: []const u8) ?Value {
        if (self.currentPackage().findSymbol(sym_name)) |found| return found.sym;
        return null;
    }

    /// Total symbols present across every live package.
    pub fn count(self: *const Interner) u32 {
        var total: u32 = 0;
        for (self.registry.list.items) |pkg| {
            total += pkg.internal.count() + pkg.external.count();
        }
        return total;
    }
};

pub fn symbol(v: Value) *Symbol {
    return @ptrFromInt(v.toSymbolAddr());
}

/// The value stored on a symbol's property list under `key`.
pub fn plistGet(sym: Value, key: Value) ?Value {
    var plist = symbol(sym).plist;
    while (plist.isCons()) {
        const rest = heap.cdr(plist);
        if (!rest.isCons()) return null;
        if (heap.car(plist).equalsRaw(key)) return heap.car(rest);
        plist = heap.cdr(rest);
    }
    return null;
}

/// Store `v` under `key`, replacing any value already there.
pub fn plistPut(h: *heap.Heap, sym: Value, key: Value, v: Value) !void {
    var plist = symbol(sym).plist;
    while (plist.isCons()) {
        const rest = heap.cdr(plist);
        if (!rest.isCons()) break;
        if (heap.car(plist).equalsRaw(key)) {
            heap.setCar(h, rest, v);
            return;
        }
        plist = heap.cdr(rest);
    }
    symbol(sym).plist = try h.listWithTail(&.{ key, v }, symbol(sym).plist);
}

pub fn name(v: Value) []const u8 {
    return symbol(v).name;
}

pub fn homePackage(v: Value) ?*Package {
    return symbol(v).home;
}

pub fn isKeyword(v: Value, interner: *const Interner) bool {
    return symbol(v).home == interner.keyword;
}

/// Pre-intern symbols every Lisp implementation needs at boot. Populates
/// `value.NIL` and `value.T` so identity checks work via raw equality.
pub fn initStandardSymbols(interner: *Interner) !void {
    value.NIL = try interner.intern("NIL");
    value.T = try interner.intern("T");

    // NIL and T are self-evaluating
    symbol(value.NIL).value_cell = value.NIL;
    symbol(value.T).value_cell = value.T;
    symbol(value.NIL).constant = true;
    symbol(value.T).constant = true;

    // Patch the plists of the bootstrap symbols — their first intern happened
    // before value.NIL was real, so they got fixnum-0 as plist by accident.
    symbol(value.NIL).plist = value.NIL;
    symbol(value.T).plist = value.NIL;

    interner.package_symbol = try interner.intern("*PACKAGE*");
    symbol(interner.package_symbol).special = true;
    interner.setCurrentPackage(interner.cl_user);

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
