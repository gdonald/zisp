//! The natives `compile` is built on.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const function = @import("../eval/function.zig");
const eval_mod = @import("../eval/eval.zig");
const compiler = @import("../compiler/compiler.zig");
const special_forms = @import("../eval/special_forms.zig");
const bytecode = compiler.bytecode;
const Op = bytecode.Op;

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerCompiler(ev: *Evaluator) !void {
    _ = try ev.defineNative("%COMPILE-LAMBDA", &compileLambdaFn);
    _ = try ev.defineNative("%COMPILE-FUNCTION", &compileFunctionFn);
    _ = try ev.defineNative("COMPILED-FUNCTION-P", &compiledFunctionPFn);
    _ = try ev.defineNative("%PROCLAIM", &proclaimFn);
    _ = try ev.defineNative("%PUT-INLINE-EXPANSION", &putInlineExpansionFn);
    function.asFunction(try ev.defineNative("%MACROEXPAND-1", &macroexpand1Fn)).preserves_values = true;
    function.asFunction(try ev.defineNative("%MACROEXPAND", &macroexpandFn)).preserves_values = true;
    _ = try ev.defineNative("%DISASSEMBLY", &disassemblyFn);
    _ = try ev.defineNative("%FUNCTION-CONSTANTS", &functionConstantsFn);
    _ = try ev.defineNative("%CALL-CACHE-COUNTERS", &callCacheCountersFn);
    _ = try ev.defineNative("%RESET-CALL-CACHE-COUNTERS", &resetCallCacheCountersFn);
    _ = try ev.defineNative("%CALL-SITE-COUNTERS", &callSiteCountersFn);

    _ = try ev.interner.internExtension("FASL-VERSION-ERROR");
    _ = try ev.interner.internExtension("*TCO-FRAME-COUNTER*");
    // Set to write fasls big-endian, which is what tests the loader's
    // byte swapping.
    const big = try ev.interner.intern("*%FASL-BIG-ENDIAN*");
    symbol_mod.symbol(big).special = true;
    if (symbol_mod.symbol(big).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) symbol_mod.symbol(big).value_cell = value.NIL;
    const mode = try ev.interner.internExtension("*EVALUATOR-MODE*");
    symbol_mod.symbol(mode).special = true;
    if (symbol_mod.symbol(mode).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) {
        symbol_mod.symbol(mode).value_cell = try ev.interner.internKeyword("INTERPRET");
    }
}

/// The name a compiled function is given, from what it was compiled as.
fn nameOf(ev: *Evaluator, given: Value) Error!?[]const u8 {
    if (given.equalsRaw(value.NIL)) return null;
    return symbol_mod.symbol(try ev.functionNameSymbol(given)).name;
}

/// `(%compile-lambda lambda-expression &optional name)`.
fn compileLambdaFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const form = args[0];
    if (!form.isCons() or !heap.car(form).equalsRaw(try ev.interner.intern("LAMBDA"))) {
        return ev.typeMismatch(form, "CONS");
    }
    const rest = heap.cdr(form);
    if (!rest.isCons()) return Error.BadArgList;
    const name = if (args.len == 2) try nameOf(ev, args[1]) else null;
    return compiler.compileLambda(ev, name, heap.car(rest), heap.cdr(rest));
}

/// `(%compile-function function &optional name)`: a compiled function
/// for an interpreted one made in the null lexical environment, and
/// any other function as it is.
fn compileFunctionFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 1 or args.len > 2) return Error.WrongArgCount;
    const fn_v = args[0];
    if (!function.isFunction(fn_v)) return ev.typeMismatch(fn_v, "FUNCTION");
    const f = function.asFunction(fn_v);
    if (f.kind != .closure) return fn_v;
    const closure = f.payload.closure;
    if (closure.is_macro or closure.captured_env != null or closure.captured_fenv != null) return fn_v;
    const name = if (args.len == 2) try nameOf(ev, args[1]) else f.name;
    return compiler.compileLambda(ev, name, closure.params, closure.body);
}

fn macroexpand1Fn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const previous = try ev.enterEnvironment(args[1]);
    defer ev.leaveEnvironment(previous);
    if (try ev.macroexpand1(args[0])) |expansion| return ev.setValues(&.{ expansion, value.T });
    return ev.setValues(&.{ args[0], value.NIL });
}

fn macroexpandFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    const previous = try ev.enterEnvironment(args[1]);
    defer ev.leaveEnvironment(previous);
    var held = ev.heap.protect();
    defer held.close();
    try held.push(args[0]);
    var expanded = false;
    while (try ev.macroexpand1(held.items()[0])) |expansion| {
        held.items()[0] = expansion;
        expanded = true;
    }
    return ev.setValues(&.{ held.items()[0], if (expanded) value.T else value.NIL });
}

fn compiledCode(ev: *Evaluator, fn_v: Value) Error!*const bytecode.Code {
    if (!function.isCompiled(fn_v)) return ev.typeMismatch(fn_v, "COMPILED-FUNCTION");
    return function.asFunction(fn_v).payload.compiled.code;
}

/// `(%function-constants function)`: the constant pool of a compiled
/// function, as a list.
fn functionConstantsFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const code = try compiledCode(ev, args[0]);
    return ev.heap.list(code.constants);
}

/// What one operand of an instruction is, for the comment beside it.
const Operand = enum { plain, constant, slot, target, closed };

fn operandKinds(op: Op) []const Operand {
    return switch (op) {
        .load_const, .load_global, .store_global, .bind_special, .load_function, .store_function, .interpret, .check_type => &.{.constant},
        .load_local, .store_local, .make_cell, .load_cell, .store_cell, .save_dynamic, .restore_dynamic, .save_state, .mv_spread, .rest_arg, .pop_list, .check_end => &.{.slot},
        .load_closed, .load_closed_cell, .store_closed_cell => &.{.closed},
        .jump, .jump_if_nil, .jump_if_true => &.{.target},
        .proclaim => &.{ .constant, .plain },
        .jump_if_bound => &.{ .constant, .target },
        .make_closure => &.{ .constant, .plain },
        .call_global => &.{ .constant, .plain, .plain },
        .enter_block => &.{ .slot, .target, .plain },
        .enter_tagbody => &.{ .slot, .plain, .plain },
        .enter_catch, .enter_cleanup => &.{ .target, .plain },
        .enter_errors => &.{ .target, .plain, .plain },
        .unwind => &.{ .plain, .plain },
        .optional_arg => &.{ .plain, .target },
        .check_keys => &.{ .constant, .plain },
        .key_arg => &.{ .constant, .slot, .target },
        .jump_if_atom => &.{ .slot, .target },
        .list_key => &.{ .constant, .slot, .slot, .target },
        .check_list_keys => &.{ .constant, .slot, .plain },
        .call => &.{ .plain, .plain },
        .load_fixnum, .drop, .slide, .unbind, .values, .mv_push, .go, .apply, .call_counted => &.{.plain},
        else => &.{},
    };
}

fn slotName(code: *const bytecode.Code, slot: u32) ?[]const u8 {
    if (slot >= code.slot_names.len) return null;
    const name = code.slot_names[slot];
    if (name.raw == 0) return null;
    return symbol_mod.symbol(name).name;
}

/// `(%disassembly function)`: the listing of a compiled function's
/// instructions, as a string. Its constants are listed by the Lisp side,
/// which prints them as the printer variables say.
fn disassemblyFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const code = try compiledCode(ev, args[0]);
    var out: std.Io.Writer.Allocating = .init(ev.allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("Disassembly of {s}\n", .{code.name orelse "an anonymous function"});
    try w.print("{d} required, {d} optional{s}, {d} locals\n", .{
        code.required,
        code.optional,
        if (code.takes_extra) ", more accepted" else "",
        code.locals,
    });
    if (code.source_file) |file| {
        const base = if (std.mem.lastIndexOfScalar(u8, file, '/')) |i| file[i + 1 ..] else file;
        try w.print("Source: {s}\n", .{base});
    }
    var pc: usize = 0;
    while (pc < code.words.len) {
        const word = code.words[pc];
        const op = bytecode.opOf(word);
        const kinds = operandKinds(op);
        var operands: [4]u32 = undefined;
        operands[0] = bytecode.operandOf(word);
        const extra = op.extraWords();
        for (0..extra) |i| operands[i + 1] = code.words[pc + 1 + i];
        try w.print("{d:>5}  ", .{pc});
        try bytecode.writeOpName(w, op);
        for (kinds, 0..) |_, i| {
            const n = operands[i];
            const call_operand = switch (op) {
                .call, .apply, .call_counted => i == 0,
                .call_global => i == 1,
                else => false,
            };
            if (call_operand) {
                const mode: []const u8 = switch (bytecode.callMode(n)) {
                    .single => "single",
                    .multiple => "multiple",
                    .tail => "tail",
                };
                try w.print(" {d} {s}", .{ bytecode.callArgc(n), mode });
            } else if (op == .load_fixnum) {
                try w.print(" {d}", .{bytecode.fixnumFromOperand(n)});
            } else {
                try w.print(" {d}", .{n});
            }
        }
        var noted = false;
        for (kinds, 0..) |kind, i| {
            const n = operands[i];
            const note: ?[]const u8 = switch (kind) {
                .slot => slotName(code, n),
                else => null,
            };
            if (kind == .constant) {
                try w.print("{s}constant {d}", .{ if (noted) ", " else "  ; ", n });
                noted = true;
            } else if (note) |text| {
                try w.print("{s}{s}", .{ if (noted) ", " else "  ; ", text });
                noted = true;
            }
        }
        for (code.positions) |pos| {
            if (pos.pc != pc) continue;
            try w.print("{s}line {d}", .{ if (noted) ", " else "  ; ", pos.line });
        }
        try w.writeByte('\n');
        pc += 1 + extra;
    }
    return ev.heap.allocString(out.written());
}

/// `(%call-cache-counters)`: how the call sites' caches have fared, as a
/// property list.
fn callCacheCountersFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 0) return Error.WrongArgCount;
    return countersList(ev, (try ev.machine()).counters, null);
}

/// `(%call-site-counters function)`: one property list for each call
/// site in a compiled function, in the order the sites come in its code,
/// with the state its cache is in.
fn callSiteCountersFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const code = try compiledCode(ev, args[0]);
    var held = ev.heap.protect();
    defer held.close();
    for (code.caches) |*cache| {
        const state: bytecode.CacheState = if (cache.epoch == function.call_cache_epoch) cache.state else .empty;
        try held.push(try countersList(ev, cache.counters, state));
    }
    return ev.heap.list(held.items());
}

fn countersList(ev: *Evaluator, counters: bytecode.CacheCounters, state: ?bytecode.CacheState) Error!Value {
    var held = ev.heap.protect();
    defer held.close();
    if (state) |s| {
        try held.push(try ev.interner.internKeyword("STATE"));
        try held.push(try ev.interner.internKeyword(switch (s) {
            .empty => "EMPTY",
            .monomorphic => "MONOMORPHIC",
            .polymorphic => "POLYMORPHIC",
            .megamorphic => "MEGAMORPHIC",
        }));
    }
    inline for (@typeInfo(@TypeOf(counters)).@"struct".field_names) |name| {
        var upper: [name.len]u8 = undefined;
        for (name, 0..) |c, i| upper[i] = if (c == '_') '-' else std.ascii.toUpper(c);
        try held.push(try ev.interner.internKeyword(&upper));
        try held.push(Value.fromFixnum(@intCast(@field(counters, name))));
    }
    return ev.heap.list(held.items());
}

fn resetCallCacheCountersFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 0) return Error.WrongArgCount;
    (try ev.machine()).counters = .{};
    return value.NIL;
}

fn compiledFunctionPFn(p: *anyopaque, args: []const Value) Error!Value {
    _ = p;
    if (args.len != 1) return Error.WrongArgCount;
    return if (function.isCompiledFunction(args[0])) value.T else value.NIL;
}

fn proclaimFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    try special_forms.proclaim(ev, args[0]);
    return value.NIL;
}

/// `(%put-inline-expansion name expansion)`: what calls to the function
/// `name` are expanded into where it is declared inline.
fn putInlineExpansionFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 2) return Error.WrongArgCount;
    if (!args[0].isSymbol()) return ev.typeMismatch(args[0], "SYMBOL");
    try symbol_mod.plistPut(ev.heap, args[0], try ev.interner.intern("%INLINE-EXPANSION"), args[1]);
    return args[1];
}
