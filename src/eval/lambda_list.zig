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
    has_whole: bool = false,
    whole: Value = undefined,
    has_env: bool = false,
    env_var: Value = undefined,
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

fn markerSection(name: []const u8, macro: bool) ?Section {
    if (std.mem.eql(u8, name, "&OPTIONAL")) return .optional;
    if (std.mem.eql(u8, name, "&REST")) return .rest;
    if (macro and std.mem.eql(u8, name, "&BODY")) return .rest;
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

/// A binding target is a symbol, or — in macro lambda lists — a nested
/// destructuring pattern.
fn isTarget(v: Value, macro: bool) bool {
    return v.isSymbol() or (macro and v.isCons());
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

fn parse(ev: *Evaluator, params: Value, macro: bool, top: bool) Error!Parsed {
    var p: Parsed = .{};
    errdefer p.deinit(ev.allocator);

    var section: Section = .required;
    var rest_filled = false;
    var rest_seen = false;
    var expect_env = false;

    var cur = params;

    if (macro and cur.isCons()) {
        const first = heap.car(cur);
        if (first.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(first).name, "&WHOLE")) {
            const tail = heap.cdr(cur);
            if (!tail.isCons()) return Error.BadArgList;
            const whole_var = heap.car(tail);
            if (!isTarget(whole_var, macro)) return Error.TypeError;
            p.has_whole = true;
            p.whole = whole_var;
            cur = heap.cdr(tail);
        }
    }

    while (!cur.equalsRaw(value.NIL)) {
        if (!cur.isCons()) {
            // Dotted lambda list: the terminating atom is a rest variable.
            if (!macro or !cur.isSymbol()) return Error.BadArgList;
            if (rest_seen or section == .key or section == .aux) return Error.BadArgList;
            p.has_rest = true;
            p.rest = cur;
            break;
        }
        const elem = heap.car(cur);
        cur = heap.cdr(cur);

        if (expect_env) {
            if (!elem.isSymbol()) return Error.TypeError;
            p.has_env = true;
            p.env_var = elem;
            expect_env = false;
            continue;
        }

        if (elem.isSymbol()) {
            const name = symbol_mod.symbol(elem).name;
            if (std.mem.eql(u8, name, "&ALLOW-OTHER-KEYS")) {
                p.allow_other = true;
                continue;
            }
            if (macro and std.mem.eql(u8, name, "&ENVIRONMENT")) {
                if (!top or p.has_env) return Error.BadArgList;
                expect_env = true;
                continue;
            }
            if (macro and std.mem.eql(u8, name, "&WHOLE")) return Error.BadArgList;
            if (markerSection(name, macro)) |sec| {
                section = sec;
                if (sec == .rest) rest_seen = true;
                if (sec == .key) p.has_key = true;
                continue;
            }
        }

        switch (section) {
            .required => {
                if (!isTarget(elem, macro)) return Error.TypeError;
                try p.required.append(ev.allocator, elem);
            },
            .optional => {
                if (elem.isSymbol()) {
                    try p.optional.append(ev.allocator, .{ .name = elem, .init = value.NIL, .supplied = value.NIL });
                } else if (elem.isCons()) {
                    const name = heap.car(elem);
                    if (!isTarget(name, macro)) return Error.TypeError;
                    const is = try parseInitSupplied(heap.cdr(elem));
                    try p.optional.append(ev.allocator, .{ .name = name, .init = is.init, .supplied = is.supplied });
                } else return Error.BadArgList;
            },
            .rest => {
                if (rest_filled) return Error.BadArgList;
                if (!isTarget(elem, macro)) return Error.TypeError;
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
                        if (!isTarget(name, macro)) return Error.TypeError;
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
    if (expect_env) return Error.BadArgList;
    if (rest_seen and !rest_filled and !p.has_rest) return Error.BadArgList;
    return p;
}

/// Structural validation only — no argument binding, no init evaluation.
/// `macro` permits macro-lambda-list syntax (`&body`, `&whole`,
/// `&environment`, nested patterns, dotted lists).
pub fn validate(ev: *Evaluator, params: Value, macro: bool) Error!void {
    return validateInner(ev, params, macro, true);
}

fn validateInner(ev: *Evaluator, params: Value, macro: bool, top: bool) Error!void {
    var p = try parse(ev, params, macro, top);
    defer p.deinit(ev.allocator);
    if (!macro) return;
    if (p.has_whole and p.whole.isCons()) try validateInner(ev, p.whole, true, false);
    for (p.required.items) |r| {
        if (r.isCons()) try validateInner(ev, r, true, false);
    }
    for (p.optional.items) |o| {
        if (o.name.isCons()) try validateInner(ev, o.name, true, false);
    }
    if (p.has_rest and p.rest.isCons()) try validateInner(ev, p.rest, true, false);
    for (p.keys.items) |k| {
        if (k.name.isCons()) try validateInner(ev, k.name, true, false);
    }
}

/// Parse `params` and bind `args` into `frame`. Init forms are evaluated in
/// the current environment, so they see parameters bound earlier in the list.
pub fn bindInto(ev: *Evaluator, params: Value, args: []const Value, frame: *Frame) Error!void {
    var p = try parse(ev, params, false, true);
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
        for (remaining, 0..) |v, i| {
            if (i % 2 == 0 and !v.isSymbol()) return Error.ProgramError;
        }
        try bindKeys(ev, &p, remaining, frame);
    } else if (!p.has_rest and remaining.len > 0) {
        return Error.WrongArgCount;
    }

    for (p.aux.items) |a| {
        try frame.bind(ev.allocator, a.name, try ev.eval(a.init));
    }
}

/// Match parsed `&key` parameters against `pairs` (a flat keyword/value
/// sequence) and bind them into `frame`. Duplicate keywords: first wins.
fn bindKeys(ev: *Evaluator, p: *const Parsed, pairs: []const Value, frame: *Frame) Error!void {
    const aok = try ev.interner.intern(":ALLOW-OTHER-KEYS");

    var allow = p.allow_other;
    var j: usize = 0;
    while (j < pairs.len) : (j += 2) {
        if (pairs[j].equalsRaw(aok) and !pairs[j + 1].equalsRaw(value.NIL)) allow = true;
    }

    for (p.keys.items) |k| {
        var found = false;
        var jj: usize = 0;
        while (jj < pairs.len) : (jj += 2) {
            if (pairs[jj].equalsRaw(k.kw)) {
                try bindTarget(ev, k.name, pairs[jj + 1], frame);
                if (!k.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, k.supplied, value.T);
                found = true;
                break;
            }
        }
        if (!found) {
            try bindTarget(ev, k.name, try ev.eval(k.init), frame);
            if (!k.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, k.supplied, value.NIL);
        }
    }

    if (!allow) {
        var jj: usize = 0;
        while (jj < pairs.len) : (jj += 2) {
            const argkw = pairs[jj];
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
}

/// Bind a macro call `form` against a macro lambda list. `&whole` sees the
/// full form, the pattern proper destructures the form's cdr, and
/// `&environment` binds `env`.
pub fn bindMacro(ev: *Evaluator, params: Value, form: Value, env: Value, frame: *Frame) Error!void {
    if (!form.isCons()) return Error.TypeError;
    return destructure(ev, params, form, heap.cdr(form), env, true, frame);
}

/// Bind a destructuring pattern to `val` in `frame`, as `destructuring-bind`
/// does. The pattern may use the full macro lambda-list syntax except
/// `&environment`.
pub fn bindPattern(ev: *Evaluator, pattern: Value, val: Value, frame: *Frame) Error!void {
    return bindTarget(ev, pattern, val, frame);
}

/// Bind `target` (a symbol or a nested pattern) to `val`. NIL is the empty
/// pattern: it binds nothing and requires `val` to be NIL.
fn bindTarget(ev: *Evaluator, target: Value, val: Value, frame: *Frame) Error!void {
    if (target.equalsRaw(value.NIL)) {
        if (!val.equalsRaw(value.NIL)) return Error.WrongArgCount;
        return;
    }
    if (target.isSymbol()) return frame.bind(ev.allocator, target, val);
    if (target.isCons()) return destructure(ev, target, val, val, value.NIL, false, frame);
    return Error.TypeError;
}

fn destructure(ev: *Evaluator, params: Value, whole: Value, args: Value, env: Value, top: bool, frame: *Frame) Error!void {
    var p = try parse(ev, params, true, top);
    defer p.deinit(ev.allocator);

    if (p.has_whole) try bindTarget(ev, p.whole, whole, frame);
    if (p.has_env) try frame.bind(ev.allocator, p.env_var, env);

    var list = args;
    for (p.required.items) |r| {
        if (!list.isCons()) return Error.WrongArgCount;
        try bindTarget(ev, r, heap.car(list), frame);
        list = heap.cdr(list);
    }

    for (p.optional.items) |opt| {
        if (list.isCons()) {
            try bindTarget(ev, opt.name, heap.car(list), frame);
            list = heap.cdr(list);
            if (!opt.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, opt.supplied, value.T);
        } else {
            try bindTarget(ev, opt.name, try ev.eval(opt.init), frame);
            if (!opt.supplied.equalsRaw(value.NIL)) try frame.bind(ev.allocator, opt.supplied, value.NIL);
        }
    }

    if (p.has_rest) try bindTarget(ev, p.rest, list, frame);

    if (p.has_key) {
        var pairs: std.ArrayList(Value) = .empty;
        defer pairs.deinit(ev.allocator);
        var cur = list;
        while (!cur.equalsRaw(value.NIL)) {
            if (!cur.isCons()) return Error.BadArgList;
            const kw = heap.car(cur);
            if (!kw.isSymbol()) return Error.ProgramError;
            const next = heap.cdr(cur);
            if (!next.isCons()) return Error.ProgramError;
            try pairs.append(ev.allocator, kw);
            try pairs.append(ev.allocator, heap.car(next));
            cur = heap.cdr(next);
        }
        try bindKeys(ev, &p, pairs.items, frame);
    } else if (!p.has_rest and !list.equalsRaw(value.NIL)) {
        return Error.WrongArgCount;
    }

    for (p.aux.items) |a| {
        try frame.bind(ev.allocator, a.name, try ev.eval(a.init));
    }
}
