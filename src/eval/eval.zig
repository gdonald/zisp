const std = @import("std");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const env_mod = @import("env.zig");
const function = @import("function.zig");

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
    return_value: Value = undefined,
    tagbody_stack: std.ArrayList(TagbodyEntry) = .empty,
    tagbody_counter: u64 = 0,
    go_id: u64 = 0,
    go_target: Value = undefined,

    pub fn init(allocator: std.mem.Allocator, heap_ref: *Heap, interner: *Interner) Evaluator {
        return .{
            .allocator = allocator,
            .heap = heap_ref,
            .interner = interner,
            .env = Env.init(allocator),
            .return_value = value.NIL,
            .go_target = value.NIL,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.env.deinit();
        self.special_forms.deinit(self.allocator);
        self.block_stack.deinit(self.allocator);
        self.tagbody_stack.deinit(self.allocator);
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
        if (form.equalsRaw(value.NIL)) return form;
        if (form.equalsRaw(value.T)) return form;
        switch (form.tag()) {
            .fixnum, .char, .heap, .special => return form,
            .symbol => return self.evalSymbol(form),
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
            .native => return f.payload.native(@ptrCast(self), args),
            .closure => return self.applyClosure(&f.payload.closure, args),
        }
    }

    fn applyClosure(self: *Evaluator, c: *const function.Closure, args: []const Value) Error!Value {
        const param_count = try countList(c.params);
        if (param_count != args.len) return Error.WrongArgCount;

        const prev_chain = self.env.setValueChain(c.captured_env);
        defer _ = self.env.setValueChain(prev_chain);

        const prev_fchain = self.env.setFunctionChain(c.captured_fenv);
        defer _ = self.env.setFunctionChain(prev_fchain);

        const frame = try self.env.pushValueFrame();
        defer self.env.popValueFrame();

        var rest = c.params;
        var i: usize = 0;
        while (!rest.equalsRaw(value.NIL)) : (i += 1) {
            const sym = heap_mod.car(rest);
            try frame.bind(self.env.allocator, sym, args[i]);
            rest = heap_mod.cdr(rest);
        }

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

fn countList(list: Value) Error!usize {
    var n: usize = 0;
    var cur = list;
    while (!cur.equalsRaw(value.NIL)) {
        if (!cur.isCons()) return Error.BadArgList;
        n += 1;
        cur = heap_mod.cdr(cur);
    }
    return n;
}
