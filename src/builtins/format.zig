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
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

pub fn prin1Settings(ev: *Evaluator) printer.Settings {
    return .{ .escape = true, .current_package = ev.interner.currentPackage() };
}

pub fn princSettings(ev: *Evaluator) printer.Settings {
    return .{ .escape = false, .current_package = ev.interner.currentPackage() };
}

/// True when `*print-circle*` asks for shared structure to be labelled.
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

const MAX_PARAMS = 4;

const Directive = struct {
    params: [MAX_PARAMS]Param = .{ .absent, .absent, .absent, .absent },
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

fn parseNode(p: *Parser, directive: Directive) Error!Node {
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
        'A', 'S', 'D', '%', '&', '~', '*', 'T', '?', '^', 'P', '_', 'I', 'W' => .{ .simple = directive },
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
    while (true) {
        const block = try parseBlock(p, ">;");
        try segments.append(p.allocator, block.nodes);
        if (block.stop.char == '>') break;
        if (block.stop.colon and segments.items.len == 1) has_overflow = true;
    }
    return .{
        .directive = directive,
        .segments = try segments.toOwnedSlice(p.allocator),
        .has_overflow = has_overflow,
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
    while (i < p.ctrl.len and isDigit(p.ctrl[i])) : (i += 1) {
        n = n * 10 + @as(i64, @intCast(p.ctrl[i] - '0'));
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
                if (!v.isFixnum()) return Error.TypeError;
                break :blk v.toFixnum();
            },
        };
    }

    fn count(self: *Runner, directive: Directive, slot: usize, args: *Args, default: i64) Error!usize {
        const n = try self.param(directive, slot, args, default);
        if (n < 0) return Error.ProgramError;
        return @intCast(n);
    }
};

pub fn run(ev: *Evaluator, out: Output, ctrl: []const u32, args: []const Value) Error!void {
    var arena = std.heap.ArenaAllocator.init(ev.allocator);
    defer arena.deinit();

    var parser = Parser{ .allocator = arena.allocator(), .ctrl = ctrl };
    const block = try parseBlock(&parser, "");

    var runner = Runner{ .ev = ev, .out = out, .allocator = arena.allocator() };
    var cursor = Args{ .items = args };
    _ = try runNodes(&runner, block.nodes, &cursor);
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
        'D' => try printDecimal(r, directive, args),
        '%' => try r.out.repeat('\n', try r.count(directive, 0, args, 1)),
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

/// `~<...~>`: the segments run in order. An overflow segment (the one
/// before `~:;`) is what a line break would use, so it is dropped here.
fn runJustification(r: *Runner, j: Justification, args: *Args) Error!Flow {
    const segments = if (j.has_overflow and j.segments.len > 1) j.segments[1..] else j.segments;
    for (segments) |segment| {
        const flow = try runNodes(r, segment, args);
        if (flow != .normal) return flow;
    }
    return .normal;
}

/// `~A` / `~S`: print the argument, then pad to `mincol` in `colinc` steps.
/// With `@` the padding goes on the left instead.
fn printPadded(r: *Runner, directive: Directive, args: *Args, settings: printer.Settings) Error!void {
    const mincol = try r.param(directive, 0, args, 0);
    const colinc = @max(try r.param(directive, 1, args, 1), 1);
    const minpad = try r.param(directive, 2, args, 0);
    const padchar: u21 = @intCast(try r.param(directive, 3, args, ' '));
    const arg = try args.next();

    const text = try render(r, arg, settings);
    var pad: i64 = minpad;
    const width: i64 = @intCast(utf8Count(text));
    while (width + pad < mincol) pad += colinc;
    const pad_count: usize = @intCast(@max(pad, 0));

    if (directive.at) try r.out.repeat(padchar, pad_count);
    try r.out.writeText(text);
    if (!directive.at) try r.out.repeat(padchar, pad_count);
}

fn render(r: *Runner, v: Value, settings: printer.Settings) Error![]const u8 {
    var rendered = std.Io.Writer.Allocating.init(r.allocator);
    try printer.write(r.allocator, &rendered.writer, v, settings);
    return rendered.written();
}

/// `~D`: decimal, right-aligned in `mincol`, with `:` grouping digits.
fn printDecimal(r: *Runner, directive: Directive, args: *Args) Error!void {
    const mincol = try r.param(directive, 0, args, 0);
    const padchar: u21 = @intCast(try r.param(directive, 1, args, ' '));
    const comma: u8 = @intCast(try r.param(directive, 2, args, ','));
    const interval: usize = @intCast(@max(try r.param(directive, 3, args, 3), 1));
    const arg = try args.next();

    var text: std.ArrayList(u8) = .empty;
    if (!arg.isFixnum()) {
        // CLHS 22.3.2: a non-integer prints as if by ~A, still padded.
        try text.appendSlice(r.allocator, try render(r, arg, princSettings(r.ev)));
    } else {
        var buf: [32]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(arg.toFixnum())}) catch
            return Error.ProgramError;
        if (arg.toFixnum() < 0) {
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

/// `~:D` inserts `comma` every `interval` digits.
fn appendGrouped(
    r: *Runner,
    digits: []const u8,
    comma: u8,
    interval: usize,
    text: *std.ArrayList(u8),
) Error!void {
    for (digits, 0..) |d, i| {
        const remaining = digits.len - i;
        if (i != 0 and remaining % interval == 0) try text.append(r.allocator, comma);
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
    const given = countParams(directive);
    if (given == 0) {
        return if (args.remaining() == 0) level else .normal;
    }
    const first = try r.param(directive, 0, args, 0);
    if (given == 1) return if (first == 0) level else .normal;
    const second = try r.param(directive, 1, args, 0);
    if (given == 2) return if (first == second) level else .normal;
    const third = try r.param(directive, 2, args, 0);
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

/// The name between the slashes, optionally `package:name`, upcased.
fn resolveCallName(r: *Runner, name: []const u32) Error!Value {
    var upper: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (c >= 128) return Error.ProgramError;
        try upper.append(r.allocator, std.ascii.toUpper(@intCast(c)));
    }
    const text = upper.items;

    const bare = if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| text[colon + 1 ..] else text;
    const sym = r.ev.interner.lookup(bare) orelse return Error.UnboundFunction;
    return r.ev.env.lookupFunction(sym) orelse r.ev.unbound(sym, Error.UnboundFunction);
}
