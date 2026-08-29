//! The `format` directive language: a parser that turns a control string
//! into a node tree, and an interpreter that walks it.
//!
//! Parsing is separate from execution because the block directives (`~[`,
//! `~{`) need their extent known before any argument is consumed, and a
//! `v` parameter consumes one.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const printer = @import("../runtime/printer.zig");
const equality = @import("../runtime/equality.zig");
const proto_class = @import("../runtime/proto_class.zig");
const package = @import("../runtime/package.zig");
const character = @import("../runtime/character.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

/// Give the printer and reader variables their standard values, where
/// nothing has given them one already.
pub fn registerVariables(ev: *Evaluator) !void {
    try defineVariable(ev, "*PRINT-ESCAPE*", value.T);
    try defineVariable(ev, "*PRINT-READABLY*", value.NIL);
    try defineVariable(ev, "*PRINT-BASE*", Value.fromFixnum(10));
    try defineVariable(ev, "*PRINT-RADIX*", value.NIL);
    try defineVariable(ev, "*PRINT-CASE*", try ev.interner.internKeyword("UPCASE"));
    try defineVariable(ev, "*PRINT-LEVEL*", value.NIL);
    try defineVariable(ev, "*PRINT-LENGTH*", value.NIL);
    try defineVariable(ev, "*PRINT-LINES*", value.NIL);
    try defineVariable(ev, "*PRINT-ARRAY*", value.T);
    try defineVariable(ev, "*PRINT-GENSYM*", value.T);
    try defineVariable(ev, "*READ-BASE*", Value.fromFixnum(10));
    try defineVariable(ev, "*READ-EVAL*", value.T);
    try defineVariable(ev, "*READ-SUPPRESS*", value.NIL);
    try defineVariable(ev, "*READ-DEFAULT-FLOAT-FORMAT*", try ev.interner.intern("SINGLE-FLOAT"));
}

fn defineVariable(ev: *Evaluator, name: []const u8, initial: Value) !void {
    const sym = try ev.interner.intern(name);
    symbol_mod.symbol(sym).special = true;
    if (symbol_mod.symbol(sym).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) {
        symbol_mod.symbol(sym).value_cell = initial;
    }
}

/// What a printer variable holds now, or null where the name has no
/// value.
fn variable(ev: *Evaluator, name: []const u8) ?Value {
    const sym = ev.interner.lookup(name) orelse return null;
    const held = ev.env.lookupValue(sym) orelse return null;
    if (held.equalsRaw(value.SPECIAL_UNBOUND)) return null;
    return held;
}

fn flag(ev: *Evaluator, name: []const u8, fallback: bool) bool {
    const held = variable(ev, name) orelse return fallback;
    return !held.equalsRaw(value.NIL);
}

/// A count a printer variable holds, or null where it holds `nil` or
/// something that is not one.
fn count(ev: *Evaluator, name: []const u8) ?u32 {
    const held = variable(ev, name) orelse return null;
    if (!held.isFixnum()) return null;
    const n = held.toFixnum();
    if (n < 0) return null;
    return @intCast(n);
}

/// The exponent marker the type in `*read-default-float-format*`
/// carries, which is the one a float of that type does without.
fn defaultFloatMarker(ev: *Evaluator) u8 {
    const held = variable(ev, "*READ-DEFAULT-FLOAT-FORMAT*") orelse return 'f';
    if (!held.isSymbol()) return 'f';
    const name = symbol_mod.name(held);
    if (std.mem.eql(u8, name, "DOUBLE-FLOAT")) return 'd';
    if (std.mem.eql(u8, name, "LONG-FLOAT")) return 'd';
    return 'f';
}

fn printCase(ev: *Evaluator) printer.Case {
    const held = variable(ev, "*PRINT-CASE*") orelse return .upcase;
    if (!held.isSymbol()) return .upcase;
    const name = symbol_mod.name(held);
    if (std.mem.eql(u8, name, "DOWNCASE")) return .downcase;
    if (std.mem.eql(u8, name, "CAPITALIZE")) return .capitalize;
    return .upcase;
}

/// The settings the printer variables come to, with `escape` left to the
/// caller: `prin1` and `princ` differ over that one alone.
fn printerSettings(ev: *Evaluator, escaping: bool) printer.Settings {
    const base = count(ev, "*PRINT-BASE*") orelse 10;
    return .{
        .escape = escaping,
        .readably = flag(ev, "*PRINT-READABLY*", false),
        .base = if (base >= 2 and base <= 36) @intCast(base) else 10,
        .radix = flag(ev, "*PRINT-RADIX*", false),
        .case = printCase(ev),
        .default_float = defaultFloatMarker(ev),
        .level = count(ev, "*PRINT-LEVEL*"),
        .length = count(ev, "*PRINT-LENGTH*"),
        .gensym = flag(ev, "*PRINT-GENSYM*", true),
        .current_package = ev.interner.currentPackage(),
    };
}

pub fn prin1Settings(ev: *Evaluator) printer.Settings {
    return printerSettings(ev, flag(ev, "*PRINT-ESCAPE*", true));
}

pub fn princSettings(ev: *Evaluator) printer.Settings {
    return printerSettings(ev, false);
}

/// True when `*print-circle*` asks for shared structure to be labeled.
pub fn circleWanted(ev: *Evaluator) bool {
    const sym = ev.interner.lookup("*PRINT-CIRCLE*") orelse return false;
    const v = ev.env.lookupValue(sym) orelse return false;
    return !v.equalsRaw(value.NIL);
}

/// A writer plus the column it is sitting at, which `~&` and `~T` need.
/// The column belongs to the destination, so console output carries it on
/// the evaluator and string output keeps its own.
pub const Output = struct {
    writer: *std.Io.Writer,
    column: *usize,

    pub fn writeChar(self: Output, c: u21) Error!void {
        try printer.writeRawChar(self.writer, c);
        self.column.* = if (c == '\n') 0 else self.column.* + 1;
    }

    /// Text that is already UTF-8, such as a rendered value. The bytes go
    /// straight through; only the column has to count characters, which is
    /// the non-continuation bytes.
    fn writeText(self: Output, text: []const u8) Error!void {
        try self.writer.writeAll(text);
        for (text) |b| {
            if (b == '\n') {
                self.column.* = 0;
            } else if (b & 0xC0 != 0x80) {
                self.column.* += 1;
            }
        }
    }

    fn writeChars(self: Output, text: []const u32) Error!void {
        for (text) |c| try self.writeChar(@intCast(c));
    }

    fn repeat(self: Output, c: u21, n: usize) Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writeChar(c);
    }
};

// --- parse tree ---

/// A directive parameter as written. `next_arg` is `v` and `arg_count` is
/// `#`; both resolve against the argument list at execution time.
const Param = union(enum) { absent, number: i64, next_arg, arg_count };

const MAX_PARAMS = 7;

const Directive = struct {
    params: [MAX_PARAMS]Param = .{ .absent, .absent, .absent, .absent, .absent, .absent, .absent },
    colon: bool = false,
    at: bool = false,
    char: u8 = 0,
};

const Conditional = struct {
    directive: Directive,
    clauses: []const []const Node,
    /// Index of the clause introduced by `~:;`, taken when no other fits.
    default: ?usize,
};

const Iteration = struct {
    directive: Directive,
    body: []const Node,
};

const Call = struct {
    directive: Directive,
    name: []const u32,
};

const Node = union(enum) {
    literal: []const u32,
    simple: Directive,
    conditional: Conditional,
    iteration: Iteration,
    call: Call,
    case_block: CaseBlock,
    justification: Justification,
};

/// `~(...~)` — the body's output with its case converted.
const CaseBlock = struct {
    directive: Directive,
    body: []const Node,
};

/// `~<...~>` — segments separated by `~;`. Line breaking is the pretty
/// printer's job; what is kept here is the segment structure, including
/// the `~:;` overflow segment that only shows when the line is too long.
const Justification = struct {
    directive: Directive,
    segments: []const []const Node,
    /// Whether the first segment was introduced as the overflow prefix.
    has_overflow: bool,
    /// Whether `~:>` closed it, which makes it a logical block rather
    /// than a field to justify in.
    logical: bool = false,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    ctrl: []const u32,
    pos: usize = 0,
};

/// Nodes up to a terminating directive, plus that directive. A `char` of 0
/// means the control string ended.
const Block = struct {
    nodes: []const Node,
    stop: Directive,
};

fn parseBlock(p: *Parser, terminators: []const u8) Error!Block {
    var nodes: std.ArrayList(Node) = .empty;
    var literal_start = p.pos;
    while (p.pos < p.ctrl.len) {
        if (p.ctrl[p.pos] != '~') {
            p.pos += 1;
            continue;
        }
        if (p.pos > literal_start) {
            try nodes.append(p.allocator, .{ .literal = p.ctrl[literal_start..p.pos] });
        }
        p.pos += 1;
        const directive = try parseDirective(p);
        if (std.mem.indexOfScalar(u8, terminators, directive.char) != null) {
            return .{ .nodes = try nodes.toOwnedSlice(p.allocator), .stop = directive };
        }
        try nodes.append(p.allocator, try parseNode(p, directive));
        literal_start = p.pos;
    }
    if (p.pos > literal_start) {
        try nodes.append(p.allocator, .{ .literal = p.ctrl[literal_start..p.pos] });
    }
    if (terminators.len != 0) return Error.ProgramError;
    return .{ .nodes = try nodes.toOwnedSlice(p.allocator), .stop = .{} };
}

/// How many parameters a directive takes. More than this is a program
/// error, which is what keeps `~1,2,3,4,5D` from being read as `~D`.
fn maxParams(char: u8) usize {
    return switch (char) {
        'E', 'G' => 7,
        'R', 'F' => 5,
        'A', 'S', 'D', 'B', 'O', 'X', '$', '<' => 4,
        '^' => 3,
        'T' => 2,
        '%', '&', '~', '|', '*', '[', '{', '_', 'I' => 1,
        'C', 'P', 'W', '?', '(' => 0,
        else => MAX_PARAMS,
    };
}

fn parseNode(p: *Parser, directive: Directive) Error!Node {
    var highest: usize = 0;
    for (directive.params, 0..) |param, slot| {
        if (param != .absent) highest = slot + 1;
    }
    if (highest > maxParams(directive.char)) return Error.ProgramError;
    return switch (directive.char) {
        '[' => .{ .conditional = try parseConditional(p, directive) },
        '{' => .{ .iteration = .{
            .directive = directive,
            .body = (try parseBlock(p, "}")).nodes,
        } },
        '/' => .{ .call = .{ .directive = directive, .name = try parseCallName(p) } },
        '(' => .{ .case_block = .{
            .directive = directive,
            .body = (try parseBlock(p, ")")).nodes,
        } },
        '<' => .{ .justification = try parseJustification(p, directive) },
        'A', 'S', 'D', 'B', 'O', 'X', 'R', 'C', 'F', 'E', 'G', '$', '%', '&', '~', '|', '*', 'T', '?', '^', 'P', '_', 'I', 'W' => .{ .simple = directive },
        // `~<newline>` continues a control string across source lines: the
        // newline goes unless `@` keeps it, and the indentation after it
        // goes unless `:` keeps that.
        '\n', '\r' => blk: {
            if (!directive.colon) {
                while (p.pos < p.ctrl.len and isFormatWhitespace(p.ctrl[p.pos])) p.pos += 1;
            }
            break :blk .{ .literal = if (directive.at) &NEWLINE_TEXT else &.{} };
        },
        else => Error.ProgramError,
    };
}

fn parseConditional(p: *Parser, directive: Directive) Error!Conditional {
    var clauses: std.ArrayList([]const Node) = .empty;
    var default: ?usize = null;
    while (true) {
        const block = try parseBlock(p, "];");
        try clauses.append(p.allocator, block.nodes);
        if (block.stop.char == ']') break;
        if (block.stop.colon) default = clauses.items.len;
    }
    return .{
        .directive = directive,
        .clauses = try clauses.toOwnedSlice(p.allocator),
        .default = default,
    };
}

fn parseJustification(p: *Parser, directive: Directive) Error!Justification {
    var segments: std.ArrayList([]const Node) = .empty;
    var has_overflow = false;
    var logical = false;
    while (true) {
        const block = try parseBlock(p, ">;");
        try segments.append(p.allocator, block.nodes);
        if (block.stop.char == '>') {
            // `~:>` closes a logical block, where `~<` closes a field to
            // justify text in.
            logical = block.stop.colon;
            break;
        }
        if (block.stop.colon and segments.items.len == 1) has_overflow = true;
    }
    return .{
        .directive = directive,
        .segments = try segments.toOwnedSlice(p.allocator),
        .has_overflow = has_overflow,
        .logical = logical,
    };
}

/// `~/name/` names a function; the text runs to the closing slash.
fn parseCallName(p: *Parser) Error![]const u32 {
    const start = p.pos;
    while (p.pos < p.ctrl.len and p.ctrl[p.pos] != '/') p.pos += 1;
    if (p.pos >= p.ctrl.len) return Error.ProgramError;
    const name = p.ctrl[start..p.pos];
    p.pos += 1;
    return name;
}

/// Characters in a UTF-8 slice, which is what the padding widths count.
fn utf8Count(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

const NEWLINE_TEXT = [_]u32{'\n'};

fn isFormatWhitespace(c: u32) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 12;
}

fn isDigit(c: u32) bool {
    return c >= '0' and c <= '9';
}

fn parseDirective(p: *Parser) Error!Directive {
    var directive = Directive{};
    var slot: usize = 0;
    while (p.pos < p.ctrl.len) {
        const c = p.ctrl[p.pos];
        if (c == ',') {
            slot += 1;
            p.pos += 1;
            continue;
        }
        if (c == ':') {
            directive.colon = true;
            p.pos += 1;
            continue;
        }
        if (c == '@') {
            directive.at = true;
            p.pos += 1;
            continue;
        }
        if (try parseParam(p)) |param| {
            if (slot >= MAX_PARAMS) return Error.ProgramError;
            directive.params[slot] = param;
            continue;
        }
        directive.char = if (c < 128) std.ascii.toUpper(@intCast(c)) else 0;
        p.pos += 1;
        return directive;
    }
    return Error.ProgramError;
}

/// A parameter is a signed integer, `'c` for a character's code, `v` for
/// "take the next argument", or `#` for the number of arguments left.
/// Null means there is no parameter at the cursor.
fn parseParam(p: *Parser) Error!?Param {
    const c = p.ctrl[p.pos];
    if (c == '\'') {
        p.pos += 1;
        if (p.pos >= p.ctrl.len) return Error.ProgramError;
        const quoted = p.ctrl[p.pos];
        p.pos += 1;
        return .{ .number = @intCast(quoted) };
    }
    if (c == 'v' or c == 'V') {
        p.pos += 1;
        return .next_arg;
    }
    if (c == '#') {
        p.pos += 1;
        return .arg_count;
    }
    const signed = c == '-' or c == '+';
    if (!isDigit(c) and !signed) return null;
    var i = p.pos + if (signed) @as(usize, 1) else 0;
    const start = i;
    var n: i64 = 0;
    // A control string may carry a parameter far larger than any width
    // it could mean, so the digits saturate rather than wrap.
    while (i < p.ctrl.len and isDigit(p.ctrl[i])) : (i += 1) {
        n = n *| 10 +| @as(i64, @intCast(p.ctrl[i] - '0'));
    }
    if (i == start) return null;
    p.pos = i;
    return .{ .number = if (c == '-') -n else n };
}

// --- execution ---

/// How a block finished: normally, escaped out of one level by `~^`, or
/// escaped out of the whole iteration by `~:^`.
const Flow = enum { normal, escape_clause, escape_all };

/// The argument list a block is walking, and how far into it execution is.
const Args = struct {
    items: []const Value,
    index: usize = 0,

    fn remaining(self: Args) usize {
        return self.items.len - self.index;
    }

    fn next(self: *Args) Error!Value {
        if (self.index >= self.items.len) return Error.ProgramError;
        const v = self.items[self.index];
        self.index += 1;
        return v;
    }
};

const Runner = struct {
    ev: *Evaluator,
    out: Output,
    allocator: std.mem.Allocator,
    /// The list a `~:{` is walking, which is what `~:^` tests rather
    /// than the sublist the body is reading.
    outer: ?*Args = null,

    /// The parameter in `slot`, resolved against the argument list. An
    /// absent parameter, or an explicit nil `v`, yields `default`.
    fn param(self: *Runner, directive: Directive, slot: usize, args: *Args, default: i64) Error!i64 {
        _ = self;
        return switch (directive.params[slot]) {
            .absent => default,
            .number => |n| n,
            .arg_count => @intCast(args.remaining()),
            .next_arg => blk: {
                const v = try args.next();
                if (v.equalsRaw(value.NIL)) break :blk default;
                if (v.tag() == .char) break :blk v.toChar();
                if (v.isFixnum()) break :blk v.toFixnum();
                // A bignum parameter is past any width that means
                // anything, so it saturates the way a written one does.
                if (isInteger(v)) {
                    break :blk if (equality.toF64(v) < 0)
                        std.math.minInt(i64)
                    else
                        std.math.maxInt(i64);
                }
                return Error.TypeError;
            },
        };
    }

    fn count(self: *Runner, directive: Directive, slot: usize, args: *Args, default: i64) Error!usize {
        const n = try self.param(directive, slot, args, default);
        if (n < 0) return Error.ProgramError;
        return @intCast(n);
    }
};

/// Run `ctrl` against `args`, and say how many of them it used, which
/// is what a `formatter` function reports back as the tail it left.
pub fn run(ev: *Evaluator, out: Output, ctrl: []const u32, args: []const Value) Error!usize {
    var arena = std.heap.ArenaAllocator.init(ev.allocator);
    defer arena.deinit();

    var parser = Parser{ .allocator = arena.allocator(), .ctrl = ctrl };
    const block = try parseBlock(&parser, "");

    var runner = Runner{ .ev = ev, .out = out, .allocator = arena.allocator() };
    var cursor = Args{ .items = args };
    _ = try runNodes(&runner, block.nodes, &cursor);
    return cursor.index;
}

fn runNodes(r: *Runner, nodes: []const Node, args: *Args) Error!Flow {
    for (nodes) |node| {
        const flow = switch (node) {
            .literal => |text| blk: {
                try r.out.writeChars(text);
                break :blk Flow.normal;
            },
            .simple => |directive| try runSimple(r, directive, args),
            .conditional => |c| try runConditional(r, c, args),
            .iteration => |it| try runIteration(r, it, args),
            .call => |c| blk: {
                try runCall(r, c, args);
                break :blk Flow.normal;
            },
            .case_block => |c| try runCaseBlock(r, c, args),
            .justification => |j| try runJustification(r, j, args),
        };
        if (flow != .normal) return flow;
    }
    return .normal;
}

fn runSimple(r: *Runner, directive: Directive, args: *Args) Error!Flow {
    switch (directive.char) {
        'A' => try printPadded(r, directive, args, princSettings(r.ev)),
        'S' => try printPadded(r, directive, args, prin1Settings(r.ev)),
        'D' => try printRadix(r, directive, args, 10, 0),
        'B' => try printRadix(r, directive, args, 2, 0),
        'O' => try printRadix(r, directive, args, 8, 0),
        'X' => try printRadix(r, directive, args, 16, 0),
        'R' => try printRoman(r, directive, args),
        'C' => try printCharacter(r, directive, args),
        'F' => try printFixed(r, directive, args),
        'E' => try printExponential(r, directive, args),
        'G' => try printGeneral(r, directive, args),
        '$' => try printMonetary(r, directive, args),
        '%' => try r.out.repeat('\n', try r.count(directive, 0, args, 1)),
        '|' => try r.out.repeat(0x0C, try r.count(directive, 0, args, 1)),
        '&' => try freshLine(r, directive, args),
        '~' => try r.out.repeat('~', try r.count(directive, 0, args, 1)),
        '*' => try skipArgs(r, directive, args),
        'T' => try columnTab(r, directive, args),
        '?' => try recursiveFormat(r, directive, args),
        'P' => try printPlural(r, directive, args),
        // Conditional newline and indentation only matter under the pretty
        // printer, which does its own line breaking.
        '_', 'I' => {},
        'W' => try printPadded(r, directive, args, prin1Settings(r.ev)),
        '^' => return try escape(r, directive, args),
        else => return Error.ProgramError,
    }
    return .normal;
}

/// `~P`: the plural suffix for the argument. `:` re-uses the previous
/// argument, `@` gives the y/ies pair instead of ""/s.
fn printPlural(r: *Runner, directive: Directive, args: *Args) Error!void {
    if (directive.colon) {
        if (args.index == 0) return Error.ProgramError;
        args.index -= 1;
    }
    const arg = try args.next();
    const singular = arg.isFixnum() and arg.toFixnum() == 1;
    if (directive.at) {
        try r.out.writeText(if (singular) "y" else "ies");
    } else if (!singular) {
        try r.out.writeChar('s');
    }
}

/// `~(...~)`: the body's output, case-converted. Plain downcases, `:`
/// capitalizes each word, `@` capitalizes the first word, `:@` upcases.
fn runCaseBlock(r: *Runner, block: CaseBlock, args: *Args) Error!Flow {
    var captured = std.Io.Writer.Allocating.init(r.allocator);
    var column: usize = r.out.column.*;
    var inner = Runner{
        .ev = r.ev,
        .out = .{ .writer = &captured.writer, .column = &column },
        .allocator = r.allocator,
    };
    const flow = try runNodes(&inner, block.body, args);
    const text = captured.written();

    var at_word_start = true;
    var seen_word = false;
    for (text) |byte| {
        const alphanumeric = std.ascii.isAlphanumeric(byte);
        const converted: u8 = if (directiveUpcases(block.directive))
            std.ascii.toUpper(byte)
        else if (block.directive.colon)
            (if (at_word_start) std.ascii.toUpper(byte) else std.ascii.toLower(byte))
        else if (block.directive.at)
            (if (at_word_start and !seen_word) std.ascii.toUpper(byte) else std.ascii.toLower(byte))
        else
            std.ascii.toLower(byte);
        try r.out.writeChar(converted);
        if (alphanumeric) seen_word = true;
        at_word_start = !alphanumeric;
    }
    return flow;
}

fn directiveUpcases(directive: Directive) bool {
    return directive.colon and directive.at;
}

/// `~mincol,colinc,minpad,padchar<...~>`: the segments, spread across a
/// field at least `mincol` wide.
///
/// A padding point sits between each pair of segments, `:` adds one
/// before the first and `@` one after the last. With none of those the
/// text is right-justified, which is the one padding point a lone
/// segment gets. A `~^` that fires drops the segment it is in and every
/// one after it.
fn runJustification(r: *Runner, j: Justification, args: *Args) Error!Flow {
    if (j.logical) return runLogicalBlock(r, j, args);
    const directive = j.directive;
    const mincol = try r.count(directive, 0, args, 0);
    const colinc = @max(try r.count(directive, 1, args, 1), 1);
    const minpad = try r.count(directive, 2, args, 0);
    const padchar: u21 = @intCast(try r.param(directive, 3, args, ' '));

    // The segment before a `~:;` is what a line break would print, and
    // nothing here breaks lines.
    const segments = if (j.has_overflow and j.segments.len > 1) j.segments[1..] else j.segments;

    var texts: std.ArrayList([]const u8) = .empty;
    for (segments) |segment| {
        var captured = std.Io.Writer.Allocating.init(r.allocator);
        var column: usize = 0;
        var inner = Runner{
            .ev = r.ev,
            .out = .{ .writer = &captured.writer, .column = &column },
            .allocator = r.allocator,
            .outer = r.outer,
        };
        if (try runNodes(&inner, segment, args) != .normal) break;
        try texts.append(r.allocator, captured.written());
    }

    var written: usize = 0;
    for (texts.items) |text| written += utf8Count(text);

    const gaps = try paddingPoints(r, directive, texts.items.len);
    var points: usize = 0;
    for (gaps) |gap| {
        if (gap) points += 1;
    }

    var width = mincol;
    const needed = written + minpad * points;
    while (width < needed) width += colinc;
    const spread = width - written;

    var given: usize = 0;
    var index: usize = 0;
    while (index < gaps.len) : (index += 1) {
        if (gaps[index]) {
            given += 1;
            try r.out.repeat(padchar, gapWidth(spread, points, given));
        }
        if (index < texts.items.len) try r.out.writeText(texts.items[index]);
    }
    return .normal;
}

/// `~<prefix~;body~;suffix~:>`: the body runs over the one argument the
/// directive takes, which is a list of what to print. `:` on the opening
/// directive makes the prefix and suffix parentheses.
///
/// Line breaking is the pretty printer's, and nothing here breaks lines,
/// so what this settles is the argument list the body reads and the text
/// that goes around it.
fn runLogicalBlock(r: *Runner, j: Justification, args: *Args) Error!Flow {
    var items: std.ArrayList(Value) = .empty;
    if (j.directive.at) {
        // `~@<` hands the block what is left of the argument list.
        try items.appendSlice(r.allocator, args.items[args.index..]);
        args.index = args.items.len;
    } else {
        const object = try args.next();
        if (!object.isCons() and !object.equalsRaw(value.NIL)) {
            try r.out.writeText(try render(r, object, prin1Settings(r.ev)));
            return .normal;
        }
        try collectList(r, object, &items);
    }
    var cursor = Args{ .items = items.items };

    const body_at = if (j.segments.len > 1) @as(usize, 1) else 0;
    const has_suffix = j.segments.len > 2;
    if (body_at == 1) {
        _ = try runNodes(r, j.segments[0], &cursor);
    } else if (j.directive.colon) {
        try r.out.writeChar('(');
    }

    const flow = try runNodes(r, j.segments[body_at], &cursor);

    if (has_suffix) {
        _ = try runNodes(r, j.segments[2], &cursor);
    } else if (body_at == 0 and j.directive.colon) {
        try r.out.writeChar(')');
    }
    return if (flow == .escape_all) .escape_all else .normal;
}

/// Where the padding points fall: one slot per position, from before the
/// first segment to after the last.
fn paddingPoints(r: *Runner, directive: Directive, segments: usize) Error![]bool {
    const gaps = try r.allocator.alloc(bool, segments + 1);
    @memset(gaps, false);
    var index: usize = 1;
    while (index + 1 <= segments) : (index += 1) gaps[index] = true;
    if (directive.colon) gaps[0] = true;
    if (directive.at) gaps[segments] = true;
    for (gaps) |gap| {
        if (gap) return gaps;
    }
    // A lone segment with neither modifier is right-justified.
    gaps[0] = true;
    return gaps;
}

/// The `given`th of `points` padding points, sharing `spread` between
/// them with what does not divide going to the leftmost.
fn gapWidth(spread: usize, points: usize, given: usize) usize {
    if (points == 0) return 0;
    const each = spread / points;
    const extra = spread % points;
    return each + @intFromBool(given <= extra);
}

/// `~A` / `~S`: print the argument, then pad to `mincol` in `colinc` steps.
/// With `@` the padding goes on the left instead.
fn printPadded(r: *Runner, directive: Directive, args: *Args, settings: printer.Settings) Error!void {
    const mincol = try r.param(directive, 0, args, 0);
    const colinc = @max(try r.param(directive, 1, args, 1), 1);
    const minpad = try r.param(directive, 2, args, 0);
    const padchar: u21 = @intCast(try r.param(directive, 3, args, ' '));
    const arg = try args.next();

    // `~:A` and `~:S` print an empty list as `()` rather than as `nil`.
    const text = if (directive.colon and arg.equalsRaw(value.NIL))
        "()"
    else
        try render(r, arg, settings);
    var pad: i64 = minpad;
    const width: i64 = @intCast(utf8Count(text));
    while (width + pad < mincol) pad += colinc;
    const pad_count: usize = @intCast(@max(pad, 0));

    if (directive.at) try r.out.repeat(padchar, pad_count);
    try r.out.writeText(text);
    if (!directive.at) try r.out.repeat(padchar, pad_count);
}

fn render(r: *Runner, v: Value, settings: printer.Settings) Error![]const u8 {
    // A condition prints as its report where nothing asked for output
    // that reads back, which is what `~A` and `princ` want of it.
    if (!settings.escape) {
        if (try conditionReport(r.ev, r.allocator, v)) |text| return text;
    }
    var rendered = std.Io.Writer.Allocating.init(r.allocator);
    try printer.write(r.allocator, &rendered.writer, v, settings);
    return rendered.written();
}

/// What a condition's report function writes, or null where its class
/// has none. The report is handed `t` for its stream and what it writes
/// there is captured, the way a `~/name/` call's output is.
pub fn conditionReport(
    ev: *Evaluator,
    allocator: std.mem.Allocator,
    v: Value,
) Error!?[]const u8 {
    if (!proto_class.isInstance(ev, v)) return null;
    const report = proto_class.inheritedReport(proto_class.classOf(v));
    if (report.equalsRaw(value.NIL)) return null;

    var captured = std.Io.Writer.Allocating.init(allocator);
    const saved_out = ev.out;
    const saved_column = ev.output_column;
    ev.out = &captured.writer;
    ev.output_column = 0;
    defer {
        ev.out = saved_out;
        ev.output_column = saved_column;
    }
    _ = try ev.callFunction(report, &.{ v, value.T });
    return captured.written();
}

/// `~D`, `~B`, `~O`, `~X` and the radix form of `~R`: the integer in
/// `base`, right-aligned in `mincol`, with `:` grouping digits. `~R`
/// spends its first parameter on the radix, so its remaining four start
/// at `offset`.
fn printRadix(
    r: *Runner,
    directive: Directive,
    args: *Args,
    base: u8,
    offset: usize,
) Error!void {
    const mincol = try r.param(directive, offset, args, 0);
    const padchar: u21 = @intCast(try r.param(directive, offset + 1, args, ' '));
    const comma: u21 = @intCast(try r.param(directive, offset + 2, args, ','));
    const interval: usize = @intCast(@max(try r.param(directive, offset + 3, args, 3), 1));
    const arg = try args.next();

    var text: std.ArrayList(u8) = .empty;
    if (!isInteger(arg)) {
        // CLHS 22.3.2: a non-integer prints as if by ~A in this base.
        var settings = princSettings(r.ev);
        settings.base = base;
        settings.radix = false;
        try text.appendSlice(r.allocator, try render(r, arg, settings));
    } else {
        const printed = try renderInteger(r, arg, base);
        const negative = printed[0] == '-';
        const digits = if (negative) printed[1..] else printed;
        if (negative) {
            try text.append(r.allocator, '-');
        } else if (directive.at) {
            try text.append(r.allocator, '+');
        }
        if (directive.colon) {
            try appendGrouped(r, digits, comma, interval, &text);
        } else {
            try text.appendSlice(r.allocator, digits);
        }
    }

    const width: i64 = @intCast(utf8Count(text.items));
    if (width < mincol) try r.out.repeat(padchar, @intCast(mincol - width));
    try r.out.writeText(text.items);
}

fn isInteger(v: Value) bool {
    if (v.isFixnum()) return true;
    return v.tag() == .heap and heap.heapType(v) == .bignum;
}

/// The integer's digits in `base`, sign included, with none of the
/// printer's radix marker.
fn renderInteger(r: *Runner, v: Value, base: u8) Error![]const u8 {
    var settings = princSettings(r.ev);
    settings.base = base;
    settings.radix = false;
    return render(r, v, settings);
}

/// `~:D` inserts `comma` every `interval` digits.
fn appendGrouped(
    r: *Runner,
    digits: []const u8,
    comma: u21,
    interval: usize,
    text: *std.ArrayList(u8),
) Error!void {
    var encoded: [4]u8 = undefined;
    const width = std.unicode.utf8Encode(comma, &encoded) catch return Error.ProgramError;
    for (digits, 0..) |d, i| {
        const remaining = digits.len - i;
        if (i != 0 and remaining % interval == 0) {
            try text.appendSlice(r.allocator, encoded[0..width]);
        }
        try text.append(r.allocator, d);
    }
}

/// `~&` starts a fresh line, and `~n&` leaves n-1 blank lines after it.
fn freshLine(r: *Runner, directive: Directive, args: *Args) Error!void {
    const n = try r.count(directive, 0, args, 1);
    if (n == 0) return;
    if (r.out.column.* != 0) try r.out.writeChar('\n');
    try r.out.repeat('\n', n - 1);
}

/// `~n*` skips forward, `~n:*` backs up, `~n@*` jumps to an absolute index.
fn skipArgs(r: *Runner, directive: Directive, args: *Args) Error!void {
    if (directive.at) {
        const target = try r.count(directive, 0, args, 0);
        if (target > args.items.len) return Error.ProgramError;
        args.index = target;
        return;
    }
    const n = try r.count(directive, 0, args, 1);
    if (directive.colon) {
        if (n > args.index) return Error.ProgramError;
        args.index -= n;
        return;
    }
    if (args.index + n > args.items.len) return Error.ProgramError;
    args.index += n;
}

/// `~colnum,colincT` pads to `colnum`, then in `colinc` steps past it.
fn columnTab(r: *Runner, directive: Directive, args: *Args) Error!void {
    const colnum = try r.count(directive, 0, args, 1);
    const colinc = @max(try r.count(directive, 1, args, 1), 1);
    const column = r.out.column.*;
    if (column < colnum) {
        try r.out.repeat(' ', colnum - column);
        return;
    }
    try r.out.repeat(' ', colinc - ((column - colnum) % colinc));
}

/// `~?` takes a control string and an argument list; `~@?` draws the
/// arguments from the enclosing list instead.
fn recursiveFormat(r: *Runner, directive: Directive, args: *Args) Error!void {
    const control = try args.next();
    if (!heap.isString(control)) return Error.TypeError;
    const ctrl = heap.asString(control).constSlice();

    if (directive.at) {
        var nested = Args{ .items = args.items, .index = args.index };
        _ = try runControl(r, ctrl, &nested);
        args.index = nested.index;
        return;
    }
    var list: std.ArrayList(Value) = .empty;
    try collectList(r, try args.next(), &list);
    var nested = Args{ .items = list.items };
    _ = try runControl(r, ctrl, &nested);
}

/// Parse and run a control string that only became known at execution time.
fn runControl(r: *Runner, ctrl: []const u32, args: *Args) Error!Flow {
    var parser = Parser{ .allocator = r.allocator, .ctrl = ctrl };
    const block = try parseBlock(&parser, "");
    return runNodes(r, block.nodes, args);
}

fn collectList(r: *Runner, list_v: Value, out: *std.ArrayList(Value)) Error!void {
    var rest = list_v;
    while (rest.isCons()) : (rest = heap.cdr(rest)) {
        try out.append(r.allocator, heap.car(rest));
    }
    if (!rest.equalsRaw(value.NIL)) return Error.TypeError;
}

/// `~^` leaves the enclosing clause when the arguments run out. With
/// parameters it compares them instead: one is zero-tested, two are tested
/// for equality, three for an ascending run.
fn escape(r: *Runner, directive: Directive, args: *Args) Error!Flow {
    const level: Flow = if (directive.colon) .escape_all else .escape_clause;
    // A `v` holding nil stands for a parameter that was not given, so
    // the parameters are resolved before they are counted.
    const resolved = try resolveParams(r, directive, args);
    const given = countParams(resolved);
    if (given == 0) {
        const cursor = if (directive.colon) r.outer orelse args else args;
        return if (cursor.remaining() == 0) level else .normal;
    }
    const first = try r.param(resolved, 0, args, 0);
    if (given == 1) return if (first == 0) level else .normal;
    const second = try r.param(resolved, 1, args, 0);
    if (given == 2) return if (first == second) level else .normal;
    const third = try r.param(resolved, 2, args, 0);
    return if (first <= second and second <= third) level else .normal;
}

fn countParams(directive: Directive) usize {
    var n: usize = 0;
    for (directive.params) |p| {
        if (p != .absent) n += 1;
    }
    return n;
}

/// `~[`: pick one clause. Plain form indexes by a parameter or an argument,
/// `~:[` picks by truth, `~@[` runs its one clause only for a true argument
/// and leaves that argument in place.
fn runConditional(r: *Runner, conditional: Conditional, args: *Args) Error!Flow {
    const directive = conditional.directive;
    if (directive.at) {
        if (conditional.clauses.len != 1) return Error.ProgramError;
        if (args.remaining() == 0) return Error.ProgramError;
        if (args.items[args.index].equalsRaw(value.NIL)) {
            _ = try args.next();
            return .normal;
        }
        return runNodes(r, conditional.clauses[0], args);
    }
    if (directive.colon) {
        if (conditional.clauses.len != 2) return Error.ProgramError;
        const chosen: usize = if ((try args.next()).equalsRaw(value.NIL)) 0 else 1;
        return runNodes(r, conditional.clauses[chosen], args);
    }

    const selector = switch (directive.params[0]) {
        .absent => blk: {
            const v = try args.next();
            if (!v.isFixnum()) return Error.TypeError;
            break :blk v.toFixnum();
        },
        else => try r.param(directive, 0, args, 0),
    };
    if (selector >= 0 and selector < conditional.clauses.len) {
        return runNodes(r, conditional.clauses[@intCast(selector)], args);
    }
    if (conditional.default) |index| return runNodes(r, conditional.clauses[index], args);
    return .normal;
}

/// `~{`: repeat the body over a list. `@` draws from the remaining format
/// arguments, `:` treats each element as its own argument list, and a
/// parameter caps the number of passes.
fn runIteration(r: *Runner, iteration: Iteration, args: *Args) Error!Flow {
    const directive = iteration.directive;
    const max = switch (directive.params[0]) {
        .absent => null,
        else => try r.count(directive, 0, args, 0),
    };

    var body = iteration.body;
    if (body.len == 0) {
        const control = try args.next();
        if (!heap.isString(control)) return Error.TypeError;
        var parser = Parser{ .allocator = r.allocator, .ctrl = heap.asString(control).constSlice() };
        body = (try parseBlock(&parser, "")).nodes;
    }

    var items: std.ArrayList(Value) = .empty;
    if (directive.at) {
        try items.appendSlice(r.allocator, args.items[args.index..]);
        args.index = args.items.len;
    } else {
        try collectList(r, try args.next(), &items);
    }

    var cursor = Args{ .items = items.items };
    var passes: usize = 0;
    while (max == null or passes < max.?) : (passes += 1) {
        if (cursor.remaining() == 0) break;
        const flow = if (directive.colon)
            try runSublistPass(r, body, &cursor)
        else
            try runNodes(r, body, &cursor);
        if (flow == .escape_all) return .normal;
        if (flow == .escape_clause) break;
    }
    return .normal;
}

/// One pass of a `~:{` iteration: the next element is itself the argument
/// list for the body.
fn runSublistPass(r: *Runner, body: []const Node, cursor: *Args) Error!Flow {
    var sublist: std.ArrayList(Value) = .empty;
    try collectList(r, try cursor.next(), &sublist);
    var inner = Args{ .items = sublist.items };
    const saved = r.outer;
    r.outer = cursor;
    defer r.outer = saved;
    const flow = try runNodes(r, body, &inner);
    return if (flow == .escape_all) .escape_all else .normal;
}

/// `~/name/` calls a user function with the stream, the argument, the two
/// modifier flags, and any parameters. Its output is captured so it lands
/// in this format's destination and keeps the column count honest.
fn runCall(r: *Runner, call: Call, args: *Args) Error!void {
    const fn_v = try resolveCallName(r, call.name);
    const arg = try args.next();

    var call_args: std.ArrayList(Value) = .empty;
    try call_args.append(r.allocator, value.T);
    try call_args.append(r.allocator, arg);
    try call_args.append(r.allocator, if (call.directive.colon) value.T else value.NIL);
    try call_args.append(r.allocator, if (call.directive.at) value.T else value.NIL);
    for (call.directive.params, 0..) |p, slot| {
        if (p == .absent) continue;
        try call_args.append(r.allocator, Value.fromFixnum(try r.param(call.directive, slot, args, 0)));
    }

    var captured = std.Io.Writer.Allocating.init(r.allocator);
    const saved_out = r.ev.out;
    r.ev.out = &captured.writer;
    defer r.ev.out = saved_out;
    _ = try r.ev.callFunction(fn_v, call_args.items);
    try r.out.writeText(captured.written());
}

/// The name between the slashes, upcased. CLHS 22.3.5.4: the first colon
/// or double colon splits the package from the symbol, and any colon
/// after that belongs to the symbol's name.
fn resolveCallName(r: *Runner, name: []const u32) Error!Value {
    var upper: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (c >= 128) return Error.ProgramError;
        try upper.append(r.allocator, std.ascii.toUpper(@intCast(c)));
    }
    const text = upper.items;

    var bare = text;
    var home: ?*package.Package = null;
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        var after = colon + 1;
        if (after < text.len and text[after] == ':') after += 1;
        home = r.ev.interner.registry.find(text[0..colon]) orelse return Error.NoSuchPackage;
        bare = text[after..];
    }

    const sym = if (home) |pkg|
        (pkg.findSymbol(bare) orelse return Error.UnboundFunction).sym
    else
        r.ev.interner.lookup(bare) orelse return Error.UnboundFunction;
    return r.ev.env.lookupFunction(sym) orelse r.ev.unbound(sym, Error.UnboundFunction);
}

/// `~R`: a radix parameter selects the digit form, and without one the
/// number is spelled out. `:` gives the ordinal, `@` the Roman numeral,
/// and `:@` the older Roman form that has no subtractive pairs.
fn printRoman(r: *Runner, directive: Directive, args: *Args) Error!void {
    // A `v` holding nil leaves the radix unsaid, which is what asks for
    // the number in words rather than in digits.
    const resolved = try resolveParams(r, directive, args);
    if (resolved.params[0] != .absent) {
        const base = try r.param(resolved, 0, args, 10);
        if (base < 2 or base > 36) return Error.ProgramError;
        return printRadix(r, resolved, args, @intCast(base), 1);
    }
    const arg = try args.next();
    if (!arg.isFixnum()) {
        // Only a fixnum is spelled out; anything else prints in decimal.
        var settings = princSettings(r.ev);
        settings.base = 10;
        settings.radix = false;
        return r.out.writeText(try render(r, arg, settings));
    }
    const n = arg.toFixnum();
    var text: std.ArrayList(u8) = .empty;
    if (resolved.at) {
        if (n < 1 or n > 4999) return Error.ProgramError;
        try appendRoman(r, @intCast(n), resolved.colon, &text);
    } else if (resolved.colon) {
        try appendOrdinal(r, n, &text);
    } else {
        try appendCardinal(r, n, &text);
    }
    try r.out.writeText(text.items);
}

const ROMAN_VALUES = [_]u32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
const ROMAN_DIGITS = [_][]const u8{ "M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I" };
const OLD_ROMAN_VALUES = [_]u32{ 1000, 500, 100, 50, 10, 5, 1 };
const OLD_ROMAN_DIGITS = [_][]const u8{ "M", "D", "C", "L", "X", "V", "I" };

fn appendRoman(r: *Runner, n: u32, old: bool, text: *std.ArrayList(u8)) Error!void {
    const values: []const u32 = if (old) &OLD_ROMAN_VALUES else &ROMAN_VALUES;
    const digits: []const []const u8 = if (old) &OLD_ROMAN_DIGITS else &ROMAN_DIGITS;
    var left = n;
    for (values, digits) |v, d| {
        while (left >= v) : (left -= v) try text.appendSlice(r.allocator, d);
    }
}

const ONES = [_][]const u8{
    "zero",  "one",     "two",     "three",    "four",     "five",     "six",
    "seven", "eight",   "nine",    "ten",      "eleven",   "twelve",   "thirteen",
    "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
};
const TENS = [_][]const u8{
    "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
};
/// The ordinal of each name in `ONES`, at the same index.
const ONES_ORDINAL = [_][]const u8{
    "zeroth",     "first",       "second",      "third",       "fourth",
    "fifth",      "sixth",       "seventh",     "eighth",      "ninth",
    "tenth",      "eleventh",    "twelfth",     "thirteenth",  "fourteenth",
    "fifteenth",  "sixteenth",   "seventeenth", "eighteenth",  "nineteenth",
};
const TENS_ORDINAL = [_][]const u8{
    "", "", "twentieth", "thirtieth", "fortieth", "fiftieth",
    "sixtieth", "seventieth", "eightieth", "ninetieth",
};
/// Names for each group of three digits, least significant first.
const SCALE = [_][]const u8{
    "",            "thousand",    "million",     "billion",     "trillion",
    "quadrillion", "quintillion", "sextillion",  "septillion",  "octillion",
    "nonillion",   "decillion",   "undecillion", "duodecillion",
};

/// Spell out `n` in English, as `~R` does with no radix parameter.
fn appendCardinal(r: *Runner, n: i64, text: *std.ArrayList(u8)) Error!void {
    if (n < 0) {
        try text.appendSlice(r.allocator, "negative ");
        return appendMagnitude(r, @abs(n), text);
    }
    return appendMagnitude(r, @abs(n), text);
}

fn appendMagnitude(r: *Runner, magnitude: u64, text: *std.ArrayList(u8)) Error!void {
    if (magnitude == 0) return text.appendSlice(r.allocator, "zero");

    var groups: [SCALE.len]u16 = undefined;
    var used: usize = 0;
    var left = magnitude;
    while (left != 0) : (left /= 1000) {
        if (used == SCALE.len) return Error.ProgramError;
        groups[used] = @intCast(left % 1000);
        used += 1;
    }

    var written = false;
    var index = used;
    while (index > 0) {
        index -= 1;
        if (groups[index] == 0) continue;
        if (written) try text.append(r.allocator, ' ');
        try appendGroup(r, groups[index], text);
        if (index != 0) {
            try text.append(r.allocator, ' ');
            try text.appendSlice(r.allocator, SCALE[index]);
        }
        written = true;
    }
}

/// One group of three digits, which is where the hyphen between tens and
/// ones belongs.
fn appendGroup(r: *Runner, group: u16, text: *std.ArrayList(u8)) Error!void {
    const hundreds = group / 100;
    const rest = group % 100;
    if (hundreds != 0) {
        try text.appendSlice(r.allocator, ONES[hundreds]);
        try text.appendSlice(r.allocator, " hundred");
        if (rest != 0) try text.append(r.allocator, ' ');
    }
    if (rest == 0) return;
    if (rest < 20) return text.appendSlice(r.allocator, ONES[rest]);
    try text.appendSlice(r.allocator, TENS[rest / 10]);
    if (rest % 10 != 0) {
        try text.append(r.allocator, '-');
        try text.appendSlice(r.allocator, ONES[rest % 10]);
    }
}

/// `~:R`: the cardinal with its last word turned into an ordinal.
fn appendOrdinal(r: *Runner, n: i64, text: *std.ArrayList(u8)) Error!void {
    if (n < 0) {
        try text.appendSlice(r.allocator, "negative ");
        return appendOrdinalMagnitude(r, @abs(n), text);
    }
    return appendOrdinalMagnitude(r, @abs(n), text);
}

fn appendOrdinalMagnitude(r: *Runner, magnitude: u64, text: *std.ArrayList(u8)) Error!void {
    if (magnitude == 0) return text.appendSlice(r.allocator, "zeroth");
    const tail = magnitude % 100;
    // The ordinal falls on the last word, so everything before the final
    // group of two digits is spelled out as a cardinal.
    if (tail == 0) {
        var cardinal: std.ArrayList(u8) = .empty;
        try appendMagnitude(r, magnitude, &cardinal);
        return appendLastWordOrdinal(r, cardinal.items, text);
    }
    if (magnitude > 99) {
        try appendMagnitude(r, magnitude - tail, text);
        try text.append(r.allocator, ' ');
    }
    if (tail < 20) return text.appendSlice(r.allocator, ONES_ORDINAL[tail]);
    if (tail % 10 == 0) return text.appendSlice(r.allocator, TENS_ORDINAL[tail / 10]);
    try text.appendSlice(r.allocator, TENS[tail / 10]);
    try text.append(r.allocator, '-');
    try text.appendSlice(r.allocator, ONES_ORDINAL[tail % 10]);
}

/// Turn the final word of a spelled-out cardinal into its ordinal, which
/// is what a number ending in two zeros needs.
fn appendLastWordOrdinal(r: *Runner, cardinal: []const u8, text: *std.ArrayList(u8)) Error!void {
    const split = std.mem.lastIndexOfAny(u8, cardinal, " -") orelse 0;
    const head = if (split == 0) "" else cardinal[0 .. split + 1];
    const last = if (split == 0) cardinal else cardinal[split + 1 ..];
    try text.appendSlice(r.allocator, head);
    if (std.mem.eql(u8, last, "hundred")) {
        return text.appendSlice(r.allocator, "hundredth");
    }
    for (SCALE[1..]) |name| {
        if (std.mem.eql(u8, last, name)) {
            try text.appendSlice(r.allocator, name);
            return text.appendSlice(r.allocator, "th");
        }
    }
    for (ONES, ONES_ORDINAL) |name, ordinal| {
        if (std.mem.eql(u8, last, name)) return text.appendSlice(r.allocator, ordinal);
    }
    for (TENS, TENS_ORDINAL) |name, ordinal| {
        if (name.len != 0 and std.mem.eql(u8, last, name)) {
            return text.appendSlice(r.allocator, ordinal);
        }
    }
    try text.appendSlice(r.allocator, last);
    try text.appendSlice(r.allocator, "th");
}

/// `~C`: the character itself, `:` its name where it has one, `@` the
/// `#\` form the reader takes back.
fn printCharacter(r: *Runner, directive: Directive, args: *Args) Error!void {
    const arg = try args.next();
    if (arg.tag() != .char) return Error.TypeError;
    const c = arg.toChar();
    if (directive.at and !directive.colon) {
        return r.out.writeText(try render(r, arg, prin1Settings(r.ev)));
    }
    if (directive.colon) {
        var buf: [character.NAME_BUFFER]u8 = undefined;
        if (character.nameForCodeInto(c, &buf)) |name| return r.out.writeText(name);
        return r.out.writeChar(c);
    }
    try r.out.writeChar(c);
}

// --- floating point ---

/// A real argument, with the width it was printed at: a single-float
/// reads back from fewer digits than its double expansion carries, and
/// `~F` has to stop where the value stops being meaningful.
const Real = struct { x: f64, single: bool };

fn realValue(v: Value) ?Real {
    if (v.isFixnum()) return .{ .x = equality.toF64(v), .single = false };
    if (v.tag() != .heap) return null;
    return switch (heap.heapType(v)) {
        .single_float => .{ .x = equality.toF64(v), .single = true },
        .double_float, .bignum, .ratio => .{ .x = equality.toF64(v), .single = false },
        else => null,
    };
}

fn scaled(real: Real, k: i64) Real {
    return .{ .x = real.x * std.math.pow(f64, 10, @floatFromInt(k)), .single = real.single };
}

/// The digits of `x` with `precision` places after the point, or the
/// shortest run that reads back as `x` when `precision` is null. The sign
/// is not included.
fn decimalDigits(r: *Runner, real: Real, precision: ?usize) Error![]const u8 {
    var buf: [4096]u8 = undefined;
    const options: std.fmt.float.Options = .{ .mode = .decimal, .precision = precision };
    // A count of places asks for the value's own digits, which the double
    // an f32 widens to holds exactly. Without one the shortest run that
    // reads back is wanted, and for an f32 that is shorter.
    const rendered = if (real.single and precision == null)
        std.fmt.float.render(&buf, @as(f32, @floatCast(@abs(real.x))), options) catch
            return Error.ProgramError
    else
        std.fmt.float.render(&buf, @abs(real.x), options) catch return Error.ProgramError;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(r.allocator, rendered);
    if (std.mem.indexOfScalar(u8, text.items, '.') == null) {
        try text.append(r.allocator, '.');
    }
    return text.items;
}

/// Sign, digits, then padding to `width` — the shape `~F`, `~E` and `~$`
/// all finish with. An `overflow` character replaces the lot when what
/// was produced is wider than `width`.
fn padNumber(
    r: *Runner,
    body: []const u8,
    sign: []const u8,
    width: ?i64,
    padchar: u21,
    overflow: ?u21,
    sign_before_pad: bool,
) Error!void {
    const total: i64 = @intCast(utf8Count(body) + sign.len);
    const w = width orelse {
        try r.out.writeText(sign);
        return r.out.writeText(body);
    };
    if (total > w) {
        if (overflow) |c| return r.out.repeat(c, @intCast(w));
        try r.out.writeText(sign);
        return r.out.writeText(body);
    }
    if (sign_before_pad) try r.out.writeText(sign);
    try r.out.repeat(padchar, @intCast(w - total));
    if (!sign_before_pad) try r.out.writeText(sign);
    try r.out.writeText(body);
}

fn signText(real: Real, at: bool) []const u8 {
    // A negative zero prints its sign, which is what reads back as the
    // same float.
    if (std.math.signbit(real.x)) return "-";
    return if (at) "+" else "";
}

/// `~w,d,k,overflowchar,padcharF`: fixed-format floating point.
fn printFixed(r: *Runner, directive: Directive, args: *Args) Error!void {
    const width = try optional(r, directive, 0, args);
    const places = try optional(r, directive, 1, args);
    const scale = try r.param(directive, 2, args, 0);
    const overflow = try optionalChar(r, directive, 3, args);
    const padchar: u21 = @intCast(try r.param(directive, 4, args, ' '));
    const arg = try args.next();

    const x = realValue(arg) orelse {
        // CLHS 22.3.3: a non-real prints as if by ~wD.
        return writeAsDecimal(r, arg, width);
    };
    const value_scaled = scaled(x, scale);
    const sign = signText(value_scaled, directive.at);

    const digits = if (places) |d|
        try trimLeadingZero(try decimalDigits(r, value_scaled, @intCast(@max(d, 0))), width, sign.len)
    else
        try fitDigits(r, value_scaled, width, sign.len);
    try padNumber(r, digits, sign, width, padchar, overflow, false);
}

/// The digits of a `~F` that was given no count of places: as many as the
/// width leaves, and never none. Where even one place overruns the width,
/// the zero before the point goes instead.
fn fitDigits(r: *Runner, x: Real, width: ?i64, sign_len: usize) Error![]const u8 {
    const shortest = try withFraction(r, try decimalDigits(r, x, null));
    const w = width orelse return shortest;
    const room = w - @as(i64, @intCast(sign_len));
    const point: i64 = @intCast(std.mem.indexOfScalar(u8, shortest, '.').?);
    const wanted = @max(room - point - 1, 0);
    if (wanted >= @as(i64, @intCast(shortest.len)) - point - 1) return shortest;

    const rounded = try withFraction(r, try decimalDigits(r, x, @intCast(wanted)));
    return trimLeadingZero(rounded, w, sign_len);
}

/// The zero before the point goes when what was produced is wider than
/// the width allows, which is what makes `~3,2F` of a half print `.50`.
fn trimLeadingZero(digits: []const u8, width: ?i64, sign_len: usize) Error![]const u8 {
    const w = width orelse return digits;
    const total: i64 = @intCast(utf8Count(digits) + sign_len);
    if (total <= w) return digits;
    if (digits.len < 2 or digits[0] != '0' or digits[1] != '.') return digits;
    // Dropping the zero has to leave a digit behind: `0.` would come to
    // a bare point, which reads back as nothing.
    if (digits.len == 2) return digits;
    return digits[1..];
}

/// A fixed-format number always shows a digit after the point when it was
/// not told how many to show.
fn withFraction(r: *Runner, digits: []const u8) Error![]const u8 {
    if (digits[digits.len - 1] != '.') return digits;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(r.allocator, digits);
    try text.append(r.allocator, '0');
    return text.items;
}

fn writeAsDecimal(r: *Runner, arg: Value, width: ?i64) Error!void {
    var settings = princSettings(r.ev);
    settings.base = 10;
    settings.radix = false;
    const text = try render(r, arg, settings);
    const w = width orelse return r.out.writeText(text);
    const printed: i64 = @intCast(utf8Count(text));
    if (printed < w) try r.out.repeat(' ', @intCast(w - printed));
    try r.out.writeText(text);
}

/// A parameter that is meaningfully absent, rather than defaulted.
fn optional(r: *Runner, directive: Directive, slot: usize, args: *Args) Error!?i64 {
    if (directive.params[slot] == .absent) return null;
    const held = try r.param(directive, slot, args, std.math.minInt(i64));
    return if (held == std.math.minInt(i64)) null else held;
}

fn optionalChar(r: *Runner, directive: Directive, slot: usize, args: *Args) Error!?u21 {
    const held = try optional(r, directive, slot, args) orelse return null;
    if (held < 0 or held > 0x10FFFF) return Error.ProgramError;
    return @intCast(held);
}

/// `~w,d,e,k,overflowchar,padchar,exponentcharE`: exponential notation.
fn printExponential(r: *Runner, directive: Directive, args: *Args) Error!void {
    const width = try optional(r, directive, 0, args);
    const places = try optional(r, directive, 1, args);
    const exp_digits = try optional(r, directive, 2, args);
    const scale = try r.param(directive, 3, args, 1);
    const overflow = try optionalChar(r, directive, 4, args);
    const padchar: u21 = @intCast(try r.param(directive, 5, args, ' '));
    const marker = try optionalChar(r, directive, 6, args);
    const arg = try args.next();

    const x = realValue(arg) orelse return writeAsDecimal(r, arg, width);
    const sign = signText(x, directive.at);
    const room: ?i64 = if (width) |w| w - @as(i64, @intCast(sign.len)) else null;
    const body = try exponentialText(r, x, places, exp_digits, scale, marker orelse 'e', room);
    try padNumber(r, body, sign, width, padchar, overflow, false);
}

/// The mantissa and exponent of `x`, with `scale` digits ahead of the
/// point. A scale of one is the default `d.dddEsdd` shape; zero puts the
/// point first, and a larger scale shifts more digits before it.
///
/// `room` is what the width leaves for the whole thing. Without a count
/// of places the mantissa fills what is left of it once the exponent has
/// taken its share, and shows one zero after the point where that fits.
fn exponentialText(
    r: *Runner,
    x: Real,
    places: ?i64,
    exp_digits: ?i64,
    scale: i64,
    marker: u21,
    room: ?i64,
) Error![]const u8 {
    const magnitude = @abs(x.x);
    var exponent: i64 = 0;
    if (magnitude != 0) {
        exponent = @intFromFloat(@floor(@log10(magnitude)));
        // The logarithm can land either side of a power of ten, so the
        // mantissa is checked against its range and stepped into it.
        while (magnitude / std.math.pow(f64, 10, @floatFromInt(exponent)) >= 10) exponent += 1;
        while (magnitude / std.math.pow(f64, 10, @floatFromInt(exponent)) < 1) exponent -= 1;
    }
    const shift = scale - 1;
    var printed_exponent = exponent - shift;
    var mantissa = Real{
        .x = magnitude / std.math.pow(f64, 10, @floatFromInt(printed_exponent)),
        .single = x.single,
    };

    var digits = try mantissaDigits(r, mantissa, places, scale);
    // Rounding can carry the mantissa up to the next power of ten.
    if (mantissaOverflowed(digits, scale)) {
        printed_exponent += 1;
        mantissa.x = magnitude / std.math.pow(f64, 10, @floatFromInt(printed_exponent));
        digits = try mantissaDigits(r, mantissa, places, scale);
    }

    var exponent_text: std.ArrayList(u8) = .empty;
    try appendChar(r, &exponent_text, marker);
    try exponent_text.append(r.allocator, if (printed_exponent < 0) '-' else '+');
    var buf: [32]u8 = undefined;
    const printed = std.fmt.bufPrint(&buf, "{d}", .{@abs(printed_exponent)}) catch
        return Error.ProgramError;
    if (exp_digits) |wanted| {
        var i: i64 = wanted - @as(i64, @intCast(printed.len));
        while (i > 0) : (i -= 1) try exponent_text.append(r.allocator, '0');
    }
    try exponent_text.appendSlice(r.allocator, printed);

    if (places == null) {
        const left = if (room) |w| w - @as(i64, @intCast(utf8Count(exponent_text.items))) else null;
        digits = try fitMantissa(r, mantissa, digits, left);
    }

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(r.allocator, digits);
    try text.appendSlice(r.allocator, exponent_text.items);
    return text.items;
}

fn mantissaDigits(r: *Runner, mantissa: Real, places: ?i64, scale: i64) Error![]const u8 {
    const d = places orelse return decimalDigits(r, mantissa, null);
    const before: i64 = @max(scale, 1);
    return decimalDigits(r, mantissa, @intCast(@max(d - before + 1, 0)));
}

/// Round the mantissa to what the width leaves it, and show one zero
/// after the point where there is space for it.
fn fitMantissa(r: *Runner, mantissa: Real, shortest: []const u8, room: ?i64) Error![]const u8 {
    const w = room orelse return withFraction(r, shortest);
    const point: i64 = @intCast(std.mem.indexOfScalar(u8, shortest, '.').?);
    const fraction: i64 = @as(i64, @intCast(shortest.len)) - point - 1;
    const wanted = @max(w - point - 1, 0);
    const digits = if (wanted < fraction)
        try decimalDigits(r, mantissa, @intCast(wanted))
    else
        shortest;
    if (digits[digits.len - 1] != '.') return digits;
    if (@as(i64, @intCast(digits.len)) + 1 > w) return digits;
    return withFraction(r, digits);
}

/// Whether rounding pushed the mantissa to or past the next power of ten.
fn mantissaOverflowed(digits: []const u8, scale: i64) bool {
    const point = std.mem.indexOfScalar(u8, digits, '.') orelse digits.len;
    const wanted: usize = @intCast(@max(scale, 1));
    return point > wanted;
}

fn appendChar(r: *Runner, text: *std.ArrayList(u8), c: u21) Error!void {
    var buf: [4]u8 = undefined;
    const width = std.unicode.utf8Encode(c, &buf) catch return Error.ProgramError;
    try text.appendSlice(r.allocator, buf[0..width]);
}

/// Every `v` and `#` parameter replaced by what it stands for, so a
/// directive that has to look at its parameters before running takes
/// each one off the argument list exactly once. A `v` holding nil counts
/// as a parameter that was not given.
fn resolveParams(r: *Runner, directive: Directive, args: *Args) Error!Directive {
    var resolved = directive;
    for (&resolved.params, 0..) |*p, slot| {
        switch (p.*) {
            .absent, .number => {},
            .next_arg => {
                if (args.remaining() != 0 and args.items[args.index].equalsRaw(value.NIL)) {
                    _ = try args.next();
                    p.* = .absent;
                } else {
                    p.* = .{ .number = try r.param(directive, slot, args, 0) };
                }
            },
            .arg_count => p.* = .{ .number = @intCast(args.remaining()) },
        }
    }
    return resolved;
}

/// `~G`: fixed format for a number close to one, exponential otherwise.
/// The choice follows CLHS 22.3.3.3, which reads the magnitude rather
/// than the printed width.
fn printGeneral(r: *Runner, directive: Directive, args: *Args) Error!void {
    const resolved = try resolveParams(r, directive, args);
    if (args.remaining() == 0) return Error.ProgramError;
    const arg = args.items[args.index];
    const x = realValue(arg) orelse {
        _ = try args.next();
        return writeAsDecimal(r, arg, try optional(r, resolved, 0, args));
    };
    const magnitude = @abs(x.x);
    const exponent: i64 = if (magnitude == 0) 0 else @intFromFloat(@floor(@log10(magnitude)));
    const digits = try optional(r, resolved, 1, args) orelse 7;
    if (magnitude != 0 and (exponent < -1 or exponent >= digits)) {
        return printExponential(r, resolved, args);
    }
    var fixed = resolved;
    // ~G spends its third parameter on the exponent digits, which the
    // fixed form has no use for, and its scale factor stays at zero.
    fixed.params[2] = .absent;
    fixed.params[3] = fixed.params[4];
    fixed.params[4] = fixed.params[5];
    try printFixed(r, fixed, args);
    // CLHS 22.3.3.3: the fixed form is followed by as many spaces as the
    // exponent it did not print would have taken.
    try r.out.repeat(' ', 4);
}

/// `~d,n,w,padchar$`: a fixed number of places after the point, and at
/// least `n` digits before it.
fn printMonetary(r: *Runner, directive: Directive, args: *Args) Error!void {
    const places: usize = @intCast(try r.count(directive, 0, args, 2));
    const before: usize = @intCast(try r.count(directive, 1, args, 1));
    const width = try optional(r, directive, 2, args);
    const padchar: u21 = @intCast(try r.param(directive, 3, args, ' '));
    const arg = try args.next();

    const x = realValue(arg) orelse return writeAsDecimal(r, arg, width);
    const digits = try decimalDigits(r, x, places);
    const point = std.mem.indexOfScalar(u8, digits, '.').?;

    var body: std.ArrayList(u8) = .empty;
    var leading = before;
    while (leading > point) : (leading -= 1) try body.append(r.allocator, '0');
    try body.appendSlice(r.allocator, digits);

    try padNumber(r, body.items, signText(x, directive.at), width, padchar, null, directive.colon);
}
