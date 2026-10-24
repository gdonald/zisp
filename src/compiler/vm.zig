//! The stack machine compiled functions run on.
//!
//! One operand stack holds every compiled call in progress: a frame's
//! arguments, then its other locals, then the values it is working on.
//! A call from one compiled function to another pushes a frame here
//! rather than recursing on the host stack. A call out to a native or an
//! interpreted function goes through the evaluator, and a compiled
//! function it calls back starts a nested run on the same stack, above
//! what the outer run holds.
//!
//! A run counts as an evaluation in progress, so no collection moves an
//! object while one is going: the values here are marked where they
//! stand.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const bytecode = @import("bytecode.zig");

const build_options = @import("build_options");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;
const Op = bytecode.Op;
const Code = bytecode.Code;

const DispatchKind = enum { loop, threaded, tail };

const dispatch_kind: DispatchKind = std.meta.stringToEnum(DispatchKind, build_options.dispatch) orelse
    @compileError("-Ddispatch must be loop, threaded or tail");

/// Slots on the operand stack. Running out signals `storage-condition`.
pub const STACK_SLOTS: usize = 1 << 20;
/// Calls in progress at once. A function of no arguments uses no slots,
/// so the slots alone do not bound how deep recursion goes.
pub const MAX_FRAMES: usize = 1 << 19;
/// What is held back from both limits for the handlers that run while
/// running out is being signaled.
const RESERVE_SLOTS: usize = 1 << 14;
const RESERVE_FRAMES: usize = 1 << 12;

/// What the caller of a frame does with its result.
pub const Want = enum(u1) { single, multiple };

pub const Frame = struct {
    function: Value,
    code: *const Code,
    pc: u32,
    /// Where the arguments start. Slot i of the frame is `base + i`.
    base: u32,
    argc: u32,
    /// Arguments past the positional parameters, moved above the locals.
    extra_start: u32,
    extra_count: u32,
    /// Dynamic bindings and handlers below these are not this frame's.
    dyn_mark: u32,
    handler_base: u32,
    /// This frame's entry in the evaluator's list of calls in progress.
    call_frame: u32,
    want: Want,
};

pub const HandlerKind = enum(u8) { block, tagbody, catch_tag, cleanup, errors };

/// Something a frame established that a non-local exit or a failure is
/// offered to.
pub const Handler = struct {
    kind: HandlerKind,
    frame: u32,
    /// The stack depth and dynamic depth to go back to.
    sp: u32,
    dyn: u32,
    target: u32,
    id: u64,
    /// The jump table of a `tagbody`, the catch-stack depth below a
    /// `catch`, and the kind of an error handler.
    aux: u32,
    level: u32,
};

/// The functions a primitive instruction stands for, called when the
/// arguments are not ones the instruction handles itself.
const fallback_names = [_][]const u8{ "+", "-", "<", ">", "<=", ">=", "=", "1+", "1-", "CAR", "CDR" };

const Fallback = enum(u8) { add, sub, less, greater, less_equal, greater_equal, num_equal, inc, dec, car, cdr };

pub const VM = struct {
    allocator: std.mem.Allocator,
    stack: []Value,
    sp: usize = 0,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    handlers: std.ArrayListUnmanaged(Handler) = .empty,
    /// Where the run in progress set the caller's lexical chains aside.
    chain_mark: usize = 0,
    /// Set while running out of stack is being signaled, which is when
    /// the reserve is open to the handlers.
    in_reserve: bool = false,
    fallbacks: [fallback_names.len]Value = undefined,
    /// The callees megamorphic call sites have looked up, with the epoch
    /// the table was filled in.
    megamorphic: std.AutoHashMapUnmanaged(u64, void) = .empty,
    megamorphic_epoch: u32 = 0,
    /// Every call site's counters added together.
    counters: bytecode.CacheCounters = .{},

    pub fn init(ev: *Evaluator) !*VM {
        const vm = try ev.allocator.create(VM);
        errdefer ev.allocator.destroy(vm);
        const stack = try ev.allocator.alloc(Value, STACK_SLOTS);
        vm.* = .{ .allocator = ev.allocator, .stack = stack };
        for (fallback_names, 0..) |name, i| vm.fallbacks[i] = try ev.interner.intern(name);
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.megamorphic.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.handlers.deinit(self.allocator);
        self.allocator.free(self.stack);
        self.allocator.destroy(self);
    }

    /// Everything a collection has to treat as live.
    pub fn live(self: *const VM) []Value {
        return self.stack[0..self.sp];
    }

    fn pushFrame(self: *VM, ev: *Evaluator, fn_v: Value, base: usize, argc: usize, want: Want, form: Value) Error!void {
        const code = function.asFunction(fn_v).payload.compiled.code;
        if (argc < code.required) return Error.WrongArgCount;
        const positional = code.positional();
        var extra: usize = 0;
        if (argc > positional) {
            if (!code.takes_extra) return Error.WrongArgCount;
            extra = argc - positional;
        }
        const locals_end = base + positional + code.locals;
        const reserve_slots: usize = if (self.in_reserve) 0 else RESERVE_SLOTS;
        const reserve_frames: usize = if (self.in_reserve) 0 else RESERVE_FRAMES;
        if (locals_end + extra + code.max_stack + reserve_slots > self.stack.len) return Error.StackExhausted;
        if (self.frames.items.len + reserve_frames >= MAX_FRAMES) return Error.StackExhausted;
        if (extra > 0) {
            std.mem.copyBackwards(Value, self.stack[locals_end .. locals_end + extra], self.stack[base + positional .. base + argc]);
        } else if (argc < positional) {
            @memset(self.stack[base + argc .. base + positional], value.NIL);
        }
        @memset(self.stack[base + positional .. locals_end], value.NIL);
        self.sp = locals_end + extra;

        const call_frame = ev.call_frames.items.len;
        try ev.call_frames.append(ev.allocator, .{
            .function = fn_v,
            .args = self.stack[base .. base + @min(argc, positional)],
            .form = form,
            .chain_mark = self.chain_mark,
        });
        errdefer ev.call_frames.shrinkRetainingCapacity(call_frame);
        try self.frames.append(self.allocator, .{
            .function = fn_v,
            .code = code,
            .pc = 0,
            .base = @intCast(base),
            .argc = @intCast(argc),
            .extra_start = @intCast(locals_end),
            .extra_count = @intCast(extra),
            .dyn_mark = @intCast(ev.dynamicMark()),
            .handler_base = @intCast(self.handlers.items.len),
            .call_frame = @intCast(call_frame),
            .want = want,
        });
    }

    /// Give up the innermost frame: its dynamic bindings, the handlers
    /// it established, and its entry among the calls in progress.
    fn popFrame(self: *VM, ev: *Evaluator) Frame {
        const fr = self.frames.pop().?;
        if (ev.dynamicMark() > fr.dyn_mark) ev.unwindSpecials(fr.dyn_mark);
        self.dropHandlers(ev, fr.handler_base);
        ev.call_frames.shrinkRetainingCapacity(fr.call_frame);
        return fr;
    }

    fn dropHandlers(self: *VM, ev: *Evaluator, floor: usize) void {
        while (self.handlers.items.len > floor) {
            const h = self.handlers.pop().?;
            if (h.kind == .catch_tag) ev.catch_stack.shrinkRetainingCapacity(h.aux);
        }
    }

    fn execute(self: *VM, ev: *Evaluator, entry: usize) Error!void {
        while (true) {
            self.dispatch(ev, entry) catch |err| {
                if (self.recover(ev, err, entry)) |unhandled| return unhandled;
                continue;
            };
            return;
        }
    }

    fn isTransfer(err: Error) bool {
        return switch (err) {
            Error.BlockReturn, Error.Go, Error.Throw, Error.Quit, Error.OutOfMemory => true,
            else => false,
        };
    }

    fn matches(h: Handler, err: Error, ev: *const Evaluator) bool {
        return switch (h.kind) {
            .block => err == Error.BlockReturn and ev.return_id == h.id,
            .tagbody => err == Error.Go and ev.go_id == h.id,
            .catch_tag => err == Error.Throw and ev.throw_id == h.id,
            .cleanup => true,
            .errors => !isTransfer(err),
        };
    }

    /// Hand a failure or a non-local exit to the innermost handler of
    /// this run that takes it. Returns null once one has, and otherwise
    /// the error, with every frame of the run given up.
    fn recover(self: *VM, ev: *Evaluator, first: Error, entry: usize) ?Error {
        var err = first;
        outer: while (true) {
            if (err == Error.StackExhausted) {
                // Running out again inside a handler for running out is
                // not offered to the handlers a second time.
                if (!self.in_reserve) {
                    self.in_reserve = true;
                    defer self.in_reserve = false;
                    err = ev.signalFailure(err);
                }
            } else if (!isTransfer(err)) {
                err = ev.signalFailure(err);
            }
            if (self.frames.items.len <= entry) return err;
            const floor = self.frames.items[entry].handler_base;
            while (self.handlers.items.len > floor) {
                const h = self.handlers.items[self.handlers.items.len - 1];
                if (matches(h, err, ev)) {
                    self.land(ev, h, err) catch |e| {
                        err = e;
                        continue :outer;
                    };
                    return null;
                }
                _ = self.handlers.pop();
                if (h.kind == .catch_tag) ev.catch_stack.shrinkRetainingCapacity(h.aux);
            }
            while (self.frames.items.len > entry) _ = self.popFrame(ev);
            return err;
        }
    }

    fn land(self: *VM, ev: *Evaluator, h: Handler, err: Error) Error!void {
        while (self.frames.items.len - 1 > h.frame) _ = self.popFrame(ev);
        if (h.kind != .tagbody) {
            _ = self.handlers.pop();
            if (h.kind == .catch_tag) ev.catch_stack.shrinkRetainingCapacity(h.aux);
        }
        ev.unwindSpecials(h.dyn);
        self.sp = h.sp;
        const fr = &self.frames.items[h.frame];
        fr.pc = h.target;
        switch (h.kind) {
            .block, .catch_tag => _ = try ev.unstashTransferValues(),
            .tagbody => fr.pc = fr.code.jump_tables[h.aux][@intCast(ev.go_target.toFixnum())],
            .errors => {
                const caught = try caughtBy(ev, err);
                if (h.aux == @backingInt(bytecode.ErrorsKind.ignore)) {
                    _ = try ev.setValues(&.{ value.NIL, caught });
                } else {
                    _ = try ev.setValues(&.{caught});
                }
            },
            .cleanup => {
                const carried = ev.transfer_values.items;
                if (self.sp + carried.len + 6 + fr.code.max_stack > self.stack.len) return Error.StackExhausted;
                for (carried) |v| self.push(v);
                self.push(Value.fromFixnum(@intCast(carried.len)));
                self.push(Value.fromFixnum(@intCast(ev.return_id)));
                self.push(Value.fromFixnum(@intCast(ev.go_id)));
                self.push(ev.go_target);
                self.push(Value.fromFixnum(@intCast(ev.throw_id)));
                self.push(Value.fromFixnum(@intFromError(err)));
            },
        }
    }

    fn push(self: *VM, v: Value) void {
        self.stack[self.sp] = v;
        self.sp += 1;
    }

    /// The condition an `error` carried, or the name of the failure a
    /// native raised.
    fn caughtBy(ev: *Evaluator, err: Error) Error!Value {
        if (ev.error_condition.raw != 0) {
            const condition = ev.error_condition;
            ev.error_condition = .{ .raw = 0 };
            return condition;
        }
        return ev.interner.internKeyword(@errorName(err));
    }

    fn findHandler(self: *const VM, kind: HandlerKind, id: u64) bool {
        for (self.handlers.items) |h| {
            if (h.kind == kind and h.id == id) return true;
        }
        return false;
    }

    fn setOne(ev: *Evaluator, v: Value) Error!void {
        ev.values.clearRetainingCapacity();
        try ev.values.append(ev.allocator, v);
    }

    fn primary(ev: *const Evaluator) Value {
        return if (ev.values.items.len == 0) value.NIL else ev.values.items[0];
    }

    fn fallback(self: *VM, ev: *Evaluator, which: Fallback, args: []const Value) Error!Value {
        const sym = self.fallbacks[@backingInt(which)];
        const callee = symbol_mod.symbol(sym).function_cell;
        return ev.callFunction(callee, args);
    }

    fn boolean(b: bool) Value {
        return if (b) value.T else value.NIL;
    }

    /// The pairs of keyword arguments, checked as a call's `&key` part:
    /// an even count of them, each key a symbol, and each one named in
    /// `known` unless other keys are allowed.
    fn checkKeys(ev: *Evaluator, pairs: []const Value, known: Value, allow: bool) Error!void {
        if (pairs.len % 2 != 0) return Error.ProgramError;
        var i: usize = 0;
        while (i < pairs.len) : (i += 2) {
            if (!pairs[i].isSymbol()) return Error.ProgramError;
        }
        if (allow) return;
        const aok = try ev.interner.internKeyword("ALLOW-OTHER-KEYS");
        i = 0;
        while (i < pairs.len) : (i += 2) {
            if (pairs[i].equalsRaw(aok) and !pairs[i + 1].equalsRaw(value.NIL)) return;
        }
        const names = heap.asArray(known).storage[0..heap.asArray(known).totalSize()];
        i = 0;
        outer: while (i < pairs.len) : (i += 2) {
            if (pairs[i].equalsRaw(aok)) continue;
            for (names) |n| if (n.equalsRaw(pairs[i])) continue :outer;
            return Error.ProgramError;
        }
    }

    fn checkListKeys(ev: *Evaluator, list: Value, known: Value, allow: bool) Error!void {
        var held = ev.heap.protect();
        defer held.close();
        var cur = list;
        while (!cur.equalsRaw(value.NIL)) {
            if (!cur.isCons()) return Error.BadArgList;
            const key = heap.car(cur);
            if (!key.isSymbol()) return Error.ProgramError;
            const next = heap.cdr(cur);
            if (!next.isCons()) return Error.ProgramError;
            try held.push(key);
            try held.push(heap.car(next));
            cur = heap.cdr(next);
        }
        return checkKeys(ev, held.items(), known, allow);
    }

    fn listKey(list: Value, key: Value) ?Value {
        var cur = list;
        while (cur.isCons()) {
            const next = heap.cdr(cur);
            if (!next.isCons()) return null;
            if (heap.car(cur).equalsRaw(key)) return heap.car(next);
            cur = heap.cdr(next);
        }
        return null;
    }

    pub fn forgetMegamorphic(self: *VM) void {
        self.megamorphic_epoch = 0;
        self.megamorphic.clearRetainingCapacity();
    }

    fn tally(self: *VM, cache: *bytecode.CallCache, comptime field: []const u8) void {
        @field(cache.counters, field) += 1;
        @field(self.counters, field) += 1;
    }

    /// Record that the site whose cache is `cache` is calling `callee`.
    fn noteCall(self: *VM, cache: *bytecode.CallCache, callee: Value) Error!void {
        const epoch = function.call_cache_epoch;
        if (cache.epoch != epoch) {
            cache.epoch = epoch;
            cache.state = .empty;
            cache.count = 0;
        }
        switch (cache.state) {
            .empty => {
                cache.state = .monomorphic;
                cache.targets[0] = callee;
                cache.count = 1;
                self.tally(cache, "misses");
            },
            .monomorphic => {
                if (cache.targets[0].equalsRaw(callee)) {
                    self.tally(cache, "monomorphic");
                    return;
                }
                cache.state = .polymorphic;
                cache.targets[1] = callee;
                cache.count = 2;
                self.tally(cache, "misses");
                self.tally(cache, "to_polymorphic");
            },
            .polymorphic => {
                for (cache.targets[0..cache.count]) |target| {
                    if (target.equalsRaw(callee)) {
                        self.tally(cache, "polymorphic");
                        return;
                    }
                }
                self.tally(cache, "misses");
                if (cache.count < bytecode.POLYMORPHIC_TARGETS) {
                    cache.targets[cache.count] = callee;
                    cache.count += 1;
                    return;
                }
                cache.state = .megamorphic;
                self.tally(cache, "to_megamorphic");
                try self.lookupMegamorphic(callee);
            },
            .megamorphic => {
                self.tally(cache, "megamorphic");
                try self.lookupMegamorphic(callee);
            },
        }
    }

    fn lookupMegamorphic(self: *VM, callee: Value) Error!void {
        const epoch = function.call_cache_epoch;
        if (self.megamorphic_epoch != epoch) {
            self.megamorphic.clearRetainingCapacity();
            self.megamorphic_epoch = epoch;
        }
        _ = try self.megamorphic.getOrPut(self.allocator, callee.raw);
    }

    const Regs = struct {
        code: *const Code,
        words: [*]const u32,
        consts: [*]Value,
        base: usize,
        env: [*]Value,
    };

    fn regs(self: *const VM, fi: usize) Regs {
        const fr = &self.frames.items[fi];
        const f = function.asFunction(fr.function);
        return .{
            .code = fr.code,
            .words = fr.code.words.ptr,
            .consts = fr.code.constants.ptr,
            .base = fr.base,
            .env = f.closedOver().ptr,
        };
    }

    /// The state one run of `dispatch` keeps between instructions.
    const Run = struct {
        vm: *VM,
        ev: *Evaluator,
        entry: usize,
        stack: [*]Value,
        fi: usize,
        r: Regs,
        pc: usize,
        sp: usize,
    };

    /// Whether the run goes on after an instruction.
    const Flow = enum { next, exit };

    fn dispatch(self: *VM, ev: *Evaluator, entry: usize) Error!void {
        const fi = self.frames.items.len - 1;
        var run: Run = .{
            .vm = self,
            .ev = ev,
            .entry = entry,
            .stack = self.stack.ptr,
            .fi = fi,
            .r = self.regs(fi),
            .pc = self.frames.items[fi].pc,
            .sp = self.sp,
        };
        switch (dispatch_kind) {
            .loop => while (true) {
                // Anything the instruction allocates may start a
                // collection, which marks what the stack holds up to here.
                self.sp = run.sp;
                const w = run.r.words[run.pc];
                run.pc += 1;
                switch (bytecode.opOf(w)) {
                    inline else => |op| if (try handle(op, &run, w) == .exit) return,
                }
            },
            .threaded => {
                self.sp = run.sp;
                var w = run.r.words[run.pc];
                run.pc += 1;
                next: switch (bytecode.opOf(w)) {
                    inline else => |op| {
                        if (try handle(op, &run, w) == .exit) return;
                        self.sp = run.sp;
                        w = run.r.words[run.pc];
                        run.pc += 1;
                        continue :next bytecode.opOf(w);
                    },
                }
            },
            .tail => {
                self.sp = run.sp;
                const w = run.r.words[run.pc];
                run.pc += 1;
                return tail_handlers[@backingInt(bytecode.opOf(w))](&run, w);
            },
        }
    }

    const TailHandler = *const fn (run: *Run, w: u32) Error!void;

    const tail_handlers = blk: {
        const ops = @typeInfo(Op).@"enum".field_names;
        var table: [ops.len]TailHandler = undefined;
        for (ops, 0..) |name, i| table[i] = tailHandler(@field(Op, name));
        break :blk table;
    };

    fn tailHandler(comptime op: Op) TailHandler {
        return struct {
            fn runOp(run: *Run, w: u32) Error!void {
                if (try handle(op, run, w) == .exit) return;
                run.vm.sp = run.sp;
                const next = run.r.words[run.pc];
                run.pc += 1;
                return @call(.always_tail, tail_handlers[@backingInt(bytecode.opOf(next))], .{ run, next });
            }
        }.runOp;
    }

    inline fn handle(comptime op: Op, run: *Run, w: u32) Error!Flow {
        return switch (op) {
            .load_const => opLoadConst(run, w),
            .load_nil => opLoadNil(run, w),
            .load_t => opLoadT(run, w),
            .load_fixnum => opLoadFixnum(run, w),
            .pop => opPop(run, w),
            .drop => opDrop(run, w),
            .slide => opSlide(run, w),
            .dup => opDup(run, w),
            .load_local => opLoadLocal(run, w),
            .store_local => opStoreLocal(run, w),
            .load_closed => opLoadClosed(run, w),
            .make_cell => opMakeCell(run, w),
            .load_cell => opLoadCell(run, w),
            .store_cell => opStoreCell(run, w),
            .load_closed_cell => opLoadClosedCell(run, w),
            .store_closed_cell => opStoreClosedCell(run, w),
            .load_global => opLoadGlobal(run, w),
            .store_global => opStoreGlobal(run, w),
            .bind_special => opBindSpecial(run, w),
            .unbind => opUnbind(run, w),
            .save_dynamic => opSaveDynamic(run, w),
            .restore_dynamic => opRestoreDynamic(run, w),
            .save_state => opSaveState(run, w),
            .progv_bind => opProgvBind(run, w),
            .proclaim => opProclaim(run, w),
            .jump_if_bound => opJumpIfBound(run, w),
            .load_function => opLoadFunction(run, w),
            .store_function => opStoreFunction(run, w),
            .make_closure => opMakeClosure(run, w),
            .call => opCall(run, w),
            .call_global => opCall(run, w),
            .apply => opCall(run, w),
            .call_counted => opCall(run, w),
            .@"return" => opReturn(run, w),
            .return_mv => opReturn(run, w),
            .to_mv => opToMv(run, w),
            .mv_primary => opMvPrimary(run, w),
            .values => opValues(run, w),
            .values_list => opValuesList(run, w),
            .mv_list => opMvList(run, w),
            .mv_push => opMvPush(run, w),
            .mv_spread => opMvSpread(run, w),
            .save_mv => opSaveMv(run, w),
            .restore_mv => opRestoreMv(run, w),
            .jump => opJump(run, w),
            .jump_if_nil => opJumpIfNil(run, w),
            .jump_if_true => opJumpIfTrue(run, w),
            .enter_block => opEnterBlock(run, w),
            .enter_tagbody => opEnterBlock(run, w),
            .enter_catch => opEnterCatch(run, w),
            .enter_cleanup => opEnterCleanup(run, w),
            .enter_errors => opEnterCleanup(run, w),
            .leave => opLeave(run, w),
            .unwind => opUnwind(run, w),
            .return_from => opReturnFrom(run, w),
            .go => opReturnFrom(run, w),
            .throw => opThrow(run, w),
            .end_cleanup => opEndCleanup(run, w),
            .errors_ok => opErrorsOk(run, w),
            .optional_arg => opOptionalArg(run, w),
            .rest_arg => opRestArg(run, w),
            .check_keys => opCheckKeys(run, w),
            .key_arg => opKeyArg(run, w),
            .pop_list => opPopList(run, w),
            .jump_if_atom => opJumpIfAtom(run, w),
            .check_end => opCheckEnd(run, w),
            .list_key => opListKey(run, w),
            .check_list_keys => opCheckListKeys(run, w),
            .add => opAdd(run, w),
            .sub => opAdd(run, w),
            .less => opLess(run, w),
            .greater => opLess(run, w),
            .less_equal => opLess(run, w),
            .greater_equal => opLess(run, w),
            .num_equal => opLess(run, w),
            .inc => opInc(run, w),
            .dec => opInc(run, w),
            .eq => opEq(run, w),
            .cons => opCons(run, w),
            .car => opCar(run, w),
            .cdr => opCar(run, w),
            .not => opNot(run, w),
            .interpret => opInterpret(run, w),
        };
    }

    inline fn opLoadConst(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp] = run.r.consts[a];
        run.sp += 1;
        return .next;
    }

    inline fn opLoadNil(run: *Run, _: u32) Error!Flow {
        run.stack[run.sp] = value.NIL;
        run.sp += 1;
        return .next;
    }

    inline fn opLoadT(run: *Run, _: u32) Error!Flow {
        run.stack[run.sp] = value.T;
        run.sp += 1;
        return .next;
    }

    inline fn opLoadFixnum(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp] = Value.fromFixnum(bytecode.fixnumFromOperand(a));
        run.sp += 1;
        return .next;
    }

    inline fn opPop(run: *Run, _: u32) Error!Flow {
        run.sp -= 1;
        return .next;
    }

    inline fn opDrop(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= a;
        return .next;
    }

    inline fn opSlide(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp - 1 - a] = run.stack[run.sp - 1];
        run.sp -= a;
        return .next;
    }

    inline fn opDup(run: *Run, _: u32) Error!Flow {
        run.stack[run.sp] = run.stack[run.sp - 1];
        run.sp += 1;
        return .next;
    }

    inline fn opLoadLocal(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp] = run.stack[run.r.base + a];
        run.sp += 1;
        return .next;
    }

    inline fn opStoreLocal(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        run.stack[run.r.base + a] = run.stack[run.sp];
        return .next;
    }

    inline fn opLoadClosed(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp] = run.r.env[a];
        run.sp += 1;
        return .next;
    }

    inline fn opMakeCell(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const cell = try run.ev.heap.allocCons(run.stack[run.r.base + a], value.NIL);
        run.stack[run.r.base + a] = cell;
        return .next;
    }

    inline fn opLoadCell(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp] = heap.car(run.stack[run.r.base + a]);
        run.sp += 1;
        return .next;
    }

    inline fn opStoreCell(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        heap.setCar(run.ev.heap, run.stack[run.r.base + a], run.stack[run.sp]);
        return .next;
    }

    inline fn opLoadClosedCell(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.sp] = heap.car(run.r.env[a]);
        run.sp += 1;
        return .next;
    }

    inline fn opStoreClosedCell(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        heap.setCar(run.ev.heap, run.r.env[a], run.stack[run.sp]);
        return .next;
    }

    inline fn opLoadGlobal(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const sym = run.r.consts[a];
        var v = symbol_mod.symbol(sym).value_cell;
        if (v.equalsRaw(value.SPECIAL_UNBOUND)) v = try run.ev.recoverUnboundVariable(sym);
        run.stack[run.sp] = v;
        run.sp += 1;
        return .next;
    }

    inline fn opStoreGlobal(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        symbol_mod.symbol(run.r.consts[a]).value_cell = run.stack[run.sp];
        return .next;
    }

    inline fn opBindSpecial(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        try run.ev.bindSpecial(run.r.consts[a], run.stack[run.sp - 1]);
        run.sp -= 1;
        return .next;
    }

    inline fn opUnbind(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.ev.unwindSpecials(run.ev.dynamicMark() - a);
        return .next;
    }

    inline fn opSaveDynamic(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.r.base + a] = Value.fromFixnum(@intCast(run.ev.dynamicMark()));
        return .next;
    }

    inline fn opRestoreDynamic(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.ev.unwindSpecials(@intCast(run.stack[run.r.base + a].toFixnum()));
        return .next;
    }

    inline fn opSaveState(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.stack[run.r.base + a] = Value.fromFixnum(@intCast(run.sp));
        run.stack[run.r.base + a + 1] = Value.fromFixnum(@intCast(run.ev.dynamicMark()));
        return .next;
    }

    inline fn opProgvBind(run: *Run, _: u32) Error!Flow {
        var symbols = run.stack[run.sp - 2];
        var values = run.stack[run.sp - 1];
        while (symbols.isCons()) : (symbols = heap.cdr(symbols)) {
            const sym = heap.car(symbols);
            if (!sym.isSymbol()) return Error.TypeError;
            if (symbol_mod.symbol(sym).constant) return Error.ProgramError;
            if (values.isCons()) {
                try run.ev.bindSpecial(sym, heap.car(values));
                values = heap.cdr(values);
            } else {
                try run.ev.bindSpecial(sym, value.SPECIAL_UNBOUND);
            }
        }
        run.sp -= 2;
        return .next;
    }

    inline fn opProclaim(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const sym = symbol_mod.symbol(run.r.consts[a]);
        sym.special = true;
        if (run.r.words[run.pc] == 1) sym.constant = true;
        run.pc += 1;
        return .next;
    }

    inline fn opJumpIfBound(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const target = run.r.words[run.pc];
        run.pc += 1;
        if (!symbol_mod.symbol(run.r.consts[a]).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) run.pc = target;
        return .next;
    }

    inline fn opLoadFunction(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const sym = run.r.consts[a];
        const f = symbol_mod.symbol(sym).function_cell;
        if (f.equalsRaw(value.SPECIAL_UNBOUND)) return run.ev.unbound(sym, Error.UnboundFunction);
        run.stack[run.sp] = f;
        run.sp += 1;
        return .next;
    }

    inline fn opStoreFunction(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        symbol_mod.symbol(run.r.consts[a]).function_cell = run.stack[run.sp];
        function.invalidateCallCaches();
        return .next;
    }

    inline fn opMakeClosure(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const n = run.r.words[run.pc];
        run.pc += 1;
        const code = function.asFunction(run.r.consts[a]).payload.compiled.code;
        const made = try function.allocCompiled(run.ev.heap, code, run.stack[run.sp - n .. run.sp]);
        run.sp -= n;
        run.stack[run.sp] = made;
        run.sp += 1;
        return .next;
    }

    inline fn opCall(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        var callee: Value = undefined;
        var argc: usize = undefined;
        var mode: bytecode.Mode = undefined;
        switch (bytecode.opOf(w)) {
            .call_global => {
                const sym = run.r.consts[a];
                const operand = run.r.words[run.pc];
                const site = run.r.words[run.pc + 1];
                run.pc += 2;
                argc = bytecode.callArgc(operand);
                mode = bytecode.callMode(operand);
                callee = symbol_mod.symbol(sym).function_cell;
                if (callee.equalsRaw(value.SPECIAL_UNBOUND)) return run.ev.unbound(sym, Error.UnboundFunction);
                try run.vm.noteCall(&run.r.code.caches[site], callee);
            },
            .call, .call_counted => {
                argc = if (bytecode.opOf(w) == .call)
                    bytecode.callArgc(a)
                else
                    @intCast(run.stack[run.r.base + bytecode.callArgc(a)].toFixnum());
                mode = bytecode.callMode(a);
                callee = run.stack[run.sp - argc - 1];
                if (bytecode.opOf(w) == .call) {
                    const site = run.r.words[run.pc];
                    run.pc += 1;
                    try run.vm.noteCall(&run.r.code.caches[site], callee);
                }
                std.mem.copyForwards(Value, run.stack[run.sp - argc - 1 .. run.sp - 1], run.stack[run.sp - argc .. run.sp]);
                run.sp -= 1;
            },
            .apply => {
                const given = bytecode.callArgc(a);
                mode = bytecode.callMode(a);
                const list = run.stack[run.sp - 1];
                var count: usize = 0;
                var cur = list;
                while (cur.isCons()) : (cur = heap.cdr(cur)) count += 1;
                if (!cur.equalsRaw(value.NIL)) return run.ev.typeMismatch(list, "LIST");
                if (run.sp + count + run.r.code.max_stack > run.vm.stack.len) return Error.StackExhausted;
                run.sp -= 1;
                cur = list;
                while (cur.isCons()) : (cur = heap.cdr(cur)) {
                    run.stack[run.sp] = heap.car(cur);
                    run.sp += 1;
                }
                argc = given - 1 + count;
                callee = run.stack[run.sp - argc - 1];
                std.mem.copyForwards(Value, run.stack[run.sp - argc - 1 .. run.sp - 1], run.stack[run.sp - argc .. run.sp]);
                run.sp -= 1;
            },
            else => unreachable,
        }
        while (true) {
            if (callee.isSymbol()) {
                const sym = callee;
                callee = symbol_mod.symbol(sym).function_cell;
                if (callee.equalsRaw(value.SPECIAL_UNBOUND)) return run.ev.unbound(sym, Error.UnboundFunction);
            }
            if (!function.isFunction(callee)) return run.ev.typeMismatch(callee, "FUNCTION");
            const f = function.asFunction(callee);
            switch (f.kind) {
                .compiled => {
                    if (mode == .tail and !f.keeps_caller) {
                        const old = run.vm.frames.items[run.fi];
                        std.mem.copyForwards(Value, run.stack[old.base .. old.base + argc], run.stack[run.sp - argc .. run.sp]);
                        _ = run.vm.popFrame(run.ev);
                        run.vm.sp = old.base + argc;
                        try run.vm.pushFrame(run.ev, callee, old.base, argc, old.want, .{ .raw = 0 });
                    } else {
                        run.vm.frames.items[run.fi].pc = @intCast(run.pc);
                        run.vm.sp = run.sp;
                        try run.vm.pushFrame(run.ev, callee, run.sp - argc, argc, if (mode == .single) .single else .multiple, .{ .raw = 0 });
                    }
                    run.fi = run.vm.frames.items.len - 1;
                    run.r = run.vm.regs(run.fi);
                    run.pc = 0;
                    run.sp = run.vm.sp;
                },
                .native => {
                    run.vm.sp = run.sp;
                    const result = try f.payload.native(@ptrCast(run.ev), run.stack[run.sp - argc .. run.sp]);
                    run.sp -= argc;
                    if (mode == .single) {
                        run.stack[run.sp] = result;
                        run.sp += 1;
                    } else if (!f.preserves_values) {
                        try setOne(run.ev, result);
                    }
                },
                .closure => {
                    run.vm.sp = run.sp;
                    run.ev.call_form = .{ .raw = 0 };
                    const result = try run.ev.callFunction(callee, run.stack[run.sp - argc .. run.sp]);
                    run.sp -= argc;
                    if (mode == .single) {
                        run.stack[run.sp] = result;
                        run.sp += 1;
                    }
                },
                .funcallable => {
                    callee = f.payload.funcallable.function;
                    continue;
                },
            }
            break;
        }
        return .next;
    }

    inline fn opReturn(run: *Run, w: u32) Error!Flow {
        const single = bytecode.opOf(w) == .@"return";
        const result = if (single) run.stack[run.sp - 1] else value.NIL;
        const fr = run.vm.popFrame(run.ev);
        run.sp = fr.base;
        if (run.fi == run.entry) {
            if (single) try setOne(run.ev, result);
            run.vm.sp = run.sp;
            return .exit;
        }
        run.fi -= 1;
        run.r = run.vm.regs(run.fi);
        run.pc = run.vm.frames.items[run.fi].pc;
        switch (fr.want) {
            .single => {
                run.stack[run.sp] = if (single) result else primary(run.ev);
                run.sp += 1;
            },
            .multiple => if (single) try setOne(run.ev, result),
        }
        return .next;
    }

    inline fn opToMv(run: *Run, _: u32) Error!Flow {
        try setOne(run.ev, run.stack[run.sp - 1]);
        run.sp -= 1;
        return .next;
    }

    inline fn opMvPrimary(run: *Run, _: u32) Error!Flow {
        run.stack[run.sp] = primary(run.ev);
        run.sp += 1;
        return .next;
    }

    inline fn opValues(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        _ = try run.ev.setValues(run.stack[run.sp - a .. run.sp]);
        run.sp -= a;
        return .next;
    }

    inline fn opValuesList(run: *Run, _: u32) Error!Flow {
        const list = run.stack[run.sp - 1];
        run.ev.values.clearRetainingCapacity();
        var cur = list;
        while (cur.isCons()) : (cur = heap.cdr(cur)) try run.ev.values.append(run.ev.allocator, heap.car(cur));
        if (!cur.equalsRaw(value.NIL)) return run.ev.typeMismatch(list, "LIST");
        run.sp -= 1;
        return .next;
    }

    inline fn opMvList(run: *Run, _: u32) Error!Flow {
        const list = try run.ev.heap.list(run.ev.values.items);
        run.stack[run.sp] = list;
        run.sp += 1;
        return .next;
    }

    inline fn opMvPush(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const held = run.ev.values.items;
        for (0..a) |i| {
            run.stack[run.sp] = if (i < held.len) held[i] else value.NIL;
            run.sp += 1;
        }
        return .next;
    }

    inline fn opMvSpread(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const held = run.ev.values.items;
        if (run.sp + held.len + run.r.code.max_stack > run.vm.stack.len) return Error.StackExhausted;
        @memcpy(run.stack[run.sp .. run.sp + held.len], held);
        run.sp += held.len;
        run.stack[run.r.base + a] = Value.fromFixnum(run.stack[run.r.base + a].toFixnum() + @as(i64, @intCast(held.len)));
        return .next;
    }

    inline fn opSaveMv(run: *Run, _: u32) Error!Flow {
        const held = run.ev.values.items;
        if (run.sp + held.len + 1 + run.r.code.max_stack > run.vm.stack.len) return Error.StackExhausted;
        @memcpy(run.stack[run.sp .. run.sp + held.len], held);
        run.sp += held.len;
        run.stack[run.sp] = Value.fromFixnum(@intCast(held.len));
        run.sp += 1;
        return .next;
    }

    inline fn opRestoreMv(run: *Run, _: u32) Error!Flow {
        const count: usize = @intCast(run.stack[run.sp - 1].toFixnum());
        _ = try run.ev.setValues(run.stack[run.sp - 1 - count .. run.sp - 1]);
        run.sp -= count + 1;
        return .next;
    }

    inline fn opJump(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.pc = a;
        return .next;
    }

    inline fn opJumpIfNil(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        if (run.stack[run.sp].equalsRaw(value.NIL)) run.pc = a;
        return .next;
    }

    inline fn opJumpIfTrue(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        run.sp -= 1;
        if (!run.stack[run.sp].equalsRaw(value.NIL)) run.pc = a;
        return .next;
    }

    inline fn opEnterBlock(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const is_block = bytecode.opOf(w) == .enter_block;
        const target = run.r.words[run.pc];
        const level = run.r.words[run.pc + 1];
        run.pc += 2;
        const id = if (is_block) blk: {
            run.ev.block_counter += 1;
            break :blk run.ev.block_counter;
        } else blk: {
            run.ev.tagbody_counter += 1;
            break :blk run.ev.tagbody_counter;
        };
        run.stack[run.r.base + a] = Value.fromFixnum(@intCast(id));
        try run.vm.handlers.append(run.vm.allocator, .{
            .kind = if (is_block) .block else .tagbody,
            .frame = @intCast(run.fi),
            .sp = @intCast(run.sp),
            .dyn = @intCast(run.ev.dynamicMark()),
            .target = if (is_block) target else 0,
            .id = id,
            .aux = if (is_block) 0 else target,
            .level = level,
        });
        return .next;
    }

    inline fn opEnterCatch(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const level = run.r.words[run.pc];
        run.pc += 1;
        const depth = run.ev.catch_stack.items.len;
        const id = try run.ev.pushCatch(run.stack[run.sp - 1]);
        run.sp -= 1;
        try run.vm.handlers.append(run.vm.allocator, .{
            .kind = .catch_tag,
            .frame = @intCast(run.fi),
            .sp = @intCast(run.sp),
            .dyn = @intCast(run.ev.dynamicMark()),
            .target = a,
            .id = id,
            .aux = @intCast(depth),
            .level = level,
        });
        return .next;
    }

    inline fn opEnterCleanup(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const is_cleanup = bytecode.opOf(w) == .enter_cleanup;
        const kind: u32 = if (is_cleanup) 0 else run.r.words[run.pc];
        if (!is_cleanup) run.pc += 1;
        const level = run.r.words[run.pc];
        run.pc += 1;
        try run.vm.handlers.append(run.vm.allocator, .{
            .kind = if (is_cleanup) .cleanup else .errors,
            .frame = @intCast(run.fi),
            .sp = @intCast(run.sp),
            .dyn = @intCast(run.ev.dynamicMark()),
            .target = a,
            .id = 0,
            .aux = kind,
            .level = level,
        });
        return .next;
    }

    inline fn opLeave(run: *Run, _: u32) Error!Flow {
        const h = run.vm.handlers.pop().?;
        if (h.kind == .catch_tag) run.ev.catch_stack.shrinkRetainingCapacity(h.aux);
        return .next;
    }

    inline fn opUnwind(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const operand = run.r.words[run.pc];
        run.pc += 1;
        const slot = operand & ((1 << 23) - 1);
        const keep = operand >> 23;
        const floor = run.vm.frames.items[run.fi].handler_base;
        while (run.vm.handlers.items.len > floor and run.vm.handlers.items[run.vm.handlers.items.len - 1].level >= a) {
            const h = run.vm.handlers.pop().?;
            if (h.kind == .catch_tag) run.ev.catch_stack.shrinkRetainingCapacity(h.aux);
        }
        run.ev.unwindSpecials(@intCast(run.stack[run.r.base + slot + 1].toFixnum()));
        const target: usize = @intCast(run.stack[run.r.base + slot].toFixnum());
        if (keep == 1) {
            run.stack[target] = run.stack[run.sp - 1];
            run.sp = target + 1;
        } else {
            run.sp = target;
        }
        return .next;
    }

    inline fn opReturnFrom(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const id: u64 = @intCast(run.stack[run.sp - 1].toFixnum());
        run.sp -= 1;
        if (bytecode.opOf(w) == .return_from) {
            if (!run.vm.findHandler(.block, id)) return Error.ControlError;
            run.ev.return_id = id;
            try run.ev.stashTransferValues();
            return Error.BlockReturn;
        }
        if (!run.vm.findHandler(.tagbody, id)) return Error.ControlError;
        run.ev.go_id = id;
        run.ev.go_target = Value.fromFixnum(a);
        return Error.Go;
    }

    inline fn opThrow(run: *Run, _: u32) Error!Flow {
        const tag = run.stack[run.sp - 1];
        run.sp -= 1;
        const id = run.ev.findCatch(tag) orelse return Error.ControlError;
        run.ev.throw_id = id;
        try run.ev.stashTransferValues();
        return Error.Throw;
    }

    inline fn opEndCleanup(run: *Run, _: u32) Error!Flow {
        const code = run.stack[run.sp - 1].toFixnum();
        if (code == -1) {
            const count: usize = @intCast(run.stack[run.sp - 2].toFixnum());
            _ = try run.ev.setValues(run.stack[run.sp - 2 - count .. run.sp - 2]);
            run.sp -= count + 2;
        } else {
            run.ev.throw_id = @intCast(run.stack[run.sp - 2].toFixnum());
            run.ev.go_target = run.stack[run.sp - 3];
            run.ev.go_id = @intCast(run.stack[run.sp - 4].toFixnum());
            run.ev.return_id = @intCast(run.stack[run.sp - 5].toFixnum());
            const count: usize = @intCast(run.stack[run.sp - 6].toFixnum());
            run.ev.transfer_values.clearRetainingCapacity();
            try run.ev.transfer_values.appendSlice(run.ev.allocator, run.stack[run.sp - 6 - count .. run.sp - 6]);
            run.sp -= count + 6;
            const err: anyerror = @errorFromInt(@as(u16, @intCast(code)));
            return @as(Error, @errorCast(err));
        }
        return .next;
    }

    inline fn opErrorsOk(run: *Run, _: u32) Error!Flow {
        try run.ev.values.insert(run.ev.allocator, 0, value.NIL);
        return .next;
    }

    inline fn opOptionalArg(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const target = run.r.words[run.pc];
        run.pc += 1;
        if (run.vm.frames.items[run.fi].argc > a) run.pc = target;
        return .next;
    }

    inline fn opRestArg(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const fr = run.vm.frames.items[run.fi];
        const list = try run.ev.heap.list(run.stack[fr.extra_start .. fr.extra_start + fr.extra_count]);
        run.stack[run.r.base + a] = list;
        return .next;
    }

    inline fn opCheckKeys(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const allow = run.r.words[run.pc] == 1;
        run.pc += 1;
        const fr = run.vm.frames.items[run.fi];
        try checkKeys(run.ev, run.stack[fr.extra_start .. fr.extra_start + fr.extra_count], run.r.consts[a], allow);
        return .next;
    }

    inline fn opKeyArg(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const slot = run.r.words[run.pc];
        const target = run.r.words[run.pc + 1];
        run.pc += 2;
        const fr = run.vm.frames.items[run.fi];
        const pairs = run.stack[fr.extra_start .. fr.extra_start + fr.extra_count];
        var i: usize = 0;
        while (i + 1 < pairs.len) : (i += 2) {
            if (pairs[i].equalsRaw(run.r.consts[a])) {
                run.stack[run.r.base + slot] = pairs[i + 1];
                run.pc = target;
                break;
            }
        }
        return .next;
    }

    inline fn opPopList(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const list = run.stack[run.r.base + a];
        if (!list.isCons()) return Error.WrongArgCount;
        run.stack[run.sp] = heap.car(list);
        run.sp += 1;
        run.stack[run.r.base + a] = heap.cdr(list);
        return .next;
    }

    inline fn opJumpIfAtom(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const target = run.r.words[run.pc];
        run.pc += 1;
        if (!run.stack[run.r.base + a].isCons()) run.pc = target;
        return .next;
    }

    inline fn opCheckEnd(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        if (!run.stack[run.r.base + a].equalsRaw(value.NIL)) return Error.WrongArgCount;
        return .next;
    }

    inline fn opListKey(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const list_slot = run.r.words[run.pc];
        const slot = run.r.words[run.pc + 1];
        const target = run.r.words[run.pc + 2];
        run.pc += 3;
        if (listKey(run.stack[run.r.base + list_slot], run.r.consts[a])) |found| {
            run.stack[run.r.base + slot] = found;
            run.pc = target;
        }
        return .next;
    }

    inline fn opCheckListKeys(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        const list_slot = run.r.words[run.pc];
        const allow = run.r.words[run.pc + 1] == 1;
        run.pc += 2;
        try checkListKeys(run.ev, run.stack[run.r.base + list_slot], run.r.consts[a], allow);
        return .next;
    }

    inline fn opAdd(run: *Run, w: u32) Error!Flow {
        const x = run.stack[run.sp - 2];
        const y = run.stack[run.sp - 1];
        const is_add = bytecode.opOf(w) == .add;
        if (x.isFixnum() and y.isFixnum()) {
            const n = if (is_add) x.toFixnum() + y.toFixnum() else x.toFixnum() - y.toFixnum();
            if (n >= value.FIXNUM_MIN and n <= value.FIXNUM_MAX) {
                run.stack[run.sp - 2] = Value.fromFixnum(n);
                run.sp -= 1;
                return .next;
            }
        }
        run.stack[run.sp - 2] = try run.vm.fallback(run.ev, if (is_add) .add else .sub, run.stack[run.sp - 2 .. run.sp]);
        run.sp -= 1;
        return .next;
    }

    inline fn opLess(run: *Run, w: u32) Error!Flow {
        const x = run.stack[run.sp - 2];
        const y = run.stack[run.sp - 1];
        const op = bytecode.opOf(w);
        if (x.isFixnum() and y.isFixnum()) {
            const p = x.toFixnum();
            const q = y.toFixnum();
            run.stack[run.sp - 2] = boolean(switch (op) {
                .less => p < q,
                .greater => p > q,
                .less_equal => p <= q,
                .greater_equal => p >= q,
                else => p == q,
            });
            run.sp -= 1;
            return .next;
        }
        const which: Fallback = switch (op) {
            .less => .less,
            .greater => .greater,
            .less_equal => .less_equal,
            .greater_equal => .greater_equal,
            else => .num_equal,
        };
        run.stack[run.sp - 2] = try run.vm.fallback(run.ev, which, run.stack[run.sp - 2 .. run.sp]);
        run.sp -= 1;
        return .next;
    }

    inline fn opInc(run: *Run, w: u32) Error!Flow {
        const x = run.stack[run.sp - 1];
        const is_inc = bytecode.opOf(w) == .inc;
        if (x.isFixnum()) {
            const n = if (is_inc) x.toFixnum() + 1 else x.toFixnum() - 1;
            if (n >= value.FIXNUM_MIN and n <= value.FIXNUM_MAX) {
                run.stack[run.sp - 1] = Value.fromFixnum(n);
                return .next;
            }
        }
        run.stack[run.sp - 1] = try run.vm.fallback(run.ev, if (is_inc) .inc else .dec, run.stack[run.sp - 1 .. run.sp]);
        return .next;
    }

    inline fn opEq(run: *Run, _: u32) Error!Flow {
        run.stack[run.sp - 2] = boolean(run.stack[run.sp - 2].equalsRaw(run.stack[run.sp - 1]));
        run.sp -= 1;
        return .next;
    }

    inline fn opCons(run: *Run, _: u32) Error!Flow {
        const made = try run.ev.heap.allocCons(run.stack[run.sp - 2], run.stack[run.sp - 1]);
        run.stack[run.sp - 2] = made;
        run.sp -= 1;
        return .next;
    }

    inline fn opCar(run: *Run, w: u32) Error!Flow {
        const x = run.stack[run.sp - 1];
        const is_car = bytecode.opOf(w) == .car;
        if (x.isCons()) {
            run.stack[run.sp - 1] = if (is_car) heap.car(x) else heap.cdr(x);
        } else if (x.equalsRaw(value.NIL)) {
            run.stack[run.sp - 1] = value.NIL;
        } else {
            run.stack[run.sp - 1] = try run.vm.fallback(run.ev, if (is_car) .car else .cdr, run.stack[run.sp - 1 .. run.sp]);
        }
        return .next;
    }

    inline fn opNot(run: *Run, _: u32) Error!Flow {
        run.stack[run.sp - 1] = boolean(run.stack[run.sp - 1].equalsRaw(value.NIL));
        return .next;
    }

    inline fn opInterpret(run: *Run, w: u32) Error!Flow {
        const a: u32 = w >> 8;
        _ = try run.ev.eval(run.r.consts[a]);
        return .next;
    }
};

/// Call the compiled function `fn_v` with `args`, from outside a run or
/// from a native inside one.
pub fn call(ev: *Evaluator, fn_v: Value, args: []const Value) Error!Value {
    const vm = try ev.machine();
    const start = vm.sp;
    if (start + args.len > vm.stack.len) return Error.StackExhausted;
    @memcpy(vm.stack[start .. start + args.len], args);
    vm.sp = start + args.len;
    defer vm.sp = start;

    ev.eval_depth += 1;
    defer ev.eval_depth -= 1;
    // Compiled code sees the null lexical environment, whatever the
    // caller was evaluating in.
    const chains = try ev.env.saveChains();
    defer ev.env.restoreChains(chains);
    ev.env.top_value = null;
    ev.env.top_function = null;
    const outer_mark = vm.chain_mark;
    vm.chain_mark = chains;
    defer vm.chain_mark = outer_mark;

    const form = ev.call_form;
    ev.call_form = .{ .raw = 0 };
    const entry = vm.frames.items.len;
    try vm.pushFrame(ev, fn_v, start, args.len, .multiple, form);
    try vm.execute(ev, entry);
    return VM.primary(ev);
}
