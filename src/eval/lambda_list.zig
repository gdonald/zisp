const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("eval.zig");
const env_mod = @import("env.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;
const Frame = env_mod.Frame;

const Section = enum { required, optional, rest, key, aux };

const Optional = struct { name: Value, init: Value, supplied: Value };
const Keyword = struct { kw: Value, name: Value, init: Value, supplied: Value };
const Aux = struct { name: Value, init: Value };

const Parsed = struct {
    required: std.ArrayList(Value) = .empty,
    optional: std.ArrayList(Optional) = .empty,
    has_rest: bool = false,
    rest: Value = undefined,
    has_key: bool = false,
    keys: std.ArrayList(Keyword) = .empty,
    allow_other: bool = false,
    aux: std.ArrayList(Aux) = .empty,

    fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        self.required.deinit(allocator);
        self.optional.deinit(allocator);
        self.keys.deinit(allocator);
        self.aux.deinit(allocator);
    }
};

fn markerSection(name: []const u8) ?Section {
    if (std.mem.eql(u8, name, "&OPTIONAL")) return .optional;
    if (std.mem.eql(u8, name, "&REST")) return .rest;
    if (std.mem.eql(u8, name, "&KEY")) return .key;
    if (std.mem.eql(u8, name, "&AUX")) return .aux;
    return null;
}

fn keywordOf(ev: *Evaluator, name_sym: Value) Error!Value {
    const name = symbol_mod.symbol(name_sym).name;
    const kw_name = try std.fmt.allocPrint(ev.allocator, ":{s}", .{name});
    defer ev.allocator.free(kw_name);
    return ev.interner.intern(kw_name);
}

/// Split a `(name [init [supplied]])` tail into its init form and supplied-p
/// variable. `entry` is the cons after the variable name (so the cdr of the
/// spec). Returns NIL for any part that is absent.
fn parseInitSupplied(tail: Value) Error!struct { init: Value, supplied: Value } {
    if (tail.equalsRaw(value.NIL)) return .{ .init = value.NIL, .supplied = value.NIL };
    if (!tail.isCons()) return Error.BadArgList;
    const init = heap.car(tail);
    const after_init = heap.cdr(tail);
    if (after_init.equalsRaw(value.NIL)) return .{ .init = init, .supplied = value.NIL };
    if (!after_init.isCons()) return Error.BadArgList;
    const supplied = heap.car(after_init);
    if (!supplied.isSymbol()) return Error.TypeError;
    if (!heap.cdr(after_init).equalsRaw(value.NIL)) return Error.BadArgList;
    return .{ .init = init, .supplied = supplied };
}

fn parse(ev: *Evaluator, params: Value) Error!Parsed {
    var p: Parsed = .{};
    errdefer p.deinit(ev.allocator);

    var section: Section = .required;
    var rest_filled = false;
    var rest_seen = false;

    var cur = params;
    while (!cur.equalsRaw(value.NIL)) {
        if (!cur.isCons()) return Error.BadArgList;
        const elem = heap.car(cur);
        cur = heap.cdr(cur);

        if (elem.isSymbol()) {
            const name = symbol_mod.symbol(elem).name;
            if (std.mem.eql(u8, name, "&ALLOW-OTHER-KEYS")) {
                p.allow_other = true;
                continue;
            }
            if (markerSection(name)) |sec| {
                section = sec;
                if (sec == .rest) rest_seen = true;
                if (sec == .key) p.has_key = true;
                continue;
            }
        }

        switch (section) {
            .required => {
                if (!elem.isSymbol()) return Error.TypeError;
                try p.required.append(ev.allocator, elem);
            },
            .optional => {
                if (elem.isSymbol()) {
                    try p.optional.append(ev.allocator, .{ .name = elem, .init = value.NIL, .supplied = value.NIL });
                } else if (elem.isCons()) {
                    const name = heap.car(elem);
                    if (!name.isSymbol()) return Error.TypeError;
                    const is = try parseInitSupplied(heap.cdr(elem));
                    try p.optional.append(ev.allocator, .{ .name = name, .init = is.init, .supplied = is.supplied });
                } else return Error.BadArgList;
            },
            .rest => {
                if (rest_filled) return Error.BadArgList;
                if (!elem.isSymbol()) return Error.TypeError;
                p.has_rest = true;
                p.rest = elem;
                rest_filled = true;
            },
            .key => {
                if (elem.isSymbol()) {
                    try p.keys.append(ev.allocator, .{
                        .kw = try keywordOf(ev, elem),
                        .name = elem,
                        .init = value.NIL,
                        .supplied = value.NIL,
                    });
                } else if (elem.isCons()) {
                    const head = heap.car(elem);
                    var kw: Value = undefined;
                    var name: Value = undefined;
                    if (head.isSymbol()) {
                        name = head;
                        kw = try keywordOf(ev, head);
                    } else if (head.isCons()) {
                        kw = heap.car(head);
                        if (!kw.isSymbol()) return Error.TypeError;
                        const name_tail = heap.cdr(head);
                        if (!name_tail.isCons()) return Error.BadArgList;
                        name = heap.car(name_tail);
                        if (!name.isSymbol()) return Error.TypeError;
                        if (!heap.cdr(name_tail).equalsRaw(value.NIL)) return Error.BadArgList;
                    } else return Error.BadArgList;
                    const is = try parseInitSupplied(heap.cdr(elem));
                    try p.keys.append(ev.allocator, .{ .kw = kw, .name = name, .init = is.init, .supplied = is.supplied });
                } else return Error.BadArgList;
            },
            .aux => {
                if (elem.isSymbol()) {
                    try p.aux.append(ev.allocator, .{ .name = elem, .init = value.NIL });
                } else if (elem.isCons()) {
                    const name = heap.car(elem);
                    if (!name.isSymbol()) return Error.TypeError;
                    const tail = heap.cdr(elem);
                    var init = value.NIL;
                    if (tail.isCons()) {
                        init = heap.car(tail);
                        if (!heap.cdr(tail).equalsRaw(value.NIL)) return Error.BadArgList;
                    } else if (!tail.equalsRaw(value.NIL)) return Error.BadArgList;
                    try p.aux.append(ev.allocator, .{ .name = name, .init = init });
                } else return Error.BadArgList;
            },
        }
    }
    if (rest_seen and !rest_filled) return Error.BadArgList;
    return p;
}

/// Structural validation only — no argument binding, no init evaluation.
pub fn validate(ev: *Evaluator, params: Value) Error!void {
    var p = try parse(ev, params);
    p.deinit(ev.allocator);
}

/// Parse `params` and bind `args` into `frame`. Init forms are evaluated in
/// the current environment, so they see parameters bound earlier in the list.
pub fn bindInto(ev: *Evaluator, params: Value, args: []const Value, frame: *Frame) Error!void {
    var p = try parse(ev, params);
    defer p.deinit(ev.allocator);

    if (args.len < p.required.items.len) return Error.WrongArgCount;
    var pos: usize = 0;
    for (p.required.items) |sym| {
        try frame.bind(ev.allocator, sym, args[pos]);
        pos += 1;
    }

    for (p.optional.items) |opt| {
        if (pos < args.len) {
            try frame.bind(ev.allocator, opt.name, args[pos]);
            pos += 1;
            if (!opt.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, opt.supplied, value.T);
        } else {
            try frame.bind(ev.allocator, opt.name, try ev.eval(opt.init));
            if (!opt.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, opt.supplied, value.NIL);
        }
    }

    const remaining = args[pos..];

    if (p.has_rest) {
        var list = value.NIL;
        var i = remaining.len;
        while (i > 0) {
            i -= 1;
            list = try ev.heap.allocCons(remaining[i], list);
        }
        try frame.bind(ev.allocator, p.rest, list);
    }

    if (p.has_key) {
        if (remaining.len % 2 != 0) return Error.ProgramError;
        const aok = try ev.interner.intern(":ALLOW-OTHER-KEYS");

        var allow = p.allow_other;
        var j: usize = 0;
        while (j < remaining.len) : (j += 2) {
            if (!remaining[j].isSymbol()) return Error.ProgramError;
            if (remaining[j].equalsRaw(aok) and !remaining[j + 1].equalsRaw(value.NIL)) allow = true;
        }

        for (p.keys.items) |k| {
            var found = false;
            var jj: usize = 0;
            while (jj < remaining.len) : (jj += 2) {
                if (remaining[jj].equalsRaw(k.kw)) {
                    try frame.bind(ev.allocator, k.name, remaining[jj + 1]);
                    if (!k.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, k.supplied, value.T);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try frame.bind(ev.allocator, k.name, try ev.eval(k.init));
                if (!k.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, k.supplied, value.NIL);
            }
        }

        if (!allow) {
            var jj: usize = 0;
            while (jj < remaining.len) : (jj += 2) {
                const argkw = remaining[jj];
                if (argkw.equalsRaw(aok)) continue;
                var known = false;
                for (p.keys.items) |k| {
                    if (k.kw.equalsRaw(argkw)) {
                        known = true;
                        break;
                    }
                }
                if (!known) return Error.ProgramError;
            }
        }
    } else if (!p.has_rest and remaining.len > 0) {
        return Error.WrongArgCount;
    }

    for (p.aux.items) |a| {
        try frame.bind(ev.allocator, a.name, try ev.eval(a.init));
    }
}
