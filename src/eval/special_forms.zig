const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("eval.zig");
const function = @import("function.zig");
const lambda_list = @import("lambda_list.zig");

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
    try ev.registerSpecialForm("CATCH", &catchForm);
    try ev.registerSpecialForm("THROW", &throwForm);
    try ev.registerSpecialForm("UNWIND-PROTECT", &unwindProtect);
    try ev.registerSpecialForm("THE", &theForm);
    try ev.registerSpecialForm("DECLARE", &declareForm);
    try ev.registerSpecialForm("VALUES", &valuesForm);
    try ev.registerSpecialForm("VALUES-LIST", &valuesListForm);
    try ev.registerSpecialForm("MULTIPLE-VALUE-LIST", &multipleValueList);
    try ev.registerSpecialForm("MULTIPLE-VALUE-CALL", &multipleValueCall);
    try ev.registerSpecialForm("MULTIPLE-VALUE-PROG1", &multipleValueProg1);
    try ev.registerSpecialForm("MULTIPLE-VALUE-BIND", &multipleValueBind);
    try ev.registerSpecialForm("EVAL-WHEN", &evalWhen);
    try ev.registerSpecialForm("AND", &andForm);
    try ev.registerSpecialForm("OR", &orForm);
    try ev.registerSpecialForm("WHEN", &whenForm);
    try ev.registerSpecialForm("UNLESS", &unlessForm);
    try ev.registerSpecialForm("COND", &condForm);

    ev.sym_if = try ev.interner.intern("IF");
    ev.sym_progn = try ev.interner.intern("PROGN");
}

fn quote(ev: *Evaluator, args: Value) Error!Value {
    return ev.set1(try expectOneArg(args));
}

fn lambda(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const params = heap.car(args);
    const body = heap.cdr(args);
    try validateParams(ev, params);
    return ev.set1(try function.allocClosure(
        ev.heap.allocator,
        null,
        params,
        body,
        ev.env.top_value,
        ev.env.top_function,
    ));
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
        try validateParams(ev, params);
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
        const f = ev.env.lookupFunction(arg) orelse return Error.UnboundFunction;
        return ev.set1(f);
    }
    if (!arg.isCons()) return Error.TypeError;
    const head = heap.car(arg);
    if (!head.isSymbol()) return Error.TypeError;
    const head_sym = symbol_mod.symbol(head);
    if (!std.mem.eql(u8, head_sym.name, "LAMBDA")) return Error.TypeError;
    return lambda(ev, heap.cdr(arg));
}

fn validateParams(ev: *Evaluator, params: Value) Error!void {
    try lambda_list.validate(ev, params);
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
    return ev.set1(value.NIL);
}

fn progn(ev: *Evaluator, args: Value) Error!Value {
    return prognBody(ev, args);
}

fn prognBody(ev: *Evaluator, body: Value) Error!Value {
    if (!body.isCons()) {
        if (body.equalsRaw(value.NIL)) return ev.set1(value.NIL);
        return Error.BadArgList;
    }
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
    return ev.set1(result);
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
            return ev.unstashTransferValues();
        }
        return err;
    };
}

fn returnFrom(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const name = heap.car(args);
    if (!name.isSymbol()) return Error.TypeError;
    const after_name = heap.cdr(args);

    if (after_name.isCons()) {
        if (!heap.cdr(after_name).equalsRaw(value.NIL)) return Error.BadArgList;
        _ = try ev.eval(heap.car(after_name));
    } else if (!after_name.equalsRaw(value.NIL)) {
        return Error.BadArgList;
    } else {
        _ = try ev.set1(value.NIL);
    }

    const id = ev.findBlock(name) orelse return Error.ControlError;
    ev.return_id = id;
    try ev.stashTransferValues();
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
    return ev.set1(value.NIL);
}

fn goForm(ev: *Evaluator, args: Value) Error!Value {
    const tag = try expectOneArg(args);
    if (!tag.isSymbol() and tag.tag() != .fixnum) return Error.TypeError;
    const target = ev.findTagbody(tag) orelse return Error.ControlError;
    ev.go_id = target.id;
    ev.go_target = target.pos;
    return Error.Go;
}

fn catchForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const tag = try ev.eval(heap.car(args));
    const body = heap.cdr(args);

    const id = try ev.pushCatch(tag);
    defer ev.popCatch();

    return prognBody(ev, body) catch |err| {
        if (err == Error.Throw and ev.throw_id == id) {
            return ev.unstashTransferValues();
        }
        return err;
    };
}

fn throwForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const tag = try ev.eval(heap.car(args));
    const after_tag = heap.cdr(args);
    if (!after_tag.isCons()) return Error.BadArgList;
    if (!heap.cdr(after_tag).equalsRaw(value.NIL)) return Error.BadArgList;
    _ = try ev.eval(heap.car(after_tag));

    const id = ev.findCatch(tag) orelse return Error.ControlError;
    ev.throw_id = id;
    try ev.stashTransferValues();
    return Error.Throw;
}

fn unwindProtect(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const protected = heap.car(args);
    const cleanup = heap.cdr(args);

    _ = ev.eval(protected) catch |err| {
        // A non-local exit is in flight. Snapshot the transfer destination
        // and its carried value list so a normally-completing cleanup can't
        // clobber them, run the cleanup, restore, and re-raise.
        const saved = ev.saveTransferState();
        var saved_tv: std.ArrayList(Value) = .empty;
        defer saved_tv.deinit(ev.allocator);
        try saved_tv.appendSlice(ev.allocator, ev.transfer_values.items);

        _ = try prognBody(ev, cleanup);

        ev.restoreTransferState(saved);
        ev.transfer_values.clearRetainingCapacity();
        try ev.transfer_values.appendSlice(ev.allocator, saved_tv.items);
        return err;
    };

    // Normal completion: the protected form's value list must survive the
    // cleanup forms, which are evaluated only for effect.
    var saved_vals: std.ArrayList(Value) = .empty;
    defer saved_vals.deinit(ev.allocator);
    try saved_vals.appendSlice(ev.allocator, ev.values.items);

    _ = try prognBody(ev, cleanup);

    return ev.setValues(saved_vals.items);
}

fn theForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const after_type = heap.cdr(args);
    if (!after_type.isCons()) return Error.BadArgList;
    if (!heap.cdr(after_type).equalsRaw(value.NIL)) return Error.BadArgList;
    // The type specifier is accepted and ignored for now.
    return ev.eval(heap.car(after_type));
}

fn declareForm(ev: *Evaluator, args: Value) Error!Value {
    _ = args;
    return ev.set1(value.NIL);
}

fn evalWhen(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const situations = heap.car(args);
    const body = heap.cdr(args);

    // Without a compiler, only the :execute (and deprecated eval) situation
    // is meaningful; :compile-toplevel / :load-toplevel are accepted and
    // skipped here.
    var execute = false;
    var rest = situations;
    while (rest.isCons()) {
        const s = heap.car(rest);
        if (!s.isSymbol()) return Error.TypeError;
        const name = symbol_mod.symbol(s).name;
        if (std.mem.eql(u8, name, ":EXECUTE") or std.mem.eql(u8, name, "EVAL")) {
            execute = true;
        }
        rest = heap.cdr(rest);
    }
    if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;

    if (execute) return prognBody(ev, body);
    return ev.set1(value.NIL);
}

fn valuesForm(ev: *Evaluator, args: Value) Error!Value {
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(ev.allocator);
    var rest = args;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        try vals.append(ev.allocator, try ev.eval(heap.car(rest)));
        rest = heap.cdr(rest);
    }
    return ev.setValues(vals.items);
}

fn valuesListForm(ev: *Evaluator, args: Value) Error!Value {
    const list = try ev.eval(try expectOneArg(args));
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(ev.allocator);
    var rest = list;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.TypeError;
        try vals.append(ev.allocator, heap.car(rest));
        rest = heap.cdr(rest);
    }
    return ev.setValues(vals.items);
}

fn multipleValueList(ev: *Evaluator, args: Value) Error!Value {
    _ = try ev.eval(try expectOneArg(args));
    var list = value.NIL;
    var i = ev.values.items.len;
    while (i > 0) {
        i -= 1;
        list = try ev.heap.allocCons(ev.values.items[i], list);
    }
    return ev.set1(list);
}

fn multipleValueCall(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const callee = try resolveCallee(ev, try ev.eval(heap.car(args)));

    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(ev.allocator);
    var rest = heap.cdr(args);
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        _ = try ev.eval(heap.car(rest));
        try collected.appendSlice(ev.allocator, ev.values.items);
        rest = heap.cdr(rest);
    }
    return ev.callFunction(callee, collected.items);
}

fn resolveCallee(ev: *Evaluator, designator: Value) Error!Value {
    if (function.isFunction(designator)) return designator;
    if (designator.isSymbol()) {
        return ev.env.lookupFunction(designator) orelse Error.UnboundFunction;
    }
    return Error.TypeError;
}

fn multipleValueProg1(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    _ = try ev.eval(heap.car(args));

    var saved: std.ArrayList(Value) = .empty;
    defer saved.deinit(ev.allocator);
    try saved.appendSlice(ev.allocator, ev.values.items);

    var rest = heap.cdr(args);
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        _ = try ev.eval(heap.car(rest));
        rest = heap.cdr(rest);
    }
    return ev.setValues(saved.items);
}

fn multipleValueBind(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const vars = heap.car(args);
    const after_vars = heap.cdr(args);
    if (!after_vars.isCons()) return Error.BadArgList;
    const values_form = heap.car(after_vars);
    const body = heap.cdr(after_vars);

    _ = try ev.eval(values_form);
    var produced: std.ArrayList(Value) = .empty;
    defer produced.deinit(ev.allocator);
    try produced.appendSlice(ev.allocator, ev.values.items);

    _ = try ev.env.pushValueFrame();
    defer ev.env.popValueFrame();

    var i: usize = 0;
    var rest = vars;
    while (!rest.equalsRaw(value.NIL)) : (i += 1) {
        if (!rest.isCons()) return Error.BadArgList;
        const var_sym = heap.car(rest);
        if (!var_sym.isSymbol()) return Error.TypeError;
        const v = if (i < produced.items.len) produced.items[i] else value.NIL;
        try ev.env.top_value.?.bind(ev.allocator, var_sym, v);
        rest = heap.cdr(rest);
    }
    return prognBody(ev, body);
}

fn andForm(ev: *Evaluator, args: Value) Error!Value {
    if (args.equalsRaw(value.NIL)) return ev.set1(value.T);
    var rest = args;
    while (true) {
        if (!rest.isCons()) return Error.BadArgList;
        const this = heap.car(rest);
        const next = heap.cdr(rest);
        const result = try ev.eval(this);
        if (next.equalsRaw(value.NIL)) return result;
        if (result.equalsRaw(value.NIL)) return ev.set1(value.NIL);
        rest = next;
    }
}

fn orForm(ev: *Evaluator, args: Value) Error!Value {
    var rest = args;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        const this = heap.car(rest);
        const next = heap.cdr(rest);
        const result = try ev.eval(this);
        if (!result.equalsRaw(value.NIL)) return result;
        if (next.equalsRaw(value.NIL)) return result;
        rest = next;
    }
    return ev.set1(value.NIL);
}

fn whenForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const test_val = try ev.eval(heap.car(args));
    if (test_val.equalsRaw(value.NIL)) return ev.set1(value.NIL);
    return prognBody(ev, heap.cdr(args));
}

fn unlessForm(ev: *Evaluator, args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    const test_val = try ev.eval(heap.car(args));
    if (!test_val.equalsRaw(value.NIL)) return ev.set1(value.NIL);
    return prognBody(ev, heap.cdr(args));
}

fn condForm(ev: *Evaluator, args: Value) Error!Value {
    var rest = args;
    while (!rest.equalsRaw(value.NIL)) {
        if (!rest.isCons()) return Error.BadArgList;
        const clause = heap.car(rest);
        if (!clause.isCons()) return Error.TypeError;
        const test_val = try ev.eval(heap.car(clause));
        if (!test_val.equalsRaw(value.NIL)) {
            const forms = heap.cdr(clause);
            if (forms.equalsRaw(value.NIL)) return ev.set1(test_val);
            return prognBody(ev, forms);
        }
        rest = heap.cdr(rest);
    }
    return ev.set1(value.NIL);
}

fn expectOneArg(args: Value) Error!Value {
    if (!args.isCons()) return Error.BadArgList;
    if (!heap.cdr(args).equalsRaw(value.NIL)) return Error.BadArgList;
    return heap.car(args);
}
