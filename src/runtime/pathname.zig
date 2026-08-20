//! Parsing a namestring into pathname components.
//!
//! This is runtime rather than builtin because the reader needs it for
//! `#p"..."`, and the reader has no evaluator.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const symbol_mod = @import("symbol.zig");

const Value = value.Value;
const Heap = heap.Heap;
const Interner = symbol_mod.Interner;

/// Split a namestring into components. Unix syntax: `/` separates
/// directories, the last dot in the file part starts the type, and `*`
/// spells a wild component.
/// A logical namestring names its host before a colon and separates
/// directories with semicolons: `SYS:SRC;CODE;EVAL.LISP.NEWEST`.
pub fn parseLogical(h: *Heap, interner: *Interner, host: []const u8, text: []const u8) !heap.Pathname {
    // Each component is built in turn, and building the next one
    // allocates, so the ones already built are held meanwhile.
    var held = h.protect();
    defer held.close();
    var parts = heap.Pathname{
        .host = try h.allocString(host),
        .device = value.NIL,
        .directory = value.NIL,
        .name = value.NIL,
        .type_ = value.NIL,
        .version = value.NIL,
        .is_logical = true,
    };

    try held.push(parts.host);

    const cut = if (std.mem.lastIndexOfScalar(u8, text, ';')) |i| i + 1 else 0;
    parts.directory = try parseLogicalDirectory(h, interner, text[0..cut]);
    try held.push(parts.directory);

    // The file part is `name.type.version`, each optional.
    var pieces = std.mem.splitScalar(u8, text[cut..], '.');
    parts.name = try component(h, interner, pieces.next() orelse "");
    try held.push(parts.name);
    if (pieces.next()) |type_text| parts.type_ = try component(h, interner, type_text);
    try held.push(parts.type_);
    if (pieces.next()) |version_text| {
        parts.version = try logicalVersion(interner, version_text);
    }
    return parts;
}

fn logicalVersion(interner: *Interner, text: []const u8) !Value {
    if (text.len == 0) return value.NIL;
    if (std.mem.eql(u8, text, "*")) return interner.internKeyword("WILD");
    if (std.ascii.eqlIgnoreCase(text, "NEWEST")) return interner.internKeyword("NEWEST");
    const n = std.fmt.parseInt(i64, text, 10) catch return interner.internKeyword("NEWEST");
    return Value.fromFixnum(n);
}

fn parseLogicalDirectory(h: *Heap, interner: *Interner, text: []const u8) !Value {
    if (text.len == 0) return value.NIL;
    // A leading semicolon marks a relative directory, the reverse of the
    // physical syntax where a leading slash marks an absolute one.
    const relative = text[0] == ';';

    var components = h.protect();
    defer components.close();
    var it = std.mem.splitScalar(u8, text, ';');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try components.push(try directorySegment(h, interner, seg));
    }

    const list = try h.list(components.items());
    const head = try interner.internKeyword(if (relative) "RELATIVE" else "ABSOLUTE");
    return h.listWithTail(&.{head}, list);
}

pub fn parse(h: *Heap, interner: *Interner, text: []const u8) !heap.Pathname {
    const cut = if (std.mem.lastIndexOfScalar(u8, text, '/')) |i| i + 1 else 0;
    const file = text[cut..];

    var held = h.protect();
    defer held.close();

    var parts = heap.Pathname{
        .host = value.NIL,
        .device = value.NIL,
        .directory = try parseDirectory(h, interner, text[0..cut]),
        .name = value.NIL,
        .type_ = value.NIL,
        .version = value.NIL,
        .is_logical = false,
    };
    try held.push(parts.directory);

    // A leading dot belongs to the name, so `.emacs` has no type.
    if (std.mem.lastIndexOfScalar(u8, file, '.')) |dot| {
        if (dot > 0) {
            parts.name = try component(h, interner, file[0..dot]);
            try held.push(parts.name);
            parts.type_ = try component(h, interner, file[dot + 1 ..]);
            return parts;
        }
    }
    parts.name = try component(h, interner, file);
    return parts;
}

pub fn parseText(h: *Heap, interner: *Interner, text: []const u8) !Value {
    return h.allocPathname(try parse(h, interner, text));
}

/// A name or type piece: absent, wild, or the text itself.
fn component(h: *Heap, interner: *Interner, text: []const u8) !Value {
    if (text.len == 0) return value.NIL;
    if (std.mem.eql(u8, text, "*")) return interner.internKeyword("WILD");
    return h.allocString(text);
}

fn parseDirectory(h: *Heap, interner: *Interner, text: []const u8) !Value {
    if (text.len == 0) return value.NIL;
    const absolute = text[0] == '/';

    var components = h.protect();
    defer components.close();
    var it = std.mem.splitScalar(u8, text, '/');
    while (it.next()) |seg| {
        // Empty segments come from the leading slash and from doubled
        // separators; a lone `.` adds nothing to the path.
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        try components.push(try directorySegment(h, interner, seg));
    }

    const list = try h.list(components.items());
    const head = try interner.internKeyword(if (absolute) "ABSOLUTE" else "RELATIVE");
    return h.listWithTail(&.{head}, list);
}

fn directorySegment(h: *Heap, interner: *Interner, seg: []const u8) !Value {
    if (std.mem.eql(u8, seg, "..")) return interner.internKeyword("UP");
    if (std.mem.eql(u8, seg, "**")) return interner.internKeyword("WILD-INFERIORS");
    if (std.mem.eql(u8, seg, "*")) return interner.internKeyword("WILD");
    return h.allocString(seg);
}

// --- rendering ---

/// The namestring a pathname's components spell.
pub fn namestringOf(allocator: std.mem.Allocator, v: Value) ![]const u8 {
    if (heap.isString(v)) return heap.stringUtf8Alloc(allocator, v);
    if (!heap.isPathname(v)) return error.TypeError;
    if (heap.asPathname(v).is_logical) return renderLogical(allocator, v);
    const p = heap.asPathname(v);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try renderDirectory(allocator, p.directory, &out);
    try renderComponent(allocator, p.name, &out);
    if (!p.type_.equalsRaw(value.NIL)) {
        try out.append(allocator, '.');
        try renderComponent(allocator, p.type_, &out);
    }
    return out.toOwnedSlice(allocator);
}

pub fn renderComponent(allocator: std.mem.Allocator, v: Value, out: *std.ArrayListUnmanaged(u8)) !void {
    if (v.equalsRaw(value.NIL)) return;
    if (heap.isString(v)) {
        const text = try heap.stringUtf8Alloc(allocator, v);
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
        return;
    }
    if (!v.isSymbol()) return error.TypeError;
    try out.appendSlice(allocator, try segmentText(symbol_mod.symbol(v).name));
}

/// The text a component keyword spells in a namestring.
pub fn segmentText(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "WILD")) return "*";
    if (std.mem.eql(u8, name, "WILD-INFERIORS")) return "**";
    if (std.mem.eql(u8, name, "UP") or std.mem.eql(u8, name, "BACK")) return "..";
    if (std.mem.eql(u8, name, "UNSPECIFIC")) return "";
    if (std.mem.eql(u8, name, "NEWEST")) return "NEWEST";
    return error.TypeError;
}

pub fn renderLogical(allocator: std.mem.Allocator, v: Value) ![]const u8 {
    const p = heap.asPathname(v);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try renderComponent(allocator, p.host, &out);
    try out.append(allocator, ':');
    if (p.directory.isCons()) {
        if (try isRelative(p.directory)) try out.append(allocator, ';');
        var rest = heap.cdr(p.directory);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            try renderComponent(allocator, heap.car(rest), &out);
            try out.append(allocator, ';');
        }
    }
    try renderComponent(allocator, p.name, &out);
    if (!p.type_.equalsRaw(value.NIL)) {
        try out.append(allocator, '.');
        try renderComponent(allocator, p.type_, &out);
    }
    if (!p.version.equalsRaw(value.NIL)) {
        try out.append(allocator, '.');
        try renderVersion(allocator, p.version, &out);
    }
    return out.toOwnedSlice(allocator);
}

fn isRelative(dir: Value) !bool {
    const head = heap.car(dir);
    if (!head.isSymbol()) return error.TypeError;
    return std.mem.eql(u8, symbol_mod.symbol(head).name, "RELATIVE");
}

fn renderVersion(allocator: std.mem.Allocator, v: Value, out: *std.ArrayListUnmanaged(u8)) !void {
    if (v.isFixnum()) {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{v.toFixnum()});
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
        return;
    }
    try renderComponent(allocator, v, out);
}

pub fn renderDirectory(allocator: std.mem.Allocator, dir: Value, out: *std.ArrayListUnmanaged(u8)) !void {
    if (dir.equalsRaw(value.NIL)) return;
    if (!dir.isCons()) return error.TypeError;
    const head = heap.car(dir);
    if (!head.isSymbol()) return error.TypeError;
    const kind = symbol_mod.symbol(head).name;
    if (std.mem.eql(u8, kind, "ABSOLUTE")) {
        try out.append(allocator, '/');
    } else if (!std.mem.eql(u8, kind, "RELATIVE")) {
        return error.TypeError;
    }
    var rest = heap.cdr(dir);
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try renderComponent(allocator, heap.car(rest), out);
        try out.append(allocator, '/');
    }
}
