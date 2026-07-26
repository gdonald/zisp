//! Package builtins: creation, lookup, symbol movement, and iteration.
//! The package objects themselves live in `runtime/package.zig`; this
//! module is the Lisp-visible surface over them.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const package_mod = @import("../runtime/package.zig");
const eval_mod = @import("../eval/eval.zig");
const special_forms = @import("../eval/special_forms.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Package = package_mod.Package;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

fn boolv(b: bool) Value {
    return if (b) value.T else value.NIL;
}

pub fn registerPackages(ev: *Evaluator) !void {
    _ = try ev.defineNative("MAKE-PACKAGE", &makePackageFn);
    _ = try ev.defineNative("FIND-PACKAGE", &findPackageFn);
    _ = try ev.defineNative("DELETE-PACKAGE", &deletePackageFn);
    _ = try ev.defineNative("PACKAGE-NAME", &packageNameFn);
    _ = try ev.defineNative("PACKAGE-NICKNAMES", &packageNicknamesFn);
    _ = try ev.defineNative("PACKAGE-USE-LIST", &packageUseListFn);
    _ = try ev.defineNative("PACKAGE-USED-BY-LIST", &packageUsedByListFn);
    _ = try ev.defineNative("PACKAGE-SHADOWING-SYMBOLS", &packageShadowingFn);
    _ = try ev.defineNative("LIST-ALL-PACKAGES", &listAllPackagesFn);
    _ = try ev.defineNative("PACKAGEP", &packagepFn);
    _ = try ev.defineNative("INTERN", &internFn);
    _ = try ev.defineNative("FIND-SYMBOL", &findSymbolFn);
    _ = try ev.defineNative("UNINTERN", &uninternFn);
    _ = try ev.defineNative("EXPORT", &exportFn);
    _ = try ev.defineNative("UNEXPORT", &unexportFn);
    _ = try ev.defineNative("IMPORT", &importFn);
    _ = try ev.defineNative("SHADOW", &shadowFn);
    _ = try ev.defineNative("SHADOWING-IMPORT", &shadowingImportFn);
    _ = try ev.defineNative("USE-PACKAGE", &usePackageFn);
    _ = try ev.defineNative("UNUSE-PACKAGE", &unusePackageFn);
    _ = try ev.defineNative("SYMBOL-PACKAGE", &symbolPackageFn);
    _ = try ev.defineNative("KEYWORDP", &keywordpFn);
    _ = try ev.defineNative("MAKE-SYMBOL", &makeSymbolFn);
    _ = try ev.defineNative("SYMBOL-NAME", &symbolNameFn);
    _ = try ev.defineNative("%PACKAGE-SYMBOLS", &packageSymbolsFn);

    function.asFunction(ev.env.lookupFunction(try ev.interner.intern("INTERN")).?).preserves_values = true;
    function.asFunction(ev.env.lookupFunction(try ev.interner.intern("FIND-SYMBOL")).?).preserves_values = true;
}

/// Package argument, defaulting to `*package*` when absent.
fn packageArg(ev: *Evaluator, args: []const Value, idx: usize) Error!*Package {
    if (idx >= args.len) return ev.interner.currentPackage();
    return special_forms.resolvePackage(ev, args[idx]);
}

fn listOfValues(ev: *Evaluator, items: []const Value) Error!Value {
    var list = value.NIL;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(items[i], list);
    }
    return list;
}

// --- creation and lookup ---

fn makePackageFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len == 0 or (args.len - 1) % 2 != 0) return Error.WrongArgCount;
    const name = try special_forms.stringDesignator(args[0]);
    if (ev.interner.registry.find(name) != null) return Error.PackageError;

    const nicknames_kw = try ev.interner.internKeyword("NICKNAMES");
    const use_kw = try ev.interner.internKeyword("USE");
    var nicknames = value.NIL;
    var use_list = value.NIL;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (args[i].equalsRaw(nicknames_kw)) {
            nicknames = args[i + 1];
        } else if (args[i].equalsRaw(use_kw)) {
            use_list = args[i + 1];
        } else return Error.ProgramError;
    }

    const pkg = ev.interner.registry.create(name) catch return Error.PackageError;
    var nick = nicknames;
    while (nick.isCons()) : (nick = heap.cdr(nick)) {
        const text = try special_forms.stringDesignator(heap.car(nick));
        ev.interner.registry.addNickname(pkg, text) catch return Error.PackageError;
    }
    var used = use_list;
    while (used.isCons()) : (used = heap.cdr(used)) {
        try pkg.addUse(try special_forms.resolvePackage(ev, heap.car(used)));
    }
    return pkg.toValue();
}

fn findPackageFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (package_mod.isPackage(args[0])) return args[0];
    const name = try special_forms.stringDesignator(args[0]);
    const pkg = ev.interner.registry.find(name) orelse return value.NIL;
    return pkg.toValue();
}

fn deletePackageFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!package_mod.isPackage(args[0])) {
        const name = try special_forms.stringDesignator(args[0]);
        if (ev.interner.registry.find(name) == null) return value.NIL;
    }
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    if (pkg.deleted) return value.NIL;
    ev.interner.registry.delete(pkg);
    return value.T;
}

fn packageNameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    if (pkg.deleted) return value.NIL;
    return ev.heap.allocString(pkg.name);
}

fn packageNicknamesFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    var list = value.NIL;
    var i = pkg.nicknames.items.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(try ev.heap.allocString(pkg.nicknames.items[i]), list);
    }
    return list;
}

fn packageUseListFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    return packageListToValue(ev, pkg.use_list.items);
}

fn packageUsedByListFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    return packageListToValue(ev, pkg.used_by.items);
}

fn packageListToValue(ev: *Evaluator, packages: []const *Package) Error!Value {
    var list = value.NIL;
    var i = packages.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(packages[i].toValue(), list);
    }
    return list;
}

fn packageShadowingFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    var list = value.NIL;
    var it = pkg.shadowing.valueIterator();
    while (it.next()) |sym| list = try ev.heap.allocCons(sym.*, list);
    return list;
}

fn listAllPackagesFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 0) return Error.WrongArgCount;
    var list = value.NIL;
    var i = ev.interner.registry.list.items.len;
    while (i > 0) {
        i -= 1;
        const pkg = ev.interner.registry.list.items[i];
        if (pkg.deleted) continue;
        list = try ev.heap.allocCons(pkg.toValue(), list);
    }
    return list;
}

fn packagepFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(package_mod.isPackage(args[0]));
}

// --- symbols ---

fn statusKeyword(ev: *Evaluator, status: package_mod.Status) Error!Value {
    return switch (status) {
        .internal => ev.interner.internKeyword("INTERNAL"),
        .external => ev.interner.internKeyword("EXTERNAL"),
        .inherited => ev.interner.internKeyword("INHERITED"),
    };
}

fn internFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const name = try special_forms.stringDesignator(args[0]);
    const pkg = try packageArg(ev, args, 1);
    if (pkg.findSymbol(name)) |found| {
        _ = try ev.setValues(&.{ found.sym, try statusKeyword(ev, found.status) });
        return found.sym;
    }
    const sym = try ev.interner.internIn(pkg, name);
    _ = try ev.setValues(&.{ sym, value.NIL });
    return sym;
}

fn findSymbolFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const name = try special_forms.stringDesignator(args[0]);
    const pkg = try packageArg(ev, args, 1);
    if (pkg.findSymbol(name)) |found| {
        _ = try ev.setValues(&.{ found.sym, try statusKeyword(ev, found.status) });
        return found.sym;
    }
    _ = try ev.setValues(&.{ value.NIL, value.NIL });
    return value.NIL;
}

fn uninternFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const pkg = try packageArg(ev, args, 1);
    const name = symbol_mod.symbol(args[0]).name;
    const present = pkg.findPresent(name) orelse return value.NIL;
    if (!present.sym.equalsRaw(args[0])) return value.NIL;
    pkg.removePresent(name);
    if (symbol_mod.symbol(args[0]).home == pkg) symbol_mod.symbol(args[0]).home = null;
    return value.T;
}

/// Apply `body` to every symbol in a symbol-or-list designator.
fn forEachSymbol(
    args: []const Value,
    context: anytype,
    body: *const fn (@TypeOf(context), Value) Error!void,
) Error!void {
    const designator = args[0];
    if (designator.isSymbol() and !designator.equalsRaw(value.NIL)) {
        return body(context, designator);
    }
    var rest = designator;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const sym = heap.car(rest);
        if (!sym.isSymbol()) return Error.TypeError;
        try body(context, sym);
    }
}

const PackageOp = struct { ev: *Evaluator, pkg: *Package };

fn exportOne(ctx: PackageOp, sym: Value) Error!void {
    const name = symbol_mod.symbol(sym).name;
    const present = ctx.pkg.findPresent(name);
    if (present == null or !present.?.sym.equalsRaw(sym)) {
        // Exporting a symbol the package only inherits makes it present.
        try ctx.pkg.addInternal(name, sym);
    }
    if (ctx.pkg.external.contains(name)) return;
    _ = ctx.pkg.internal.remove(name);
    try ctx.pkg.addExternal(name, sym);
}

fn exportFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const ctx = PackageOp{ .ev = ev, .pkg = try packageArg(ev, args, 1) };
    try forEachSymbol(args, ctx, &exportOne);
    return value.T;
}

fn unexportOne(ctx: PackageOp, sym: Value) Error!void {
    const name = symbol_mod.symbol(sym).name;
    if (!ctx.pkg.external.contains(name)) return;
    _ = ctx.pkg.external.remove(name);
    try ctx.pkg.addInternal(name, sym);
}

fn unexportFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const ctx = PackageOp{ .ev = ev, .pkg = try packageArg(ev, args, 1) };
    try forEachSymbol(args, ctx, &unexportOne);
    return value.T;
}

fn importOne(ctx: PackageOp, sym: Value) Error!void {
    const name = symbol_mod.symbol(sym).name;
    if (ctx.pkg.findPresent(name)) |found| {
        if (found.sym.equalsRaw(sym)) return;
        return Error.PackageError;
    }
    try ctx.pkg.addInternal(name, sym);
    if (symbol_mod.symbol(sym).home == null) symbol_mod.symbol(sym).home = ctx.pkg;
}

fn importFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const ctx = PackageOp{ .ev = ev, .pkg = try packageArg(ev, args, 1) };
    try forEachSymbol(args, ctx, &importOne);
    return value.T;
}

fn shadowingImportOne(ctx: PackageOp, sym: Value) Error!void {
    const name = symbol_mod.symbol(sym).name;
    ctx.pkg.removePresent(name);
    try ctx.pkg.addInternal(name, sym);
    try ctx.pkg.shadowing.put(ctx.pkg.allocator, name, sym);
}

fn shadowingImportFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const ctx = PackageOp{ .ev = ev, .pkg = try packageArg(ev, args, 1) };
    try forEachSymbol(args, ctx, &shadowingImportOne);
    return value.T;
}

fn shadowFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const pkg = try packageArg(ev, args, 1);

    const designator = args[0];
    if (designator.isCons() or designator.equalsRaw(value.NIL)) {
        var rest = designator;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            try shadowName(ev, pkg, try special_forms.stringDesignator(heap.car(rest)));
        }
    } else {
        try shadowName(ev, pkg, try special_forms.stringDesignator(designator));
    }
    return value.T;
}

fn shadowName(ev: *Evaluator, pkg: *Package, name: []const u8) Error!void {
    const present = pkg.findPresent(name);
    const sym = if (present) |found| found.sym else try ev.interner.internLocal(pkg, name);
    try pkg.shadowing.put(pkg.allocator, symbol_mod.symbol(sym).name, sym);
}

fn usePackageFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const pkg = try packageArg(ev, args, 1);
    var rest = args[0];
    if (!rest.isCons() and !rest.equalsRaw(value.NIL)) {
        try pkg.addUse(try special_forms.resolvePackage(ev, rest));
        return value.T;
    }
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try pkg.addUse(try special_forms.resolvePackage(ev, heap.car(rest)));
    }
    return value.T;
}

fn unusePackageFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const pkg = try packageArg(ev, args, 1);
    var rest = args[0];
    if (!rest.isCons() and !rest.equalsRaw(value.NIL)) {
        pkg.removeUse(try special_forms.resolvePackage(ev, rest));
        return value.T;
    }
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        pkg.removeUse(try special_forms.resolvePackage(ev, heap.car(rest)));
    }
    return value.T;
}

fn symbolPackageFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    const home = symbol_mod.homePackage(args[0]) orelse return value.NIL;
    return home.toValue();
}

fn keywordpFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return boolv(args[0].isSymbol() and symbol_mod.isKeyword(args[0], ev.interner));
}

fn symbolNameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return Error.TypeError;
    return ev.heap.allocString(symbol_mod.symbol(args[0]).name);
}

fn makeSymbolFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    return ev.interner.makeUninterned(try special_forms.stringDesignator(args[0]));
}

/// `(%package-symbols pkg kind)` — the list backing `do-symbols` and its
/// siblings. `kind` selects `:internal`, `:external`, or `:inherited`.
fn packageSymbolsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const pkg = try special_forms.resolvePackage(ev, args[0]);
    const kind = try special_forms.stringDesignator(args[1]);

    var out: std.ArrayList(Value) = .empty;
    defer out.deinit(ev.allocator);
    if (std.mem.eql(u8, kind, "EXTERNAL") or std.mem.eql(u8, kind, "PRESENT")) {
        var it = pkg.external.valueIterator();
        while (it.next()) |sym| try out.append(ev.allocator, sym.*);
    }
    if (std.mem.eql(u8, kind, "INTERNAL") or std.mem.eql(u8, kind, "PRESENT")) {
        var it = pkg.internal.valueIterator();
        while (it.next()) |sym| try out.append(ev.allocator, sym.*);
    }
    if (std.mem.eql(u8, kind, "INHERITED")) {
        for (pkg.use_list.items) |used| {
            var it = used.external.iterator();
            while (it.next()) |entry| {
                if (pkg.findPresent(entry.key_ptr.*) != null) continue;
                try out.append(ev.allocator, entry.value_ptr.*);
            }
        }
    }
    return listOfValues(ev, out.items);
}
