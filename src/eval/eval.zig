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

    fn applyClosure(self: *Evaluator, c: *const function.Closure, args: []const Value) Error!Value {
        const prev_chain = self.env.setValueChain(c.captured_env);
        defer _ = self.env.setValueChain(prev_chain);

        const prev_fchain = self.env.setFunctionChain(c.captured_fenv);
        defer _ = self.env.setFunctionChain(prev_fchain);

        const frame = try self.env.pushValueFrame();
        defer self.env.popValueFrame();

        try lambda_list.bindInto(self, c.params, args, frame);

        // An empty body yields a single NIL; otherwise the last form's
        // value list (set by its eval) propagates out unchanged.
        if (!c.body.isCons()) return self.set1(value.NIL);
        var result = value.NIL;
        var body = c.body;
        while (!body.equalsRaw(value.NIL)) {
            if (!body.isCons()) return Error.BadArgList;
            result = try self.eval(heap_mod.car(body));
            body = heap_mod.cdr(body);
        }
        return result;
    }

    pub fn fromOpaque(p: *anyopaque) *Evaluator {
        return @ptrCast(@alignCast(p));
    }
};
