const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("eval.zig");
const function = @import("function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;

pub fn registerStandard(ev: *Evaluator) !void {
    try ev.registerSpecialForm("QUOTE", &quote);
    try ev.registerSpecialForm("IF", &ifForm);
    try ev.registerSpecialForm("PROGN", &progn);
    try ev.registerSpecialForm("SETQ", &setq);
    try ev.registerSpecialForm("LET", &letForm);
    try ev.registerSpecialForm("LET*", &letStar);
    try ev.registerSpecialForm("LAMBDA", &lambda);
    try ev.registerSpecialForm("FUNCTION", &functionForm);
    try ev.registerSpecialForm("FLET", &flet);
    try ev.registerSpecialForm("LABELS", &labels);
    try ev.registerSpecialForm("BLOCK", &block);
    try ev.registerSpecialForm("RETURN-FROM", &returnFrom);
    try ev.registerSpecialForm("TAGBODY", &tagbody);
    try ev.registerSpecialForm("GO", &goForm);
}

fn quote(ev: *Evaluator, args: Value) Error!Value {
    _ = ev;
    return expectOneArg(args);
}

fn lambda(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const params = heap.car(args);
    const body = heap.cdr(args);
    try validateParams(params);
    return function.allocClosure(
        ev.heap.allocator,
        null,
        params,
        body,
        ev.env.top_value,
        ev.env.top_function,
    );
}

fn flet(ev: *Evaluator, args: Value) Error!Value {
    return localFunctions(ev, args, false);
}

fn labels(ev: *Evaluator, args: Value) Error!Value {
    return localFunctions(ev, args, true);
}

fn localFunctions(ev: *Evaluator, args: Value, recursive: bool) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const definitions = heap.car(args);
    const body = heap.cdr(args);

    const frame = try ev.env.pushFunctionFrame();
    defer ev.env.popFunctionFrame();

    // For LABELS the local functions see each other (and themselves), so they
    // capture the new frame. For FLET they capture the surrounding function
    // environment, so the definitions are invisible to one another.
    const captured_fenv = if (recursive) frame else frame.parent;

    var rest = definitions;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        const def = heap.car(rest);
        if (!def.isCons()) return Error.BadArgList;
        const name = heap.car(def);
        if (!name.isSymbol()) return Error.TypeError;
        const after_name = heap.cdr(def);
        if (!after_name.isCons()) return Error.BadArgList;
        const params = heap.car(after_name);
        const fn_body = heap.cdr(after_name);
        try validateParams(params);
        const closure = try function.allocClosure(
            ev.heap.allocator,
            symbol_mod.symbol(name).name,
            params,
            fn_body,
            ev.env.top_value,
            captured_fenv,
        );
        try frame.bind(ev.allocator, name, closure);
        rest = heap.cdr(rest);
    }

    return prognBody(ev, body);
}

fn functionForm(ev: *Evaluator, args: Value) Error!Value {
    const arg = try expectOneArg(args);
    if (arg.isSymbol()) {
        return ev.env.lookupFunction(arg) orelse Error.UnboundFunction;
    }
    if (!arg.isCons()) return Error.TypeError;
    const head = heap.car(arg);
    if (!head.isSymbol()) return Error.TypeError;
    const head_sym = symbol_mod.symbol(head);
    if (!std.mem.eql(u8, head_sym.name, "LAMBDA")) return Error.TypeError;
    return lambda(ev, heap.cdr(arg));
}

fn validateParams(params: Value) Error!void {
    var rest = params;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        const p = heap.car(rest);
        if (!p.isSymbol()) return Error.TypeError;
        rest = heap.cdr(rest);
    }
}

fn ifForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const test_form = heap.car(args);
    const rest = heap.cdr(args);
    if (!rest.isCons()) return Error.BadArgList;
    const then_form = heap.car(rest);
    const after_then = heap.cdr(rest);

    var else_form = value.NIL;
    var has_else = false;
    if (after_then.isCons()) {
        else_form = heap.car(after_then);
        has_else = true;
        if (!heap.cdr(after_then).equalsRaw(value.NIL)) return Error.BadArgList;
    } else if (!after_then.equalsRaw(value.NIL)) {
        return Error.BadArgList;
    }

    const test_val = try ev.eval(test_form);
    if (!test_val.equalsRaw(value.NIL)) {
        return ev.eval(then_form);
    }
    if (has_else) return ev.eval(else_form);
    return value.NIL;
}

fn progn(ev: *Evaluator, args: Value) Error!Value {
    return prognBody(ev, args);
}

fn prognBody(ev: *Evaluator, body: Value) Error!Value {
    var result = value.NIL;
    var rest = body;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        result = try ev.eval(heap.car(rest));
        rest = heap.cdr(rest);
    }
    return result;
}

fn setq(ev: *Evaluator, args: Value) Error!Value {
    var result = value.NIL;
    var rest = args;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        const sym = heap.car(rest);
        if (!sym.isSymbol()) return Error.TypeError;
        const after_sym = heap.cdr(rest);
        if (!after_sym.isCons()) return Error.BadArgList;
        const val = try ev.eval(heap.car(after_sym));
        ev.env.assignValue(sym, val);
        result = val;
        rest = heap.cdr(after_sym);
    }
    return result;
}

fn letForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const bindings = heap.car(args);
    const body = heap.cdr(args);

    var syms: std.ArrayList(Value) = .empty;
    defer syms.deinit(ev.allocator);
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(ev.allocator);

    var bind_rest = bindings;
    while (!bind_rest.equalsRaw(value.NIL)) {
        if (!bind_rest.isCons()) return Error.BadArgList;
        const pair = try parseBinding(heap.car(bind_rest));
        const init_val = if (pair.has_init) try ev.eval(pair.init) else value.NIL;
        try syms.append(ev.allocator, pair.sym);
        try vals.append(ev.allocator, init_val);
        bind_rest = heap.cdr(bind_rest);
    }

    _ = try ev.env.pushValueFrame();
    defer ev.env.popValueFrame();
    for (syms.items, vals.items) |s, v| {
        try ev.env.top_value.?.bind(ev.allocator, s, v);
    }
    return prognBody(ev, body);
}

fn letStar(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const bindings = heap.car(args);
    const body = heap.cdr(args);

    _ = try ev.env.pushValueFrame();
    defer ev.env.popValueFrame();

    var bind_rest = bindings;
    while (!bind_rest.equalsRaw(value.NIL)) {
        if (!bind_rest.isCons()) return Error.BadArgList;
        const pair = try parseBinding(heap.car(bind_rest));
        const init_val = if (pair.has_init) try ev.eval(pair.init) else value.NIL;
        try ev.env.top_value.?.bind(ev.allocator, pair.sym, init_val);
        bind_rest = heap.cdr(bind_rest);
    }

    return prognBody(ev, body);
}

const Binding = struct { sym: Value, init: Value, has_init: bool };

fn parseBinding(entry: Value) Error!Binding {
    if (entry.isSymbol()) {
        return .{ .sym = entry, .init = value.NIL, .has_init = false };
    }
    if (!entry.isCons()) return Error.BadArgList;
    const sym = heap.car(entry);
    if (!sym.isSymbol()) return Error.TypeError;
    const tail = heap.cdr(entry);
    if (tail.equalsRaw(value.NIL)) {
        return .{ .sym = sym, .init = value.NIL, .has_init = false };
    }
    if (!tail.isCons()) return Error.BadArgList;
    if (!heap.cdr(tail).equalsRaw(value.NIL)) return Error.BadArgList;
    return .{ .sym = sym, .init = heap.car(tail), .has_init = true };
}

fn block(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const name = heap.car(args);
    if (!name.isSymbol()) return Error.TypeError;
    const body = heap.cdr(args);

    const id = try ev.pushBlock(name);
    defer ev.popBlock();

    return prognBody(ev, body) catch |err| {
        if (err == Error.BlockReturn and ev.return_id == id) {
            return ev.return_value;
        }
        return err;
    };
}

fn returnFrom(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const name = heap.car(args);
    if (!name.isSymbol()) return Error.TypeError;
    const after_name = heap.cdr(args);

    var result = value.NIL;
    if (after_name.isCons()) {
        if (!heap.cdr(after_name).equalsRaw(value.NIL)) return Error.BadArgList;
        result = try ev.eval(heap.car(after_name));
    } else if (!after_name.equalsRaw(value.NIL)) {
        return Error.BadArgList;
    }

    const id = ev.findBlock(name) orelse return Error.ControlError;
    ev.return_id = id;
    ev.return_value = result;
    return Error.BlockReturn;
}

fn tagbody(ev: *Evaluator, args: Value) Error!Value {
    var v = args;
    while (!v.equalsRaw(value.NIL)) {
        if (!v.isCons()) return Error.BadArgList;
        v = heap.cdr(v);
    }

    const id = try ev.pushTagbody(args);
    defer ev.popTagbody();

    var pc = args;
    while (!pc.equalsRaw(value.NIL)) {
        const stmt = heap.car(pc);
        if (stmt.isCons()) {
            _ = ev.eval(stmt) catch |err| {
                if (err == Error.Go and ev.go_id == id) {
                    pc = ev.go_target;
                    continue;
                }
                return err;
            };
        }
        pc = heap.cdr(pc);
    }
    return value.NIL;
}

fn goForm(ev: *Evaluator, args: Value) Error!Value {
    const tag = try expectOneArg(args);
    if (!tag.isSymbol() and tag.tag() != .fixnum) return Error.TypeError;
    const target = ev.findTagbody(tag) orelse return Error.ControlError;
    ev.go_id = target.id;
    ev.go_target = target.pos;
    return Error.Go;
}

fn expectOneArg(args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    if (!heap.cdr(args).equalsRaw(value.NIL)) return Error.BadArgList;
    return heap.car(args);
}
