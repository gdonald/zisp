const std = @import("std");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const env_mod = @import("env.zig");
const function = @import("function.zig");
const lambda_list = @import("lambda_list.zig");

const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = symbol_mod.Interner;

pub const Env = env_mod.Env;
pub const HeapFunction = function.HeapFunction;
pub const isFunction = function.isFunction;
pub const asFunction = function.asFunction;

pub const Error = function.NativeError;

pub const NativeFn = function.NativeFn;
pub const SpecialFormFn = *const fn (ev: *Evaluator, args: Value) Error!Value;
pub const MacroExpander = *const fn (ev: *Evaluator, form: Value) Error!?Value;

fn defaultMacroExpander(ev: *Evaluator, form: Value) Error!?Value {
    _ = ev;
    _ = form;
    return null;
}

const BlockEntry = struct { name: Value, id: u64 };
const TagbodyEntry = struct { body: Value, id: u64 };
const CatchEntry = struct { tag: Value, id: u64 };
pub const GoTarget = struct { id: u64, pos: Value };

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,
    env: Env,
    special_forms: std.AutoHashMapUnmanaged(u64, SpecialFormFn) = .{},
    macro_expander: MacroExpander = defaultMacroExpander,
    // Tail-position dispatch through these control forms reuses the caller's
    // frame instead of growing the native stack. Populated by registerStandard.
    sym_if: Value = undefined,
    sym_progn: Value = undefined,
    block_stack: std.ArrayList(BlockEntry) = .empty,
    block_counter: u64 = 0,
    return_id: u64 = 0,
    tagbody_stack: std.ArrayList(TagbodyEntry) = .empty,
    tagbody_counter: u64 = 0,
    go_id: u64 = 0,
    go_target: Value = undefined,
    catch_stack: std.ArrayList(CatchEntry) = .empty,
    catch_counter: u64 = 0,
    throw_id: u64 = 0,
    // Complete multiple-value list of the most recently evaluated form.
    // After any normal `eval` return, `values.items[0]` (or NIL when empty)
    // equals the returned primary value.
    values: std.ArrayList(Value) = .empty,
    // Value list carried by an in-flight return-from / throw, read by the
    // catching block / catch frame.
    transfer_values: std.ArrayList(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator, heap_ref: *Heap, interner: *Interner) Evaluator {
        return .{
            .allocator = allocator,
            .heap = heap_ref,
            .interner = interner,
            .env = Env.init(allocator),
            .go_target = value.NIL,
            .sym_if = value.NIL,
            .sym_progn = value.NIL,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.env.deinit();
        self.special_forms.deinit(self.allocator);
        self.block_stack.deinit(self.allocator);
        self.tagbody_stack.deinit(self.allocator);
        self.catch_stack.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.transfer_values.deinit(self.allocator);
    }

    /// Record `v` as the sole value of the current form and return it.
    pub fn set1(self: *Evaluator, v: Value) Error!Value {
        self.values.clearRetainingCapacity();
        try self.values.append(self.allocator, v);
        return v;
    }

    /// Record `vals` as the complete value list of the current form and
    /// return the primary value (NIL when there are zero values).
    pub fn setValues(self: *Evaluator, vals: []const Value) Error!Value {
        self.values.clearRetainingCapacity();
        try self.values.appendSlice(self.allocator, vals);
        return if (vals.len == 0) value.NIL else vals[0];
    }

    /// Copy the current value list into the transfer channel so a catching
    /// frame can recover it after an in-flight return-from / throw.
    pub fn stashTransferValues(self: *Evaluator) Error!void {
        self.transfer_values.clearRetainingCapacity();
        try self.transfer_values.appendSlice(self.allocator, self.values.items);
    }

    /// Restore the current value list from the transfer channel.
    pub fn unstashTransferValues(self: *Evaluator) Error!Value {
        return self.setValues(self.transfer_values.items);
    }

    pub const TransferState = struct {
        return_id: u64,
        go_id: u64,
        go_target: Value,
        throw_id: u64,
    };

    pub fn saveTransferState(self: *const Evaluator) TransferState {
        return .{
            .return_id = self.return_id,
            .go_id = self.go_id,
            .go_target = self.go_target,
            .throw_id = self.throw_id,
        };
    }

    pub fn restoreTransferState(self: *Evaluator, s: TransferState) void {
        self.return_id = s.return_id;
        self.go_id = s.go_id;
        self.go_target = s.go_target;
        self.throw_id = s.throw_id;
    }

    pub fn pushCatch(self: *Evaluator, tag: Value) Error!u64 {
        self.catch_counter += 1;
        const id = self.catch_counter;
        try self.catch_stack.append(self.allocator, .{ .tag = tag, .id = id });
        return id;
    }

    pub fn popCatch(self: *Evaluator) void {
        _ = self.catch_stack.pop();
    }

    pub fn findCatch(self: *const Evaluator, tag: Value) ?u64 {
        var i = self.catch_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.catch_stack.items[i].tag.equalsRaw(tag)) {
                return self.catch_stack.items[i].id;
            }
        }
        return null;
    }

    pub fn pushTagbody(self: *Evaluator, body: Value) Error!u64 {
        self.tagbody_counter += 1;
        const id = self.tagbody_counter;
        try self.tagbody_stack.append(self.allocator, .{ .body = body, .id = id });
        return id;
    }

    pub fn popTagbody(self: *Evaluator) void {
        _ = self.tagbody_stack.pop();
    }

    pub fn findTagbody(self: *const Evaluator, tag: Value) ?GoTarget {
        var i = self.tagbody_stack.items.len;
        while (i > 0) {
            i -= 1;
            var cur = self.tagbody_stack.items[i].body;
            while (cur.isCons()) {
                const elem = heap_mod.car(cur);
                if (!elem.isCons() and elem.equalsRaw(tag)) {
                    return .{ .id = self.tagbody_stack.items[i].id, .pos = heap_mod.cdr(cur) };
                }
                cur = heap_mod.cdr(cur);
            }
        }
        return null;
    }

    pub fn pushBlock(self: *Evaluator, name: Value) Error!u64 {
        self.block_counter += 1;
        const id = self.block_counter;
        try self.block_stack.append(self.allocator, .{ .name = name, .id = id });
        return id;
    }

    pub fn popBlock(self: *Evaluator) void {
        _ = self.block_stack.pop();
    }

    pub fn findBlock(self: *const Evaluator, name: Value) ?u64 {
        var i = self.block_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.block_stack.items[i].name.equalsRaw(name)) {
                return self.block_stack.items[i].id;
            }
        }
        return null;
    }

    pub fn registerSpecialForm(self: *Evaluator, name: []const u8, handler: SpecialFormFn) !void {
        const sym = try self.interner.intern(name);
        try self.special_forms.put(self.allocator, sym.raw, handler);
    }

    pub fn lookupSpecialForm(self: *const Evaluator, sym: Value) ?SpecialFormFn {
        std.debug.assert(sym.isSymbol());
        return self.special_forms.get(sym.raw);
    }

    pub fn defineNative(self: *Evaluator, name: []const u8, native: NativeFn) !Value {
        const sym = try self.interner.intern(name);
        const fn_v = try function.allocNative(self.heap.allocator, name, native);
        symbol_mod.symbol(sym).function_cell = fn_v;
        return fn_v;
    }

    pub fn eval(self: *Evaluator, form: Value) Error!Value {
        if (form.equalsRaw(value.NIL)) return self.set1(form);
        if (form.equalsRaw(value.T)) return self.set1(form);
        switch (form.tag()) {
            .fixnum, .char, .heap, .special => return self.set1(form),
            .symbol => return self.set1(try self.evalSymbol(form)),
            .cons => return self.evalCons(form),
            ._reserved6, ._reserved7 => return Error.TypeError,
        }
    }

    fn evalSymbol(self: *Evaluator, sym: Value) Error!Value {
        const s = symbol_mod.symbol(sym);
        if (s.name.len > 0 and s.name[0] == ':') return sym;
        return self.env.lookupValue(sym) orelse Error.UnboundVariable;
    }

    fn evalCons(self: *Evaluator, form: Value) Error!Value {
        const head = heap_mod.car(form);
        const tail = heap_mod.cdr(form);

        if (head.isSymbol()) {
            if (self.lookupSpecialForm(head)) |handler| {
                return handler(self, tail);
            }
            if (try self.macro_expander(self, form)) |expanded| {
                return self.eval(expanded);
            }
            const fn_v = self.env.lookupFunction(head) orelse return Error.UnboundFunction;
            return self.applyFunction(fn_v, tail);
        }

        return Error.NotCallable;
    }

    pub fn applyFunction(self: *Evaluator, fn_v: Value, arg_forms: Value) Error!Value {
        if (!isFunction(fn_v)) return Error.NotCallable;

        var args: std.ArrayList(Value) = .empty;
        defer args.deinit(self.allocator);

        var rest = arg_forms;
        while (!rest.equalsRaw(value.NIL)) {
            if (!rest.isCons()) return Error.BadArgList;
            const arg = try self.eval(heap_mod.car(rest));
            try args.append(self.allocator, arg);
            rest = heap_mod.cdr(rest);
        }

        return self.callFunction(fn_v, args.items);
    }

    pub fn callFunction(self: *Evaluator, fn_v: Value, args: []const Value) Error!Value {
        if (!isFunction(fn_v)) return Error.NotCallable;
        const f = asFunction(fn_v);
        switch (f.kind) {
            // Natives are single-valued; multiple-value producers are special
            // forms, so collapsing the channel here is always correct.
            .native => return self.set1(try f.payload.native(@ptrCast(self), args)),
            .closure => return self.applyClosure(&f.payload.closure, args),
        }
    }

    const TailStep = union(enum) {
        value: Value,
        call: *const function.Closure,
    };

    fn applyClosure(self: *Evaluator, c0: *const function.Closure, args0: []const Value) Error!Value {
        const saved_value_chain = self.env.top_value;
        const saved_function_chain = self.env.top_function;
        defer {
            self.env.top_value = saved_value_chain;
            self.env.top_function = saved_function_chain;
        }

        // Tail jumps alternate between two buffers so the args feeding the
        // current call are never the buffer being refilled for the next one.
        var buf_a: std.ArrayList(Value) = .empty;
        var buf_b: std.ArrayList(Value) = .empty;
        defer buf_a.deinit(self.allocator);
        defer buf_b.deinit(self.allocator);

        var cur = c0;
        var cur_args: []const Value = args0;
        var use_a = true;
        var frame: ?*env_mod.Frame = null;

        while (true) {
            self.env.top_function = cur.captured_fenv;
            if (frame) |f| {
                f.reset();
                f.parent = cur.captured_env;
                self.env.top_value = f;
            } else {
                self.env.top_value = cur.captured_env;
                frame = try self.env.pushValueFrame();
            }
            try lambda_list.bindInto(self, cur.params, cur_args, frame.?);

            if (!cur.body.isCons()) return self.set1(value.NIL);

            var body = cur.body;
            while (true) {
                if (!body.isCons()) return Error.BadArgList;
                const next = heap_mod.cdr(body);
                if (next.equalsRaw(value.NIL)) break;
                if (!next.isCons()) return Error.BadArgList;
                _ = try self.eval(heap_mod.car(body));
                body = next;
            }
            const last = heap_mod.car(body);

            const out_buf = if (use_a) &buf_a else &buf_b;
            switch (try self.evalTail(last, out_buf)) {
                .value => |v| return v,
                .call => |next_c| {
                    cur = next_c;
                    cur_args = out_buf.items;
                    use_a = !use_a;
                },
            }
        }
    }

    /// Evaluate `form` in tail position. A direct call to a closure (possibly
    /// reached through `if` or `progn`) is reported as a `.call` for the
    /// trampoline to loop on; everything else evaluates here and returns a
    /// `.value`. Closure call arguments are evaluated into `out_buf`.
    fn evalTail(self: *Evaluator, form: Value, out_buf: *std.ArrayList(Value)) Error!TailStep {
        if (!form.isCons()) return .{ .value = try self.eval(form) };
        const head = heap_mod.car(form);
        if (!head.isSymbol()) return .{ .value = try self.eval(form) };
        const tail = heap_mod.cdr(form);

        if (self.lookupSpecialForm(head)) |handler| {
            if (head.equalsRaw(self.sym_if)) return self.tailIf(tail, out_buf);
            if (head.equalsRaw(self.sym_progn)) return self.tailProgn(tail, out_buf);
            return .{ .value = try handler(self, tail) };
        }

        if (try self.macro_expander(self, form)) |expanded| {
            return self.evalTail(expanded, out_buf);
        }

        const fn_v = self.env.lookupFunction(head) orelse return Error.UnboundFunction;
        if (isFunction(fn_v) and asFunction(fn_v).kind == .closure) {
            out_buf.clearRetainingCapacity();
            var rest = tail;
            while (!rest.equalsRaw(value.NIL)) {
                if (!rest.isCons()) return Error.BadArgList;
                try out_buf.append(self.allocator, try self.eval(heap_mod.car(rest)));
                rest = heap_mod.cdr(rest);
            }
            return .{ .call = &asFunction(fn_v).payload.closure };
        }

        return .{ .value = try self.applyFunction(fn_v, tail) };
    }

    fn tailIf(self: *Evaluator, args: Value, out_buf: *std.ArrayList(Value)) Error!TailStep {
        if (!args.isCons()) return Error.BadArgList;
        const test_form = heap_mod.car(args);
        const rest = heap_mod.cdr(args);
        if (!rest.isCons()) return Error.BadArgList;
        const then_form = heap_mod.car(rest);
        const after_then = heap_mod.cdr(rest);

        var else_form = value.NIL;
        var has_else = false;
        if (after_then.isCons()) {
            else_form = heap_mod.car(after_then);
            has_else = true;
            if (!heap_mod.cdr(after_then).equalsRaw(value.NIL)) return Error.BadArgList;
        } else if (!after_then.equalsRaw(value.NIL)) {
            return Error.BadArgList;
        }

        const test_val = try self.eval(test_form);
        if (!test_val.equalsRaw(value.NIL)) return self.evalTail(then_form, out_buf);
        if (has_else) return self.evalTail(else_form, out_buf);
        return .{ .value = try self.set1(value.NIL) };
    }

    fn tailProgn(self: *Evaluator, body: Value, out_buf: *std.ArrayList(Value)) Error!TailStep {
        if (!body.isCons()) {
            if (body.equalsRaw(value.NIL)) return .{ .value = try self.set1(value.NIL) };
            return Error.BadArgList;
        }
        var rest = body;
        while (true) {
            if (!rest.isCons()) return Error.BadArgList;
            const this = heap_mod.car(rest);
            const next = heap_mod.cdr(rest);
            if (next.equalsRaw(value.NIL)) return self.evalTail(this, out_buf);
            if (!next.isCons()) return Error.BadArgList;
            _ = try self.eval(this);
            rest = next;
        }
    }

    pub fn fromOpaque(p: *anyopaque) *Evaluator {
        return @ptrCast(@alignCast(p));
    }
};
