//! Pathnames, held as their six components.
//!
//! Only physical pathnames exist at this point. A namestring is parsed
//! into components on the way in and rendered from them on the way out,
//! so a pathname built by `make-pathname` is indistinguishable from one
//! that was parsed.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const pathname_mod = @import("../runtime/pathname.zig");
const equality = @import("../runtime/equality.zig");
const reader_mod = @import("../reader.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

/// A compiled file keeps its source's directory and name, with the fasl type.
pub const FASL_TYPE = "zfasl";

pub fn registerPathnames(ev: *Evaluator) !void {
    _ = try ev.defineNative("PATHNAME", &pathnameFn);
    _ = try ev.defineNative("PATHNAMEP", &pathnamepFn);
    _ = try ev.defineNative("MAKE-PATHNAME", &makePathnameFn);
    _ = try ev.defineNative("MERGE-PATHNAMES", &mergePathnamesFn);
    _ = try ev.defineNative("NAMESTRING", &namestringFn);
    _ = try ev.defineNative("FILE-NAMESTRING", &fileNamestringFn);
    _ = try ev.defineNative("DIRECTORY-NAMESTRING", &directoryNamestringFn);
    _ = try ev.defineNative("PATHNAME-HOST", componentFn(.host));
    _ = try ev.defineNative("PATHNAME-DEVICE", componentFn(.device));
    _ = try ev.defineNative("PATHNAME-DIRECTORY", componentFn(.directory));
    _ = try ev.defineNative("PATHNAME-NAME", componentFn(.name));
    _ = try ev.defineNative("PATHNAME-TYPE", componentFn(.type_));
    _ = try ev.defineNative("PATHNAME-VERSION", componentFn(.version));
    _ = try ev.defineNative("WILD-PATHNAME-P", &wildPathnamePFn);
    _ = try ev.defineNative("COMPILE-FILE-PATHNAME", &compileFilePathnameFn);
    function.asFunction(try ev.defineNative("PARSE-NAMESTRING", &parseNamestringFn))
        .preserves_values = true;
    _ = try ev.defineNative("LOGICAL-PATHNAME", &logicalPathnameFn);
    _ = try ev.defineNative("LOGICAL-PATHNAME-TRANSLATIONS", &logicalPathnameTranslationsFn);
    _ = try ev.defineNative("%SET-LOGICAL-PATHNAME-TRANSLATIONS", &setLogicalPathnameTranslationsFn);
    _ = try ev.defineNative("LOAD-LOGICAL-PATHNAME-TRANSLATIONS", &loadLogicalPathnameTranslationsFn);
    _ = try ev.defineNative("TRANSLATE-PATHNAME", &translatePathnameFn);
    _ = try ev.defineNative("TRANSLATE-LOGICAL-PATHNAME", &translateLogicalPathnameFn);

    // The component markers, interned before any source can create them
    // in another package.
    for ([_][]const u8{
        "ABSOLUTE", "RELATIVE", "WILD", "WILD-INFERIORS", "UP", "BACK", "NEWEST", "UNSPECIFIC",
    }) |n| {
        _ = try ev.interner.internKeyword(n);
    }
}

fn isString(v: Value) bool {
    return heap.isString(v);
}

fn keyword(ev: *Evaluator, name: []const u8) Error!Value {
    return ev.interner.internKeyword(name);
}

fn isKeyword(ev: *Evaluator, v: Value, name: []const u8) Error!bool {
    return v.equalsRaw(try keyword(ev, name));
}

// --- parsing ---

// --- rendering ---

/// The namestring a pathname's components spell.
pub const namestringOf = pathname_mod.namestringOf;

// --- constructors ---

fn emptyPathname() heap.Pathname {
    return .{
        .host = value.NIL,
        .device = value.NIL,
        .directory = value.NIL,
        .name = value.NIL,
        .type_ = value.NIL,
        .version = value.NIL,
    };
}

/// Any pathname designator as a pathname's components.
fn componentsOf(ev: *Evaluator, v: Value) Error!heap.Pathname {
    if (heap.isPathname(v)) {
        const p = heap.asPathname(v);
        return .{
            .host = p.host,
            .device = p.device,
            .directory = p.directory,
            .name = p.name,
            .type_ = p.type_,
            .version = p.version,
        };
    }
    if (isString(v)) {
        const text = try heap.stringUtf8Alloc(ev.heap.allocator, v);
        return parseText(ev, text);
    }
    return Error.TypeError;
}

/// A pathname from namestring text, for the callers that already hold
/// bytes rather than a Lisp string.
pub fn parsed(ev: *Evaluator, text: []const u8) Error!Value {
    return ev.heap.allocPathname(try parseText(ev, text));
}

fn pathnameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (heap.isPathname(args[0])) return args[0];
    return ev.heap.allocPathname(try componentsOf(ev, args[0]));
}

fn pathnamepFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return if (heap.isPathname(args[0])) value.T else value.NIL;
}

const ComponentName = enum { host, device, directory, name, type_, version };

fn componentFn(comptime which: ComponentName) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len != 1) return Error.WrongArgCount;
            const parts = try componentsOf(ev, args[0]);
            return switch (which) {
                .host => parts.host,
                .device => parts.device,
                .directory => parts.directory,
                .name => parts.name,
                .type_ => parts.type_,
                .version => parts.version,
            };
        }
    }.f;
}

const IGNORED_KEYS = [_][]const u8{"CASE"};

fn makePathnameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len % 2 != 0) return Error.ProgramError;

    var parts = emptyPathname();
    var given = std.EnumSet(ComponentName).initEmpty();
    var defaults: ?Value = null;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const key = args[i];
        const v = args[i + 1];
        if (try isKeyword(ev, key, "DIRECTORY")) {
            parts.directory = try normalizeDirectory(ev, v);
            given.insert(.directory);
        } else if (try isKeyword(ev, key, "NAME")) {
            parts.name = v;
            given.insert(.name);
        } else if (try isKeyword(ev, key, "TYPE")) {
            parts.type_ = v;
            given.insert(.type_);
        } else if (try isKeyword(ev, key, "VERSION")) {
            parts.version = v;
            given.insert(.version);
        } else if (try isKeyword(ev, key, "HOST")) {
            parts.host = v;
            given.insert(.host);
        } else if (try isKeyword(ev, key, "DEVICE")) {
            parts.device = v;
            given.insert(.device);
        } else if (try isKeyword(ev, key, "DEFAULTS")) {
            defaults = v;
        } else if (!isIgnoredKey(ev, key)) {
            return Error.ProgramError;
        }
    }

    try validate(ev, parts);

    // Anything not supplied comes from `:defaults`, which is where a
    // pathname is copied with one component changed.
    if (defaults) |d| {
        const base = try componentsOf(ev, d);
        if (!given.contains(.host)) parts.host = base.host;
        if (!given.contains(.device)) parts.device = base.device;
        if (!given.contains(.directory)) parts.directory = base.directory;
        if (!given.contains(.name)) parts.name = base.name;
        if (!given.contains(.type_)) parts.type_ = base.type_;
        if (!given.contains(.version)) parts.version = base.version;
    }
    return ev.heap.allocPathname(parts);
}

/// Reject a component the renderer could not spell. Checking here means
/// a pathname that exists can always produce a namestring.
fn validate(ev: *Evaluator, parts: heap.Pathname) Error!void {
    for ([_]Value{ parts.name, parts.type_ }) |c| {
        if (c.equalsRaw(value.NIL) or isString(c)) continue;
        if (try isKeyword(ev, c, "WILD")) continue;
        return Error.TypeError;
    }
    for ([_]Value{ parts.host, parts.device }) |c| {
        if (c.equalsRaw(value.NIL) or isString(c)) continue;
        if (try isKeyword(ev, c, "UNSPECIFIC") or try isKeyword(ev, c, "WILD")) continue;
        return Error.TypeError;
    }
    if (!parts.version.equalsRaw(value.NIL) and !parts.version.isFixnum()) {
        const ok = try isKeyword(ev, parts.version, "WILD") or
            try isKeyword(ev, parts.version, "NEWEST") or
            try isKeyword(ev, parts.version, "UNSPECIFIC");
        if (!ok) return Error.TypeError;
    }
    try validateDirectory(ev, parts.directory);
}

fn validateDirectory(ev: *Evaluator, dir: Value) Error!void {
    if (dir.equalsRaw(value.NIL)) return;
    if (!dir.isCons()) return Error.TypeError;
    const head = heap.car(dir);
    const rooted = try isKeyword(ev, head, "ABSOLUTE") or try isKeyword(ev, head, "RELATIVE");
    if (!rooted) return Error.TypeError;
    var rest = heap.cdr(dir);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const c = heap.car(rest);
        if (isString(c)) continue;
        if (!c.isSymbol()) return Error.TypeError;
        _ = pathname_mod.segmentText(symbol_mod.symbol(c).name) catch return Error.TypeError;
    }
    if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
}

/// A directory argument may be a list, or the shorthands `:wild` and a
/// bare string meaning a one-component absolute directory.
fn normalizeDirectory(ev: *Evaluator, v: Value) Error!Value {
    if (v.equalsRaw(value.NIL) or v.isCons()) return v;
    if (try isKeyword(ev, v, "WILD")) {
        const tail = try ev.heap.allocCons(try keyword(ev, "WILD-INFERIORS"), value.NIL);
        return ev.heap.allocCons(try keyword(ev, "ABSOLUTE"), tail);
    }
    if (isString(v)) {
        const tail = try ev.heap.allocCons(v, value.NIL);
        return ev.heap.allocCons(try keyword(ev, "ABSOLUTE"), tail);
    }
    return Error.TypeError;
}

fn isIgnoredKey(ev: *Evaluator, key: Value) bool {
    for (IGNORED_KEYS) |k| {
        if (isKeyword(ev, key, k) catch false) return true;
    }
    return false;
}

// --- namestrings ---

fn namestringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const text = try namestringOf(ev.heap.allocator, args[0]);
    return ev.heap.allocString(text);
}

fn fileNamestringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const parts = try componentsOf(ev, args[0]);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const allocator = ev.heap.allocator;
    try pathname_mod.renderComponent(allocator, parts.name, &out);
    if (!parts.type_.equalsRaw(value.NIL)) {
        try out.append(allocator, '.');
        try pathname_mod.renderComponent(allocator, parts.type_, &out);
    }
    return ev.heap.allocString(out.items);
}

fn directoryNamestringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const parts = try componentsOf(ev, args[0]);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try pathname_mod.renderDirectory(ev.heap.allocator, parts.directory, &out);
    return ev.heap.allocString(out.items);
}

/// `(parse-namestring thing)` returns the pathname and the index just past
/// the text it consumed.
fn parseNamestringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 3) return Error.WrongArgCount;
    if (heap.isPathname(args[0])) {
        return ev.setValues(&.{ args[0], Value.fromFixnum(0) });
    }
    if (!isString(args[0])) return Error.TypeError;
    const text = try heap.stringUtf8Alloc(ev.heap.allocator, args[0]);
    const result = try ev.heap.allocPathname(try parseText(ev, text));
    return ev.setValues(&.{
        result,
        Value.fromFixnum(@intCast(heap.asString(args[0]).constSlice().len)),
    });
}

fn wildPathnamePFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const parts = try componentsOf(ev, args[0]);
    for ([_]Value{ parts.name, parts.type_, parts.version, parts.host, parts.device }) |c| {
        if (try isKeyword(ev, c, "WILD")) return value.T;
    }
    var rest = parts.directory;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const c = heap.car(rest);
        if (try isKeyword(ev, c, "WILD") or try isKeyword(ev, c, "WILD-INFERIORS")) return value.T;
    }
    return value.NIL;
}

// --- merging ---

/// CLHS 19.2.2.4: each component of `pathname` that is nil is filled in
/// from `defaults`, a relative directory is appended to the default's, and
/// the version falls back to `default-version` unless the name came from
/// the defaults too.
fn mergePathnamesFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 3) return Error.WrongArgCount;
    var parts = try componentsOf(ev, args[0]);
    const defaults = if (args.len >= 2)
        try componentsOf(ev, args[1])
    else
        emptyPathname();
    const default_version = if (args.len == 3) args[2] else try keyword(ev, "NEWEST");

    if (parts.host.equalsRaw(value.NIL)) parts.host = defaults.host;
    if (parts.device.equalsRaw(value.NIL)) parts.device = defaults.device;
    parts.directory = try mergedDirectory(ev, parts.directory, defaults.directory);

    const name_was_supplied = !parts.name.equalsRaw(value.NIL);
    if (!name_was_supplied) parts.name = defaults.name;
    if (parts.type_.equalsRaw(value.NIL)) parts.type_ = defaults.type_;
    if (parts.version.equalsRaw(value.NIL)) {
        parts.version = if (name_was_supplied) default_version else defaults.version;
    }
    return ev.heap.allocPathname(parts);
}

/// A relative directory extends the default's; an absolute one replaces
/// it. A `:back` at the join point cancels the last default component.
fn mergedDirectory(ev: *Evaluator, dir: Value, default_dir: Value) Error!Value {
    if (dir.equalsRaw(value.NIL)) return default_dir;
    if (default_dir.equalsRaw(value.NIL)) return dir;
    if (!dir.isCons()) return Error.TypeError;
    if (!try isKeyword(ev, heap.car(dir), "RELATIVE")) return dir;

    var prefix: std.ArrayList(Value) = .empty;
    defer prefix.deinit(ev.allocator);
    var rest = default_dir;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try prefix.append(ev.allocator, heap.car(rest));
    }

    var tail = heap.cdr(dir);
    // `:back` means "drop the component before me", so it cancels against
    // the tail of the default's directory rather than being kept.
    while (tail.isCons() and try isKeyword(ev, heap.car(tail), "BACK") and prefix.items.len > 1) {
        _ = prefix.pop();
        tail = heap.cdr(tail);
    }

    var i: usize = prefix.items.len;
    while (i > 0) {
        i -= 1;
        tail = try ev.heap.allocCons(prefix.items[i], tail);
    }
    return tail;
}

// --- compiled files ---

/// `dir/name.zfasl` for any source namestring, whatever its own type.
pub fn faslPathOf(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cut = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    const file = path[cut..];
    const stem = if (std.mem.lastIndexOfScalar(u8, file, '.')) |dot|
        (if (dot > 0) file[0..dot] else file)
    else
        file;
    return std.fmt.allocPrint(allocator, "{s}{s}.{s}", .{ path[0..cut], stem, FASL_TYPE });
}

fn compileFilePathnameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    var parts = try componentsOf(ev, args[0]);
    parts.type_ = try ev.heap.allocString(FASL_TYPE);
    return ev.heap.allocPathname(parts);
}

// --- logical pathnames ---

/// The host part of a logical namestring, or null when the text names no
/// host at all. A host is only a logical host once it has translations.
fn logicalHostOf(text: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    if (colon == 0) return null;
    for (text[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    return text[0..colon];
}

fn upcased(ev: *Evaluator, text: []const u8) Error![]u8 {
    const out = try ev.heap.allocator.alloc(u8, text.len);
    for (text, out) |c, *o| o.* = std.ascii.toUpper(c);
    return out;
}

/// Parse text as a logical pathname when it names a defined logical host,
/// and as a physical one otherwise.
pub fn parseText(ev: *Evaluator, text: []const u8) Error!heap.Pathname {
    if (logicalHostOf(text)) |host| {
        const key = try upcased(ev, host);
        if (ev.logical_hosts.contains(key)) {
            return pathname_mod.parseLogical(ev.heap, ev.interner, key, text[host.len + 1 ..]);
        }
    }
    return pathname_mod.parse(ev.heap, ev.interner, text);
}

fn hostKeyOf(ev: *Evaluator, v: Value) Error![]u8 {
    if (heap.isString(v)) {
        return upcased(ev, try heap.stringUtf8Alloc(ev.heap.allocator, v));
    }
    if (v.isSymbol()) return upcased(ev, symbol_mod.symbol(v).name);
    return Error.TypeError;
}

fn logicalPathnameTranslationsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const key = try hostKeyOf(ev, args[0]);
    return ev.logical_hosts.get(key) orelse Error.FileError;
}

fn setLogicalPathnameTranslationsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const key = try hostKeyOf(ev, args[0]);
    if (!args[1].isCons() and !args[1].equalsRaw(value.NIL)) return Error.TypeError;
    // Defining the host is what makes namestrings with that prefix
    // logical, so the entry goes in before anything is parsed.
    const slot = try ev.logical_hosts.getOrPut(ev.allocator, key);
    if (!slot.found_existing) {
        slot.key_ptr.* = try ev.allocator.dupe(u8, key);
    }
    slot.value_ptr.* = args[1];
    return args[1];
}

/// `(logical-pathname thing)` insists on a logical pathname, so the host
/// must already have translations.
fn logicalPathnameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (heap.isPathname(args[0])) {
        if (!heap.asPathname(args[0]).is_logical) return Error.TypeError;
        return args[0];
    }
    if (!heap.isString(args[0])) return Error.TypeError;
    const text = try heap.stringUtf8Alloc(ev.heap.allocator, args[0]);
    const parts = try parseText(ev, text);
    if (!parts.is_logical) return Error.FileError;
    return ev.heap.allocPathname(parts);
}

/// `(load-logical-pathname-translations host)` returns nil when the host
/// is already defined, and otherwise reads `<host>.translations`, whose
/// contents are the translation list.
fn loadLogicalPathnameTranslationsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const key = try hostKeyOf(ev, args[0]);
    if (ev.logical_hosts.contains(key)) return value.NIL;

    const path = try std.fmt.allocPrint(ev.heap.allocator, "{s}.translations", .{key});
    const source = readFile(ev, path) catch return Error.FileError;
    const translations = try readOneForm(ev, source);
    _ = try setLogicalPathnameTranslationsFn(p, &.{ args[0], translations });
    return value.T;
}

fn readFile(ev: *Evaluator, path: []const u8) ![]u8 {
    const io = ev.io orelse return error.FileError;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var contents: std.ArrayList(u8) = .empty;
    try file_reader.interface.appendRemainingUnlimited(ev.heap.allocator, &contents);
    return contents.items;
}

fn readOneForm(ev: *Evaluator, source: []const u8) Error!Value {
    var tokenizer = reader_mod.Tokenizer.init(source);
    var rd = reader_mod.Reader.init(&tokenizer, ev.heap, ev.interner);
    const form = rd.read() catch return Error.ProgramError;
    return form orelse Error.ProgramError;
}

// --- wildcard matching and substitution ---

/// What a pattern's wildcards matched. The directory run is positional,
/// so it keeps a list; the name and type each have at most one wildcard,
/// so a single slot each is enough. Keeping them apart matters: a
/// replacement that spells one component literally must not shift the
/// wildcards of the others along.
const Captures = struct {
    directory: std.ArrayList(Value) = .empty,
    directory_next: usize = 0,
    name: ?Value = null,
    type_: ?Value = null,

    fn deinit(self: *Captures, ev: *Evaluator) void {
        self.directory.deinit(ev.allocator);
    }

    fn takeDirectory(self: *Captures) ?Value {
        if (self.directory_next >= self.directory.items.len) return null;
        const v = self.directory.items[self.directory_next];
        self.directory_next += 1;
        return v;
    }
};

fn isWild(ev: *Evaluator, v: Value) Error!bool {
    return isKeyword(ev, v, "WILD");
}

/// Match one name-like component against a pattern, recording what a
/// wildcard swallowed.
fn matchComponent(ev: *Evaluator, pattern: Value, source: Value, slot: *?Value) Error!bool {
    if (try isWild(ev, pattern)) {
        slot.* = source;
        return true;
    }
    if (pattern.equalsRaw(value.NIL)) return source.equalsRaw(value.NIL);
    return equality.equal(pattern, source);
}

/// Match a directory list, where `:wild-inferiors` stands for any number
/// of components and `:wild` for exactly one.
fn matchDirectory(ev: *Evaluator, pattern: Value, source: Value, caps: *Captures) Error!bool {
    var pattern_items: std.ArrayList(Value) = .empty;
    defer pattern_items.deinit(ev.allocator);
    var source_items: std.ArrayList(Value) = .empty;
    defer source_items.deinit(ev.allocator);
    try collect(ev, pattern, &pattern_items);
    try collect(ev, source, &source_items);
    if (pattern_items.items.len == 0) return source_items.items.len == 0;
    if (source_items.items.len == 0) return false;
    // The :absolute or :relative head has to agree before the rest can.
    if (!equality.equal(pattern_items.items[0], source_items.items[0])) return false;
    return matchSegments(ev, pattern_items.items[1..], source_items.items[1..], caps);
}

fn collect(ev: *Evaluator, list: Value, out: *std.ArrayList(Value)) Error!void {
    var rest = list;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try out.append(ev.allocator, heap.car(rest));
    }
}

fn matchSegments(ev: *Evaluator, pattern: []const Value, source: []const Value, caps: *Captures) Error!bool {
    if (pattern.len == 0) return source.len == 0;
    if (try isKeyword(ev, pattern[0], "WILD-INFERIORS")) {
        // Take the shortest run that lets the rest of the pattern match.
        var taken: usize = 0;
        while (taken <= source.len) : (taken += 1) {
            const mark = caps.directory.items.len;
            try caps.directory.append(ev.allocator, try listOf(ev, source[0..taken]));
            if (try matchSegments(ev, pattern[1..], source[taken..], caps)) return true;
            caps.directory.shrinkRetainingCapacity(mark);
        }
        return false;
    }
    if (source.len == 0) return false;
    if (try isWild(ev, pattern[0])) {
        try caps.directory.append(ev.allocator, source[0]);
    } else if (!equality.equal(pattern[0], source[0])) {
        return false;
    }
    return matchSegments(ev, pattern[1..], source[1..], caps);
}

fn listOf(ev: *Evaluator, items: []const Value) Error!Value {
    var list = value.NIL;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(items[i], list);
    }
    return list;
}

fn substituteComponent(ev: *Evaluator, pattern: Value, captured: ?Value) Error!Value {
    if (try isWild(ev, pattern)) return captured orelse value.NIL;
    return pattern;
}

fn substituteDirectory(ev: *Evaluator, pattern: Value, caps: *Captures) Error!Value {
    if (!pattern.isCons()) return pattern;
    var out: std.ArrayList(Value) = .empty;
    defer out.deinit(ev.allocator);
    try out.append(ev.allocator, heap.car(pattern));

    var rest = heap.cdr(pattern);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const c = heap.car(rest);
        if (try isKeyword(ev, c, "WILD-INFERIORS")) {
            var run = caps.takeDirectory() orelse value.NIL;
            while (run.isCons()) : (run = heap.cdr(run)) {
                try out.append(ev.allocator, heap.car(run));
            }
            continue;
        }
        if (try isWild(ev, c)) {
            try out.append(ev.allocator, caps.takeDirectory() orelse value.NIL);
            continue;
        }
        try out.append(ev.allocator, c);
    }
    return listOf(ev, out.items);
}

/// `(translate-pathname source from to)`: match `source` against `from`,
/// then fill `to`'s wildcards with what matched.
fn translatePathnameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 3) return Error.WrongArgCount;
    return (try translate(ev, args[0], args[1], args[2])) orelse Error.FileError;
}

fn translate(ev: *Evaluator, source_v: Value, from_v: Value, to_v: Value) Error!?Value {
    const source = try componentsOf(ev, source_v);
    const from = try componentsOf(ev, from_v);
    const to = try componentsOf(ev, to_v);

    var caps = Captures{};
    defer caps.deinit(ev);
    if (!try matchDirectory(ev, from.directory, source.directory, &caps)) return null;
    if (!try matchComponent(ev, from.name, source.name, &caps.name)) return null;
    if (!try matchComponent(ev, from.type_, source.type_, &caps.type_)) return null;

    var parts = emptyPathname();
    parts.host = to.host;
    parts.device = to.device;
    parts.is_logical = to.is_logical;
    parts.directory = try substituteDirectory(ev, to.directory, &caps);
    parts.name = try substituteComponent(ev, to.name, caps.name);
    parts.type_ = try substituteComponent(ev, to.type_, caps.type_);
    parts.version = if (try isWild(ev, to.version)) source.version else to.version;
    return try ev.heap.allocPathname(parts);
}

/// Apply a host's translations until the pathname is no longer logical.
fn translateLogicalPathnameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1) return Error.WrongArgCount;
    var current = if (heap.isPathname(args[0]))
        args[0]
    else
        try ev.heap.allocPathname(try componentsOf(ev, args[0]));

    // A translation may itself be logical, so keep going until it is not.
    // The bound stops a rule set that translates in a circle.
    var rounds: usize = 0;
    while (heap.asPathname(current).is_logical and rounds < 64) : (rounds += 1) {
        const key = try hostKeyOf(ev, heap.asPathname(current).host);
        const rules = ev.logical_hosts.get(key) orelse return Error.FileError;
        current = (try applyRules(ev, current, rules)) orelse return Error.FileError;
    }
    return current;
}

fn applyRules(ev: *Evaluator, source: Value, rules: Value) Error!?Value {
    var rest = rules;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        const rule = heap.car(rest);
        if (!rule.isCons() or !heap.cdr(rule).isCons()) return Error.TypeError;
        const from = try asRulePathname(ev, heap.car(rule), true);
        const to = try asRulePathname(ev, heap.car(heap.cdr(rule)), false);
        if (try translate(ev, source, from, to)) |result| return result;
    }
    return null;
}

/// A rule's two halves are namestrings. The left one is read in the
/// logical syntax, since it matches against a logical pathname.
fn asRulePathname(ev: *Evaluator, v: Value, logical: bool) Error!Value {
    if (heap.isPathname(v)) return v;
    if (!heap.isString(v)) return Error.TypeError;
    const text = try heap.stringUtf8Alloc(ev.heap.allocator, v);
    if (logical) {
        if (logicalHostOf(text)) |host| {
            const key = try upcased(ev, host);
            const parts = try pathname_mod.parseLogical(ev.heap, ev.interner, key, text[host.len + 1 ..]);
            return ev.heap.allocPathname(parts);
        }
    }
    return ev.heap.allocPathname(try pathname_mod.parse(ev.heap, ev.interner, text));
}
