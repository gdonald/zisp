//! The closure calls in progress, as the debugger reads them. Frame 0 is
//! the innermost call.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const function = @import("../eval/function.zig");
const eval_mod = @import("../eval/eval.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const CallFrame = eval_mod.CallFrame;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerFrames(ev: *Evaluator) !void {
    _ = try ev.defineNative("%FRAME-COUNT", &frameCountFn);
    _ = try ev.defineNative("%FRAME-FUNCTION-NAME", &frameFunctionNameFn);
    _ = try ev.defineNative("%FRAME-ARGUMENTS", &frameArgumentsFn);
    _ = try ev.defineNative("%FRAME-FORM", &frameFormFn);
    _ = try ev.defineNative("%FRAME-POSITION", &framePositionFn);
    function.asFunction(try ev.defineNative("%FRAME-EVAL", &frameEvalFn)).preserves_values = true;
    _ = try ev.defineNative("%KEEP-CALLER-FRAME", &keepCallerFrameFn);
    _ = try ev.defineNative("%DEFINE-SYMBOL-MACRO", &defineSymbolMacroFn);
}

/// `(%define-symbol-macro name expansion)`: make `name` stand for
/// `expansion` wherever no binding of it is in scope.
fn defineSymbolMacroFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const name = args[0];
    if (!name.isSymbol()) return ev.typeMismatch(name, "SYMBOL");
    const sym = symbol_mod.symbol(name);
    if (sym.special or sym.constant) return Error.ProgramError;
    const marker = try ev.heap.allocStructure(try ev.interner.intern(Evaluator.SYMBOL_MACRO_NAME), &.{args[1]});
    sym.value_cell = marker;
    return name;
}

/// `(%keep-caller-frame function)`: calls to `function` keep the frame
/// that made them, even from tail position.
fn keepCallerFrameFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    if (!function.isFunction(args[0])) return Error.TypeError;
    function.asFunction(args[0]).keeps_caller = true;
    return args[0];
}

/// The frame `index` names, counting outward from the innermost call.
fn frameAt(ev: *Evaluator, index: Value) Error!CallFrame {
    if (!index.isFixnum() or index.toFixnum() < 0) return Error.TypeError;
    const from_innermost: usize = @intCast(index.toFixnum());
    const count = ev.call_frames.items.len;
    if (from_innermost >= count) return Error.TypeError;
    return ev.call_frames.items[count - 1 - from_innermost];
}

fn frameCountFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 0) return Error.WrongArgCount;
    return Value.fromFixnum(@intCast(ev.call_frames.items.len));
}

/// The name the frame's function was defined under, as a string, or nil
/// for an anonymous function.
fn frameFunctionNameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const frame = try frameAt(ev, args[0]);
    const name = function.asFunction(frame.function).name orelse return value.NIL;
    return ev.heap.allocString(name);
}

fn frameArgumentsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const frame = try frameAt(ev, args[0]);
    return ev.heap.list(frame.args);
}

/// The form that made the call, or nil where a native made it.
fn frameFormFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const frame = try frameAt(ev, args[0]);
    return if (frame.form.isCons()) frame.form else value.NIL;
}

/// Where the person wrote the call the frame is for, as `(file line
/// column)`, or nil where no position was recorded. A call a macro built
/// is placed where the macro's own call was written.
fn framePositionFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const frame = try frameAt(ev, args[0]);
    const table = ev.positions orelse return value.NIL;
    const pos = table.userPosition(frame.form) orelse return value.NIL;
    var held = ev.heap.protect();
    defer held.close();
    try held.push(try ev.heap.allocString(pos.file));
    try held.push(Value.fromFixnum(pos.line));
    try held.push(Value.fromFixnum(pos.column));
    return ev.heap.list(held.items());
}

/// `(%frame-eval index form)` evaluates `form` in the lexical environment
/// the frame's call was made in.
fn frameEvalFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const frame = try frameAt(ev, args[0]);
    const mark = try ev.env.saveChains();
    defer ev.env.restoreChains(mark);
    ev.env.top_value = ev.env.saved_chains.items[frame.chain_mark];
    ev.env.top_function = ev.env.saved_chains.items[frame.chain_mark + 1];
    return ev.eval(args[1]);
}
