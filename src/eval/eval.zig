const std = @import("std");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const env_mod = @import("env.zig");
const stack_mod = @import("../runtime/stack.zig");
const collect_mod = @import("collect.zig");
const source_pos = @import("../runtime/source_pos.zig");
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
    return ev.macroexpand1(form);
}

const BlockEntry = struct { name: Value, id: u64 };
/// One saved value cell, restored when the establishing form unwinds.
const DynamicEntry = struct { sym: Value, saved: Value };
const TagbodyEntry = struct { body: Value, id: u64 };
const CatchEntry = struct { tag: Value, id: u64 };
pub const GoTarget = struct { id: u64, pos: Value };

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,
    env: Env,
    // Standard-output sink for the printing builtins (`format`, etc.) and the
    // value of `*standard-output*`. The host wires this to a real writer; it
    // stays null in unit fixtures that never print.
    out: ?*std.Io.Writer = null,
    // Warning sink. The CLI wires this to stderr; null suppresses warnings.
    warn_out: ?*std.Io.Writer = null,
    // Filesystem access for `load`. Null where no file I/O is expected.
    io: ?std.Io = null,
    // Set by `quit` / `exit`; the driver reads it to choose the process exit
    // code after the in-flight `Quit` unwinds the evaluator.
    quit_code: ?u8 = null,
    special_forms: std.AutoHashMapUnmanaged(u64, SpecialFormFn) = .{},
    macro_expander: MacroExpander = defaultMacroExpander,
    // Expansion of each macro call form, keyed by the call's cons address.
    // Re-expanding on every evaluation makes a macro inside a loop cost a
    // full interpreted run of the macro body per iteration. An entry is
    // used only while the head still names the same macro function, and the
    // whole table is dropped at each collection so no entry outlives the
    // cons it is keyed on.
    macro_cache: std.AutoHashMapUnmanaged(u64, MacroExpansion) = .{},
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
    // Source-position side-table shared with the reader. When bound,
    // macroexpansion stamps synthesized conses with the defining macro's
    // position; verbatim subforms keep theirs through structure sharing.
    positions: ?*source_pos.PositionTable = null,
    // The full form whose special-form handler is currently running.
    // `defmacro` reads it to record the definition form's position.
    // Fixnum zero until the first dispatch; never a cons before then.
    current_form: Value = .{ .raw = 0 },
    // Logical pathname hosts, mapping an upcased host name to its
    // translation list. Empty until `setf logical-pathname-translations`
    // defines one.
    logical_hosts: std.StringHashMapUnmanaged(Value) = .{},

    // Column the console sink is sitting at, so `~&` and `~T` can line
    // output up across separate `format` calls.
    output_column: usize = 0,

    // Symbol named by the most recent UnboundVariable / UnboundFunction /
    // NotCallable error, so the driver can name it in the message.
    error_symbol: Value = .{ .raw = 0 },

    // The condition an in-flight `error` is carrying. A Zig error value
    // says only what kind of failure it was, so a condition object rides
    // here from the `error` call to whatever catches it. Fixnum zero
    // when the failure came from a native rather than from Lisp.
    error_condition: Value = .{ .raw = 0 },

    // Shallow-binding stack for special variables. `let`, `let*`, and
    // lambda-list binding push the old value cell here and restore on exit,
    // so a native function reading the cell sees the innermost binding.
    dynamic_stack: std.ArrayList(DynamicEntry) = .empty,

    // Values the driver is holding across a possible collection, which
    // nothing else roots.
    pinned: std.ArrayList(Value) = .empty,
    // Collections run so far, which `room` reports.
    gc_count: u64 = 0,
    /// What the tenured space held when the last major collection
    /// finished, which is what says when the next one is due.
    live_after_major: usize = 0,
    /// How many of the collections so far walked the whole heap.
    major_count: u64 = 0,
    /// The smallest tenured space a major collection is asked to walk.
    /// Below it a program is still starting up and there is nothing to
    /// reclaim.
    major_floor: usize = 1 << 20,
    /// What to run once an object has been reclaimed. Each entry holds
    /// the object through a weak pointer, so registering one does not
    /// keep the object alive.
    finalizers: std.ArrayListUnmanaged(Finalizer) = .empty,
    /// Finalizers whose object has gone, waiting to be run. They are run
    /// by whatever was evaluating rather than by the collector, where
    /// allocating is not allowed.
    pending: std.ArrayListUnmanaged(Value) = .empty,
    /// Set while the pending queue is being run, so a collection a
    /// finalizer sets off does not start a second pass over it.
    draining: bool = false,
    // Set by `gc`, cleared by the collection it asks for.
    gc_requested: bool = false,
    // Whether the heap knows how to reach this evaluator's root scan.
    collector_installed: bool = false,
    /// How many `eval` frames are on the native stack. A collection that
    /// moves is safe only at zero: above it a Zig local holds a value the
    /// root scan can see on the Lisp stack but cannot write back into.
    /// `load` runs its own read-eval loop, so a nested one sees a depth
    /// the outer forms put there.
    eval_depth: usize = 0,

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

    /// One registration: what to run, and a weak pointer to what has to
    /// be gone before it runs.
    pub const Finalizer = struct { object: Value, action: Value };

    pub fn deinit(self: *Evaluator) void {
        self.finalizers.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.env.deinit();
        self.special_forms.deinit(self.allocator);
        self.macro_cache.deinit(self.allocator);
        self.block_stack.deinit(self.allocator);
        self.tagbody_stack.deinit(self.allocator);
        self.catch_stack.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.transfer_values.deinit(self.allocator);
        self.dynamic_stack.deinit(self.allocator);
        self.pinned.deinit(self.allocator);
        var hosts = self.logical_hosts.keyIterator();
        while (hosts.next()) |name| self.allocator.free(name.*);
        self.logical_hosts.deinit(self.allocator);
    }

    /// Hold values on the Lisp stack for as long as the caller needs
    /// them. Any Zig function that keeps a value in a local across an
    /// allocation uses this, or the value is invisible to a root scan:
    ///
    ///     var held = ev.protect();
    ///     defer held.close();
    ///     try held.push(v);
    pub fn protect(self: *Evaluator) stack_mod.Region {
        return self.heap.protect();
    }

    /// Keep `v` alive across a collection until `unpin`.
    pub fn pin(self: *Evaluator, v: Value) !void {
        try self.pinned.append(self.allocator, v);
    }

    pub fn unpin(self: *Evaluator) void {
        _ = self.pinned.pop();
    }

    /// Pins come off in groups where a caller holds several values whose
    /// lifetimes end together.
    pub fn pinMark(self: *const Evaluator) usize {
        return self.pinned.items.len;
    }

    pub fn unpinTo(self: *Evaluator, mark: usize) void {
        self.pinned.shrinkRetainingCapacity(mark);
    }

    /// Replace the most recent pin, for a value that is rebuilt in place.
    pub fn repin(self: *Evaluator, v: Value) void {
        self.pinned.items[self.pinned.items.len - 1] = v;
    }

    /// Rebind `sym`'s value cell, remembering the previous contents.
    pub fn bindSpecial(self: *Evaluator, sym: Value, val: Value) Error!void {
        const cell = &symbol_mod.symbol(sym).value_cell;
        try self.dynamic_stack.append(self.allocator, .{ .sym = sym, .saved = cell.* });
        cell.* = val;
    }

    /// Record `sym` as the subject of `err` and return the error.
    pub fn unbound(self: *Evaluator, sym: Value, err: Error) Error {
        self.error_symbol = sym;
        return err;
    }

    /// Depth of the dynamic stack, to be handed back to `unwindSpecials`.
    pub fn dynamicMark(self: *const Evaluator) usize {
        return self.dynamic_stack.items.len;
    }

    /// Restore every value cell bound since `mark`, innermost first.
    pub fn unwindSpecials(self: *Evaluator, mark: usize) void {
        while (self.dynamic_stack.items.len > mark) {
            const entry = self.dynamic_stack.pop().?;
            symbol_mod.symbol(entry.sym).value_cell = entry.saved;
        }
    }

    /// Record `v` as the sole value of the current form and return it.
    pub fn set1(self: *Evaluator, v: Value) Error!Value {
        heap_mod.checkStoredValue(v);
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

    /// Let the heap collect through this evaluator's roots, which is what
    /// the torture setting needs.
    fn installCollector(self: *Evaluator) void {
        self.collector_installed = true;
        self.heap.collector = .{ .context = @ptrCast(self), .run = &runCollection };
    }

    fn runCollection(context: *anyopaque) anyerror!void {
        try collect_mod.collect(fromOpaque(context));
    }

    /// Evaluate a form the reader built for `#.`, through an opaque context
    /// so the reader needs no evaluator type.
    pub fn readEval(context: *anyopaque, form: Value) anyerror!Value {
        return fromOpaque(context).eval(form);
    }

    pub fn eval(self: *Evaluator, form: Value) Error!Value {
        if (!self.collector_installed) self.installCollector();
        // The form is held on the Lisp stack for as long as it is being
        // evaluated. A macro expansion or a quasiquote's output is fresh
        // structure that nothing else refers to.
        var held = self.heap.protect();
        defer held.close();
        try held.push(form);
        self.eval_depth += 1;
        defer self.eval_depth -= 1;
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
        if (symbol_mod.isKeyword(sym, self.interner)) return sym;
        return self.env.lookupValue(sym) orelse self.unbound(sym, Error.UnboundVariable);
    }

    fn evalCons(self: *Evaluator, form: Value) Error!Value {
        const head = heap_mod.car(form);
        const tail = heap_mod.cdr(form);

        if (head.isSymbol()) {
            if (self.lookupSpecialForm(head)) |handler| {
                self.current_form = form;
                return handler(self, tail);
            }
            // A replaced expander sees every call form, so its own
            // decisions stand; the standard one expands only macro calls,
            // and those expansions are cached per call site.
            if (@intFromPtr(self.macro_expander) != @intFromPtr(&defaultMacroExpander)) {
                if (try self.macro_expander(self, form)) |expanded| {
                    var held = self.heap.stack.open();
                    defer held.close();
                    try held.push(expanded);
                    return self.eval(expanded);
                }
            }
            const fn_v = self.env.lookupFunction(head) orelse
                return self.unbound(head, Error.UnboundFunction);
            if (function.isMacro(fn_v)) {
                const expanded = try self.expandCached(form, fn_v);
                // The expansion is fresh structure nothing else holds.
                var held = self.heap.stack.open();
                defer held.close();
                try held.push(expanded);
                return self.eval(expanded);
            }
            return self.applyFunction(fn_v, tail);
        }

        return Error.NotCallable;
    }

    pub fn applyFunction(self: *Evaluator, fn_v: Value, arg_forms: Value) Error!Value {
        if (!isFunction(fn_v)) return Error.NotCallable;

        // The function and the arguments go on the Lisp stack, so a
        // collection during a later argument's evaluation can see them.
        var held = self.heap.stack.open();
        defer held.close();
        try held.push(fn_v);

        var args = self.heap.stack.open();
        defer args.close();
        var rest = arg_forms;
        while (!rest.equalsRaw(value.NIL)) {
            if (!rest.isCons()) return Error.BadArgList;
            try args.push(try self.eval(heap_mod.car(rest)));
            rest = heap_mod.cdr(rest);
        }

        return self.callFunction(fn_v, args.items());
    }

    /// The expansion of one macro call, tagged with the macro function it
    /// came from so a redefinition is not served from the cache.
    const MacroExpansion = struct { expander: Value, expansion: Value };

    /// Expand a macro call, reusing the previous expansion of this same call
    /// form when the head still names the same macro function.
    fn expandCached(self: *Evaluator, form: Value, expander: Value) Error!Value {
        if (self.macro_cache.get(form.raw)) |cached| {
            if (cached.expander.equalsRaw(expander)) return cached.expansion;
        }
        const expanded = (try self.macro_expander(self, form)) orelse return Error.NotCallable;
        try self.macro_cache.put(
            self.allocator,
            form.raw,
            .{ .expander = expander, .expansion = expanded },
        );
        return expanded;
    }

    /// Expand `form` once if its head names a macro. Returns null when the
    /// form is not a macro call. Expansion goes through `*macroexpand-hook*`
    /// when one is set (the `funcall` designator short-circuits to a direct
    /// call, matching its default value).
    pub fn macroexpand1(self: *Evaluator, form: Value) Error!?Value {
        if (!form.isCons()) return null;
        const head = heap_mod.car(form);
        if (!head.isSymbol()) return null;
        if (self.lookupSpecialForm(head) != null) return null;
        const expander = self.env.lookupFunction(head) orelse return null;
        if (!function.isMacro(expander)) return null;

        const hook_sym = try self.interner.intern("*MACROEXPAND-HOOK*");
        const funcall_sym = try self.interner.intern("FUNCALL");
        const hook = self.env.lookupValue(hook_sym) orelse funcall_sym;
        if (hook.equalsRaw(funcall_sym) or hook.equalsRaw(value.NIL)) {
            const expansion = try self.callFunction(expander, &.{ form, value.NIL });
            try self.stampMacroExpansion(expander, expansion);
            return expansion;
        }
        const hook_fn = if (isFunction(hook))
            hook
        else if (hook.isSymbol())
            self.env.lookupFunction(hook) orelse return Error.UnboundFunction
        else
            return Error.TypeError;
        const expansion = try self.callFunction(hook_fn, &.{ expander, form, value.NIL });
        try self.stampMacroExpansion(expander, expansion);
        return expansion;
    }

    /// Give every expansion cons that lacks a source position the defining
    /// macro's position. Conses passed through verbatim from the call form
    /// already have entries and keep them.
    fn stampMacroExpansion(self: *Evaluator, expander: Value, expansion: Value) Error!void {
        const table = self.positions orelse return;
        const def_pos = asFunction(expander).payload.closure.def_pos orelse return;
        try stampExpansion(table, expansion, def_pos);
    }

    fn stampExpansion(
        table: *source_pos.PositionTable,
        v: Value,
        pos: source_pos.SourcePosition,
    ) std.mem.Allocator.Error!void {
        if (!v.isCons()) return;
        if (table.lookup(v) != null) return;
        try table.record(v, pos);
        try stampExpansion(table, heap_mod.car(v), pos);
        try stampExpansion(table, heap_mod.cdr(v), pos);
    }

    pub fn callFunction(self: *Evaluator, fn_v: Value, args: []const Value) Error!Value {
        if (!isFunction(fn_v)) return Error.NotCallable;
        const f = asFunction(fn_v);
        switch (f.kind) {
            // Natives are single-valued unless flagged; multiple-value
            // producers are special forms or pass-through natives.
            .native => {
                const result = try f.payload.native(@ptrCast(self), args);
                if (f.preserves_values) return result;
                return self.set1(result);
            },
            .closure => return self.applyClosure(&f.payload.closure, args),
        }
    }

    const TailStep = union(enum) {
        value: Value,
        call: *const function.Closure,
    };

    fn applyClosure(self: *Evaluator, c0: *const function.Closure, args0: []const Value) Error!Value {
        const chain_mark = try self.env.saveChains();
        defer self.env.restoreChains(chain_mark);

        // A tail jump refills one region on the Lisp stack. The args
        // feeding the current call are already bound into its frame by
        // the time the region is refilled for the next one.
        var out_region = self.heap.stack.open();
        defer out_region.close();

        const call_mark = self.dynamicMark();
        defer self.unwindSpecials(call_mark);

        var cur = c0;
        var cur_args: []const Value = args0;
        var frame: ?*env_mod.Frame = null;

        while (true) {
            self.env.top_function = cur.captured_fenv;
            if (if (frame) |f| !f.captured else false) {
                // A tail jump leaves the previous iteration's dynamic
                // bindings behind before rebinding into the reused frame.
                const f = frame.?;
                self.unwindSpecials(call_mark);
                f.reset();
                f.parent = cur.captured_env;
                self.env.top_value = f;
            } else if (frame != null) {
                // The frame in hand outlives this call, so the next one
                // gets a fresh frame rather than clearing what a closure
                // still reads.
                self.unwindSpecials(call_mark);
                self.env.top_value = cur.captured_env;
                frame = try self.env.pushValueFrame();
            } else {
                self.env.top_value = cur.captured_env;
                frame = try self.env.pushValueFrame();
            }
            const frame_mark = self.dynamicMark();
            if (cur.is_macro) {
                // Macro-function protocol: (form env). The lambda list
                // destructures the form's cdr; &whole sees the whole form
                // and &environment binds env.
                if (cur_args.len != 2) return Error.WrongArgCount;
                try lambda_list.bindMacro(self, cur.params, cur_args[0], cur_args[1], frame.?);
            } else {
                try lambda_list.bindInto(self, cur.params, cur_args, frame.?);
            }

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

            // A frame that established dynamic bindings must outlive the
            // call in its tail position, so that call is not a tail call.
            if (self.dynamicMark() > frame_mark) return self.eval(last);

            switch (try self.evalTail(last, &out_region)) {
                .value => |v| return v,
                .call => |next_c| {
                    cur = next_c;
                    cur_args = out_region.items();
                },
            }
        }
    }

    /// Evaluate `form` in tail position. A direct call to a closure (possibly
    /// reached through `if` or `progn`) is reported as a `.call` for the
    /// trampoline to loop on; everything else evaluates here and returns a
    /// `.value`. Closure call arguments are evaluated into `out_buf`.
    fn evalTail(self: *Evaluator, form: Value, out_buf: *stack_mod.Region) Error!TailStep {
        if (!form.isCons()) return .{ .value = try self.eval(form) };
        const head = heap_mod.car(form);
        if (!head.isSymbol()) return .{ .value = try self.eval(form) };
        const tail = heap_mod.cdr(form);

        if (self.lookupSpecialForm(head)) |handler| {
            if (head.equalsRaw(self.sym_if)) return self.tailIf(tail, out_buf);
            if (head.equalsRaw(self.sym_progn)) return self.tailProgn(tail, out_buf);
            self.current_form = form;
            return .{ .value = try handler(self, tail) };
        }

        if (try self.macro_expander(self, form)) |expanded| {
            var held = self.heap.stack.open();
            defer held.close();
            try held.push(expanded);
            return self.evalTail(expanded, out_buf);
        }

        const fn_v = self.env.lookupFunction(head) orelse
            return self.unbound(head, Error.UnboundFunction);
        if (isFunction(fn_v) and asFunction(fn_v).kind == .closure) {
            out_buf.clear();
            var rest = tail;
            while (!rest.equalsRaw(value.NIL)) {
                if (!rest.isCons()) return Error.BadArgList;
                try out_buf.push(try self.eval(heap_mod.car(rest)));
                rest = heap_mod.cdr(rest);
            }
            return .{ .call = &asFunction(fn_v).payload.closure };
        }

        return .{ .value = try self.applyFunction(fn_v, tail) };
    }

    fn tailIf(self: *Evaluator, args: Value, out_buf: *stack_mod.Region) Error!TailStep {
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

    fn tailProgn(self: *Evaluator, body: Value, out_buf: *stack_mod.Region) Error!TailStep {
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

    /// The handle a native receives, so one native can call another.
    pub fn asOpaque(self: *Evaluator) *anyopaque {
        return @ptrCast(self);
    }
};
