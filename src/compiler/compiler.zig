//! Compiling a lambda expression to a function the VM runs.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const convert = @import("convert.zig");
const emit = @import("emit.zig");

pub const bytecode = @import("bytecode.zig");
pub const vm = @import("vm.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;

/// A compiled function for `(lambda params . body)`, given as its params
/// and body, in the null lexical environment.
pub fn compileLambda(ev: *Evaluator, name: ?[]const u8, params: Value, body: Value) Error!Value {
    var arena = std.heap.ArenaAllocator.init(ev.allocator);
    defer arena.deinit();
    const pins = ev.pinMark();
    defer ev.unpinTo(pins);
    try ev.pin(params);
    try ev.pin(body);

    ev.eval_depth += 1;
    defer ev.eval_depth -= 1;
    const chains = try ev.env.saveChains();
    defer ev.env.restoreChains(chains);
    ev.env.top_value = null;
    ev.env.top_function = null;

    var converter = try convert.Converter.init(ev, arena.allocator());
    const l = try converter.convertLambda(null, name, params, body, null);
    const code = try emit.compileFunction(ev, arena.allocator(), l);
    return function.allocCompiled(ev.heap, code, &.{});
}

/// Evaluate `form` by compiling it as the body of a function of no
/// arguments and calling that. A top-level `progn` is taken a form at a
/// time, so a macro one of its forms defines is there for the next.
pub fn evalCompiled(ev: *Evaluator, form: Value) Error!Value {
    if (!form.isCons()) return ev.eval(form);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(form);
    if (heap.car(form).equalsRaw(try ev.interner.intern("PROGN"))) {
        var rest = heap.cdr(form);
        if (rest.equalsRaw(value.NIL)) return ev.set1(value.NIL);
        var result = value.NIL;
        while (rest.isCons()) : (rest = heap.cdr(rest)) result = try ev.evalTopLevel(heap.car(rest));
        return result;
    }
    try held.push(try ev.heap.list(held.items()[0..1]));
    const compiled = try compileLambda(ev, null, value.NIL, held.items()[1]);
    try held.push(compiled);
    return ev.callFunction(compiled, &.{});
}
