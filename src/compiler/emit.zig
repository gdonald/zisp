//! The second pass: bytecode for one function of the tree the first pass
//! built, and for each function inside it.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const equality = @import("../runtime/equality.zig");
const bytecode = @import("bytecode.zig");
const convert = @import("convert.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = eval_mod.Error;
const Op = bytecode.Op;
const Node = convert.Node;
const Lambda = convert.Lambda;
const Var = convert.Var;
const Target = convert.Target;

/// Where a form's result goes.
const Ctx = enum {
    /// Nowhere: the form runs for its effects.
    effect,
    /// On the operand stack, one value.
    single,
    /// In the values register, every value.
    multiple,
    /// Back to the caller, as the function's result.
    tail,
};

const BlockScope = struct {
    block: *convert.Block,
    ctx: Ctx,
    depth: u32,
    level: u32,
    end: u32,
    state_slot: ?u32,
    tail: bool,
};

const TagbodyScope = struct {
    tagbody: *convert.Tagbody,
    depth: u32,
    level: u32,
    labels: []u32,
    state_slot: ?u32,
};

/// Something an exit to an enclosing block or tag passes through.
const Scope = union(enum) {
    block: BlockScope,
    tagbody: TagbodyScope,
    handler,
    special,
    unknown_depth,
};

const Fixup = struct { index: usize, label: u32, whole_word: bool };

pub const Emitter = struct {
    ev: *Evaluator,
    arena: std.mem.Allocator,
    lambda: *Lambda,
    words: std.ArrayListUnmanaged(u32) = .empty,
    constants: std.ArrayListUnmanaged(Value) = .empty,
    tables: std.ArrayListUnmanaged([]u32) = .empty,
    labels: std.ArrayListUnmanaged(?u32) = .empty,
    fixups: std.ArrayListUnmanaged(Fixup) = .empty,
    slot_names: std.ArrayListUnmanaged(Value) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    depth: u32 = 0,
    max_depth: u32 = 0,
    level: u32 = 0,
    call_sites: u32 = 0,
    positions: std.ArrayListUnmanaged(bytecode.Position) = .empty,
    source_file: ?[]const u8 = null,

    // --- low-level emission ---

    fn emit(self: *Emitter, op: Op, a: u32) Error!void {
        try self.words.append(self.arena, bytecode.encode(op, a));
    }

    fn word(self: *Emitter, w: u32) Error!void {
        try self.words.append(self.arena, w);
    }

    fn grow(self: *Emitter, n: u32) void {
        self.depth += n;
        if (self.depth > self.max_depth) self.max_depth = self.depth;
    }

    fn shrink(self: *Emitter, n: u32) void {
        std.debug.assert(self.depth >= n);
        self.depth -= n;
    }

    fn newLabel(self: *Emitter) Error!u32 {
        try self.labels.append(self.arena, null);
        return @intCast(self.labels.items.len - 1);
    }

    fn place(self: *Emitter, label: u32) void {
        self.labels.items[label] = @intCast(self.words.items.len);
    }

    fn emitJump(self: *Emitter, op: Op, label: u32) Error!void {
        try self.fixups.append(self.arena, .{ .index = self.words.items.len, .label = label, .whole_word = false });
        try self.emit(op, 0);
    }

    fn labelWord(self: *Emitter, label: u32) Error!void {
        try self.fixups.append(self.arena, .{ .index = self.words.items.len, .label = label, .whole_word = true });
        try self.word(0);
    }

    fn allocSlot(self: *Emitter, name: Value) Error!u32 {
        try self.slot_names.append(self.arena, name);
        return @intCast(self.slot_names.items.len - 1);
    }

    fn hiddenSlot(self: *Emitter) Error!u32 {
        return self.allocSlot(.{ .raw = 0 });
    }

    /// The pool entry for `v`. Constants that are `equal` share one.
    fn constant(self: *Emitter, v: Value) Error!u32 {
        for (self.constants.items, 0..) |held, i| {
            var budget: usize = COMPARE_BUDGET;
            if (similar(held, v, &budget)) return @intCast(i);
        }
        try self.constants.append(self.arena, v);
        return @intCast(self.constants.items.len - 1);
    }

    /// How many conses two constants are compared through before they
    /// are taken to differ, which is what stops a circular one.
    const COMPARE_BUDGET: usize = 4096;

    fn similar(a: Value, b: Value, budget: *usize) bool {
        if (a.isCons() and b.isCons()) {
            if (budget.* == 0) return false;
            budget.* -= 1;
            return similar(heap.car(a), heap.car(b), budget) and similar(heap.cdr(a), heap.cdr(b), budget);
        }
        if (a.isCons() or b.isCons()) return false;
        return equality.equal(a, b);
    }

    fn loadConstant(self: *Emitter, v: Value) Error!void {
        if (v.equalsRaw(value.NIL)) {
            try self.emit(.load_nil, 0);
        } else if (v.equalsRaw(value.T)) {
            try self.emit(.load_t, 0);
        } else if (v.isFixnum() and v.toFixnum() >= bytecode.FIXNUM_IMMEDIATE_MIN and v.toFixnum() <= bytecode.FIXNUM_IMMEDIATE_MAX) {
            try self.emit(.load_fixnum, bytecode.fixnumOperand(v.toFixnum()));
        } else {
            try self.emit(.load_const, try self.constant(v));
        }
        self.grow(1);
    }

    /// Send the value on the stack where `ctx` wants it.
    fn finishSingle(self: *Emitter, ctx: Ctx) Error!void {
        switch (ctx) {
            .effect => try self.emit(.pop, 0),
            .single => return,
            .multiple => try self.emit(.to_mv, 0),
            .tail => try self.emit(.@"return", 0),
        }
        self.shrink(1);
    }

    /// Send what the values register holds where `ctx` wants it.
    fn finishMultiple(self: *Emitter, ctx: Ctx) Error!void {
        switch (ctx) {
            .effect, .multiple => {},
            .single => {
                try self.emit(.mv_primary, 0);
                self.grow(1);
            },
            .tail => try self.emit(.return_mv, 0),
        }
    }

    /// Code after a non-local exit never runs, but the depth it is
    /// emitted at has to read as if the form had produced its result.
    fn deadResult(self: *Emitter, start: u32, ctx: Ctx) void {
        self.depth = start;
        if (ctx == .single) self.grow(1);
    }

    /// The context the body of a form that binds or establishes
    /// something runs in. Such a form is never in tail position, since
    /// what it established has to be undone when its body returns.
    fn inside(ctx: Ctx) Ctx {
        return if (ctx == .tail) .multiple else ctx;
    }

    fn leaveInside(self: *Emitter, ctx: Ctx) Error!void {
        if (ctx == .tail) try self.emit(.return_mv, 0);
    }

    // --- variables ---

    fn loadVar(self: *Emitter, v: *const Var) Error!void {
        if (v.owner == self.lambda) {
            try self.emit(if (v.boxed()) .load_cell else .load_local, v.slot);
        } else {
            try self.emit(if (v.boxed()) .load_closed_cell else .load_closed, self.lambda.closedIndex(v));
        }
        self.grow(1);
    }

    fn storeVar(self: *Emitter, v: *const Var) Error!void {
        if (v.owner == self.lambda) {
            try self.emit(if (v.boxed()) .store_cell else .store_local, v.slot);
        } else {
            std.debug.assert(v.boxed());
            try self.emit(.store_closed_cell, self.lambda.closedIndex(v));
        }
        self.shrink(1);
    }

    /// What a closure made here holds for `v`: its cell when it has one.
    fn loadRaw(self: *Emitter, v: *const Var) Error!void {
        if (v.owner == self.lambda) {
            try self.emit(.load_local, v.slot);
        } else {
            try self.emit(.load_closed, self.lambda.closedIndex(v));
        }
        self.grow(1);
    }

    /// Check the value on top of the stack is of the type `v` was
    /// declared with, where the policy asks for that.
    fn checkVar(self: *Emitter, v: *const Var) Error!void {
        if (!v.check) return;
        try self.emit(.check_type, try self.constant(v.declared));
    }

    /// Bind `target` to the value in `slot`. A lexical variable takes the
    /// slot over. Returns whether a dynamic binding was made.
    fn bindFromSlot(self: *Emitter, target: Target, slot: u32) Error!bool {
        switch (target) {
            .lexical => |v| {
                v.slot = slot;
                self.slot_names.items[slot] = v.sym;
                if (v.check) {
                    try self.emit(.load_local, slot);
                    self.grow(1);
                    try self.checkVar(v);
                    try self.emit(.pop, 0);
                    self.shrink(1);
                }
                if (v.boxed()) try self.emit(.make_cell, slot);
                return false;
            },
            .special => |sym| {
                try self.emit(.load_local, slot);
                try self.emit(.bind_special, try self.constant(sym));
                return true;
            },
        }
    }

    /// Bind `target` to the value on top of the stack.
    fn bindTop(self: *Emitter, target: Target) Error!bool {
        switch (target) {
            .lexical => |v| {
                try self.checkVar(v);
                v.slot = try self.allocSlot(v.sym);
                try self.emit(.store_local, v.slot);
                self.shrink(1);
                if (v.boxed()) try self.emit(.make_cell, v.slot);
                return false;
            },
            .special => |sym| {
                try self.emit(.bind_special, try self.constant(sym));
                self.shrink(1);
                return true;
            },
        }
    }

    fn slotFor(self: *Emitter, target: Target) Error!u32 {
        return switch (target) {
            .lexical => |v| self.allocSlot(v.sym),
            .special => self.hiddenSlot(),
        };
    }

    // --- forms ---

    fn compile(self: *Emitter, n: *Node, ctx: Ctx) Error!void {
        switch (n.*) {
            .constant => |v| {
                if (ctx == .effect) return;
                try self.loadConstant(v);
                try self.finishSingle(ctx);
            },
            .local_ref => |v| {
                if (ctx == .effect) return;
                try self.loadVar(v);
                try self.finishSingle(ctx);
            },
            .the_ => |t| {
                if (!t.check) return self.compile(t.form, ctx);
                try self.compile(t.form, .single);
                try self.emit(.check_type, try self.constant(t.spec));
                try self.finishSingle(ctx);
            },
            .local_set => |set| {
                try self.compile(set.value, .single);
                try self.checkVar(set.v);
                if (ctx != .effect) {
                    try self.emit(.dup, 0);
                    self.grow(1);
                }
                try self.storeVar(set.v);
                if (ctx != .effect) try self.finishSingle(ctx);
            },
            .global_ref => |sym| {
                try self.emit(.load_global, try self.constant(sym));
                self.grow(1);
                try self.finishSingle(ctx);
            },
            .global_set => |set| {
                try self.compile(set.value, .single);
                if (ctx != .effect) {
                    try self.emit(.dup, 0);
                    self.grow(1);
                }
                try self.emit(.store_global, try self.constant(set.sym));
                self.shrink(1);
                if (ctx != .effect) try self.finishSingle(ctx);
            },
            .function_ref => |sym| {
                try self.emit(.load_function, try self.constant(sym));
                self.grow(1);
                try self.finishSingle(ctx);
            },
            .call_global => |call| {
                for (call.args) |arg| try self.compile(arg, .single);
                try self.notePosition(call.form);
                try self.emit(.call_global, try self.constant(call.sym));
                try self.callTail(@intCast(call.args.len), 0, ctx, .call_global);
            },
            .call => |call| {
                try self.compile(call.callee, .single);
                for (call.args) |arg| try self.compile(arg, .single);
                try self.notePosition(call.form);
                try self.callTail(@intCast(call.args.len), 1, ctx, .call);
            },
            .apply => |call| {
                try self.compile(call.callee, .single);
                for (call.args) |arg| try self.compile(arg, .single);
                try self.callTail(@intCast(call.args.len), 1, ctx, .apply);
            },
            .primitive => |prim| {
                for (prim.args) |arg| try self.compile(arg, .single);
                try self.emit(prim.op, 0);
                self.shrink(@intCast(prim.args.len));
                self.grow(1);
                try self.finishSingle(ctx);
            },
            .if_ => |branch| {
                const otherwise = try self.newLabel();
                const end = try self.newLabel();
                try self.compile(branch.test_form, .single);
                try self.emitJump(.jump_if_nil, otherwise);
                self.shrink(1);
                const start = self.depth;
                try self.compile(branch.then, ctx);
                const after = self.depth;
                if (ctx != .tail) try self.emitJump(.jump, end);
                self.place(otherwise);
                self.depth = start;
                try self.compile(branch.otherwise, ctx);
                std.debug.assert(ctx == .tail or self.depth == after);
                self.place(end);
            },
            .progn => |forms| {
                if (forms.len == 0) {
                    var nil_node: Node = .{ .constant = value.NIL };
                    return self.compile(&nil_node, ctx);
                }
                for (forms[0 .. forms.len - 1]) |form| try self.compile(form, .effect);
                try self.compile(forms[forms.len - 1], ctx);
            },
            .let => |let| try self.compileLet(let.sequential, let.bindings, let.body, ctx),
            .lambda => |l| {
                try self.makeClosure(l);
                try self.finishSingle(ctx);
            },
            .local_functions => |lf| try self.compileLocalFunctions(lf.recursive, lf.vars, lf.lambdas, lf.body, ctx),
            .block => |b| try self.compileBlock(b, ctx),
            .return_from => |r| try self.compileReturnFrom(r.block, r.value, r.exit, ctx),
            .tagbody => |t| try self.compileTagbody(t, ctx),
            .go => |g| try self.compileGo(g.tagbody, g.index, g.exit, ctx),
            .catch_ => |c| {
                try self.compile(c.tag, .single);
                const inner = inside(ctx);
                const land = try self.newLabel();
                const end = try self.newLabel();
                self.shrink(1);
                const start = self.depth;
                try self.emitJump(.enter_catch, land);
                try self.word(self.level);
                try self.withHandler(c.body, .multiple);
                try self.emit(.leave, 0);
                try self.emitJump(.jump, end);
                self.place(land);
                self.place(end);
                self.depth = start;
                try self.finishMultiple(inner);
                try self.leaveInside(ctx);
            },
            .throw => |t| {
                const start = self.depth;
                try self.compile(t.tag, .single);
                try self.compile(t.value, .multiple);
                try self.emit(.throw, 0);
                self.deadResult(start, ctx);
            },
            .unwind_protect => |u| {
                const inner = inside(ctx);
                const cleanup = try self.newLabel();
                const start = self.depth;
                try self.emitJump(.enter_cleanup, cleanup);
                try self.word(self.level);
                try self.withHandler(u.protected, .multiple);
                try self.emit(.leave, 0);
                try self.emit(.save_mv, 0);
                try self.emit(.load_fixnum, bytecode.fixnumOperand(-1));
                self.place(cleanup);
                self.grow(2);
                try self.scopes.append(self.arena, .unknown_depth);
                try self.compile(u.cleanup, .effect);
                _ = self.scopes.pop();
                try self.emit(.end_cleanup, 0);
                self.depth = start;
                try self.finishMultiple(inner);
                try self.leaveInside(ctx);
            },
            .errors => |e| {
                const inner = inside(ctx);
                const fail = try self.newLabel();
                const start = self.depth;
                try self.emitJump(.enter_errors, fail);
                try self.word(@backingInt(e.kind));
                try self.word(self.level);
                try self.withHandler(e.body, .multiple);
                try self.emit(.leave, 0);
                if (e.kind == .catch_error) try self.emit(.errors_ok, 0);
                self.place(fail);
                self.depth = start;
                try self.finishMultiple(inner);
                try self.leaveInside(ctx);
            },
            .values => |forms| {
                for (forms) |form| try self.compile(form, .single);
                try self.emit(.values, @intCast(forms.len));
                self.shrink(@intCast(forms.len));
                try self.finishMultiple(ctx);
            },
            .values_list => |form| {
                try self.compile(form, .single);
                try self.emit(.values_list, 0);
                self.shrink(1);
                try self.finishMultiple(ctx);
            },
            .mv_list => |form| {
                try self.compile(form, .multiple);
                try self.emit(.mv_list, 0);
                self.grow(1);
                try self.finishSingle(ctx);
            },
            .mv_call => |call| {
                try self.compile(call.callee, .single);
                const counter = try self.hiddenSlot();
                try self.emit(.load_fixnum, 0);
                self.grow(1);
                try self.emit(.store_local, counter);
                self.shrink(1);
                try self.scopes.append(self.arena, .unknown_depth);
                for (call.args) |arg| {
                    try self.compile(arg, .multiple);
                    try self.emit(.mv_spread, counter);
                }
                _ = self.scopes.pop();
                try self.emit(.call_counted, bytecode.callOperand(counter, self.modeFor(ctx)));
                self.shrink(1);
                try self.afterCall(ctx);
            },
            .mv_prog1 => |m| {
                try self.compile(m.first, .multiple);
                try self.emit(.save_mv, 0);
                self.grow(1);
                try self.scopes.append(self.arena, .unknown_depth);
                try self.compile(m.rest, .effect);
                _ = self.scopes.pop();
                try self.emit(.restore_mv, 0);
                self.shrink(1);
                try self.finishMultiple(ctx);
            },
            .mv_bind => |m| {
                try self.compile(m.form, .multiple);
                try self.emit(.mv_push, @intCast(m.targets.len));
                self.grow(@intCast(m.targets.len));
                var specials: u32 = 0;
                var i = m.targets.len;
                while (i > 0) {
                    i -= 1;
                    if (try self.bindTop(m.targets[i])) specials += 1;
                }
                try self.bodyWithSpecials(m.body, specials, ctx);
            },
            .progv => |p| {
                try self.compile(p.symbols, .single);
                try self.compile(p.values, .single);
                const saved = try self.hiddenSlot();
                try self.emit(.save_dynamic, saved);
                try self.emit(.progv_bind, 0);
                self.shrink(2);
                try self.scopes.append(self.arena, .special);
                try self.compile(p.body, inside(ctx));
                _ = self.scopes.pop();
                try self.emit(.restore_dynamic, saved);
                try self.leaveInside(ctx);
            },
            .destructure => |d| {
                try self.compile(d.value, .single);
                const list = try self.hiddenSlot();
                try self.emit(.store_local, list);
                self.shrink(1);
                const scope_mark = self.scopes.items.len;
                var specials: u32 = 0;
                try self.emitPattern(d.pattern, list, &specials);
                self.scopes.shrinkRetainingCapacity(scope_mark);
                try self.bodyWithSpecials(d.body, specials, ctx);
            },
            .interpret => |form| {
                try self.emit(.interpret, try self.constant(form));
                try self.finishMultiple(ctx);
            },
            .define_function => |d| {
                try self.makeClosure(d.lambda);
                try self.emit(.store_function, try self.constant(d.sym));
                self.shrink(1);
                if (d.expansion.raw != 0) {
                    try self.loadConstant(d.sym);
                    try self.loadConstant(d.expansion);
                    try self.emit(.call_global, try self.constant(try self.ev.interner.intern("%PUT-INLINE-EXPANSION")));
                    try self.callTail(2, 0, .effect, .call_global);
                }
                var result: Node = .{ .constant = d.result };
                try self.compile(&result, ctx);
            },
            .define_variable => |d| {
                const k = try self.constant(d.sym);
                try self.emit(.proclaim, k);
                try self.word(0);
                if (d.init) |init| {
                    const done = try self.newLabel();
                    if (d.kind == .defvar) {
                        try self.emitJump(.jump_if_bound, done);
                        self.words.items[self.words.items.len - 1] = bytecode.encode(.jump_if_bound, k);
                        self.fixups.items[self.fixups.items.len - 1].whole_word = true;
                        self.fixups.items[self.fixups.items.len - 1].index = self.words.items.len;
                        try self.word(0);
                    }
                    try self.compile(init, .single);
                    try self.emit(.store_global, k);
                    self.shrink(1);
                    if (d.kind == .defconstant) {
                        try self.emit(.proclaim, k);
                        try self.word(1);
                    }
                    self.place(done);
                }
                var result: Node = .{ .constant = d.sym };
                try self.compile(&result, ctx);
            },
        }
    }

    /// What a call in `ctx` does with its result. With `(debug 3)` a
    /// call in tail position still keeps its caller's frame, so a
    /// backtrace shows every call.
    fn modeFor(self: *const Emitter, ctx: Ctx) bytecode.Mode {
        return switch (ctx) {
            .effect, .single => .single,
            .multiple => .multiple,
            .tail => if (self.lambda.policy.debug == 3) .multiple else .tail,
        };
    }

    /// Note where the call about to be emitted was written, under
    /// `(debug 3)`.
    fn notePosition(self: *Emitter, form: Value) Error!void {
        if (self.lambda.policy.debug < 3 or form.raw == 0) return;
        const table = self.ev.positions orelse return;
        const pos = table.userPosition(form) orelse return;
        if (self.source_file == null) self.source_file = pos.file;
        try self.positions.append(self.arena, .{
            .pc = @intCast(self.words.items.len),
            .line = @intCast(pos.line),
            .column = @intCast(pos.column),
        });
    }

    /// Emit the operand of the call just started and account for its
    /// result. `callee_slots` is 1 when the function sits on the stack
    /// below its arguments.
    fn callTail(self: *Emitter, argc: u32, callee_slots: u32, ctx: Ctx, op: Op) Error!void {
        const operand = bytecode.callOperand(argc, self.modeFor(ctx));
        if (op == .call_global) {
            try self.word(operand);
        } else {
            try self.emit(op, operand);
        }
        if (op == .call or op == .call_global) {
            try self.word(self.call_sites);
            self.call_sites += 1;
        }
        self.shrink(argc + callee_slots);
        try self.afterCall(ctx);
    }

    fn afterCall(self: *Emitter, ctx: Ctx) Error!void {
        switch (ctx) {
            .effect => {
                self.grow(1);
                try self.emit(.pop, 0);
                self.shrink(1);
            },
            .single => self.grow(1),
            .multiple => {},
            // A callee the machine cannot replace the frame with, such
            // as a native, returns here, and this returns what it did.
            .tail => try self.emit(.return_mv, 0),
        }
    }

    fn withHandler(self: *Emitter, body: *Node, ctx: Ctx) Error!void {
        self.level += 1;
        try self.scopes.append(self.arena, .handler);
        try self.compile(body, ctx);
        _ = self.scopes.pop();
        self.level -= 1;
    }

    fn bodyWithSpecials(self: *Emitter, body: *Node, specials: u32, ctx: Ctx) Error!void {
        if (specials == 0) return self.compile(body, ctx);
        try self.scopes.append(self.arena, .special);
        try self.compile(body, inside(ctx));
        _ = self.scopes.pop();
        if (ctx == .tail) {
            try self.emit(.return_mv, 0);
        } else {
            try self.emit(.unbind, specials);
        }
    }

    fn compileLet(self: *Emitter, sequential: bool, bindings: []convert.Binding, body: *Node, ctx: Ctx) Error!void {
        var specials: u32 = 0;
        const scope_mark = self.scopes.items.len;
        if (sequential) {
            for (bindings) |b| {
                try self.compile(b.init, .single);
                if (try self.bindTop(b.target)) {
                    if (specials == 0) try self.scopes.append(self.arena, .special);
                    specials += 1;
                }
            }
        } else {
            for (bindings) |b| try self.compile(b.init, .single);
            var i = bindings.len;
            while (i > 0) {
                i -= 1;
                if (try self.bindTop(bindings[i].target)) specials += 1;
            }
        }
        self.scopes.shrinkRetainingCapacity(scope_mark);
        try self.bodyWithSpecials(body, specials, ctx);
    }

    fn makeClosure(self: *Emitter, l: *Lambda) Error!void {
        const code = try compileFunction(self.ev, self.arena, l);
        const template = try function.allocCompiled(self.ev.heap, code, &.{});
        try self.ev.pin(template);
        for (l.captures.items) |v| try self.loadRaw(v);
        try self.emit(.make_closure, try self.constant(template));
        try self.word(@intCast(l.captures.items.len));
        self.shrink(@intCast(l.captures.items.len));
        self.grow(1);
    }

    fn compileLocalFunctions(self: *Emitter, recursive: bool, vars: []*Var, lambdas: []*Lambda, body: *Node, ctx: Ctx) Error!void {
        if (recursive) {
            for (vars) |v| {
                v.slot = try self.allocSlot(v.sym);
                if (v.boxed()) {
                    try self.emit(.load_nil, 0);
                    try self.emit(.store_local, v.slot);
                    try self.emit(.make_cell, v.slot);
                }
            }
            for (vars, lambdas) |v, l| {
                try self.makeClosure(l);
                try self.storeVar(v);
            }
        } else {
            for (lambdas) |l| try self.makeClosure(l);
            var i = vars.len;
            while (i > 0) {
                i -= 1;
                _ = try self.bindTop(.{ .lexical = vars[i] });
            }
        }
        try self.compile(body, ctx);
    }

    fn stateSlot(self: *Emitter, needed: bool) Error!?u32 {
        if (!needed) return null;
        const slot = try self.hiddenSlot();
        _ = try self.hiddenSlot();
        try self.emit(.save_state, slot);
        return slot;
    }

    fn compileBlock(self: *Emitter, b: *convert.Block, ctx: Ctx) Error!void {
        const state_slot = try self.stateSlot(b.needs_state);
        if (!b.dynamic) {
            const end = try self.newLabel();
            try self.scopes.append(self.arena, .{ .block = .{
                .block = b,
                .ctx = ctx,
                .depth = self.depth,
                .level = self.level,
                .end = end,
                .state_slot = state_slot,
                .tail = ctx == .tail,
            } });
            try self.compile(b.body, ctx);
            _ = self.scopes.pop();
            self.place(end);
            return;
        }
        const inner = inside(ctx);
        const id = b.id_var.?;
        id.slot = try self.hiddenSlot();
        const land = try self.newLabel();
        const end = try self.newLabel();
        const start = self.depth;
        try self.emit(.enter_block, id.slot);
        try self.labelWord(land);
        try self.word(self.level);
        try self.scopes.append(self.arena, .{ .block = .{
            .block = b,
            .ctx = inner,
            .depth = start,
            .level = self.level,
            .end = end,
            .state_slot = state_slot,
            .tail = false,
        } });
        self.level += 1;
        try self.compile(b.body, inner);
        self.level -= 1;
        _ = self.scopes.pop();
        try self.emit(.leave, 0);
        try self.emitJump(.jump, end);
        self.place(land);
        self.depth = start;
        if (inner == .single) {
            try self.emit(.mv_primary, 0);
            self.grow(1);
        }
        self.place(end);
        try self.leaveInside(ctx);
    }

    /// Whether anything between here and the scope at `index` changes
    /// the stack depth or the dynamic state on the way out.
    fn crossesState(self: *const Emitter, index: usize) bool {
        for (self.scopes.items[index + 1 ..]) |scope| {
            switch (scope) {
                .handler, .special, .unknown_depth => return true,
                .block => |b| if (b.block.dynamic) return true,
                .tagbody => |t| if (t.tagbody.dynamic) return true,
            }
        }
        return false;
    }

    fn exitTo(self: *Emitter, index: usize, depth: u32, level: u32, state_slot: ?u32, keep: u32) Error!void {
        if (self.crossesState(index)) {
            try self.emit(.unwind, level);
            try self.word(state_slot.? | (keep << 23));
            return;
        }
        const extra = self.depth - depth - keep;
        if (extra == 0) return;
        try self.emit(if (keep == 1) .slide else .drop, extra);
    }

    fn findScope(self: *const Emitter, comptime kind: std.meta.Tag(Scope), ptr: *const anyopaque) usize {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scopes.items[i];
            if (scope != kind) continue;
            const held: *const anyopaque = switch (kind) {
                .block => scope.block.block,
                .tagbody => scope.tagbody.tagbody,
                else => unreachable,
            };
            if (held == ptr) return i;
        }
        unreachable;
    }

    fn compileReturnFrom(self: *Emitter, b: *convert.Block, form: *Node, exit: convert.Exit, ctx: Ctx) Error!void {
        const start = self.depth;
        if (exit == .dynamic) {
            try self.compile(form, .multiple);
            try self.loadRaw(b.id_var.?);
            try self.emit(.return_from, 0);
            self.deadResult(start, ctx);
            return;
        }
        const index = self.findScope(.block, b);
        const scope = self.scopes.items[index].block;
        if (scope.tail) {
            try self.compile(form, .tail);
            self.deadResult(start, ctx);
            return;
        }
        try self.compile(form, scope.ctx);
        try self.exitTo(index, scope.depth, scope.level, scope.state_slot, if (scope.ctx == .single) 1 else 0);
        try self.emitJump(.jump, scope.end);
        self.deadResult(start, ctx);
    }

    fn compileTagbody(self: *Emitter, t: *convert.Tagbody, ctx: Ctx) Error!void {
        const state_slot = try self.stateSlot(t.needs_state);
        const labels = try self.arena.alloc(u32, t.tag_count);
        for (labels) |*label| label.* = try self.newLabel();
        const start = self.depth;
        if (t.dynamic) {
            const id = t.id_var.?;
            id.slot = try self.hiddenSlot();
            try self.emit(.enter_tagbody, id.slot);
            try self.word(@intCast(self.tables.items.len));
            try self.word(self.level);
            try self.tables.append(self.arena, labels);
            self.level += 1;
        }
        try self.scopes.append(self.arena, .{ .tagbody = .{
            .tagbody = t,
            .depth = start,
            .level = self.level,
            .labels = labels,
            .state_slot = state_slot,
        } });
        for (t.items) |item| switch (item) {
            .tag => |i| {
                std.debug.assert(self.depth == start);
                self.place(labels[i]);
            },
            .form => |form| try self.compile(form, .effect),
        };
        _ = self.scopes.pop();
        if (t.dynamic) {
            self.level -= 1;
            try self.emit(.leave, 0);
        }
        var nil_node: Node = .{ .constant = value.NIL };
        try self.compile(&nil_node, ctx);
    }

    fn compileGo(self: *Emitter, t: *convert.Tagbody, index: u32, exit: convert.Exit, ctx: Ctx) Error!void {
        const start = self.depth;
        if (exit == .dynamic) {
            try self.loadRaw(t.id_var.?);
            try self.emit(.go, index);
            self.deadResult(start, ctx);
            return;
        }
        const scope_index = self.findScope(.tagbody, t);
        const scope = self.scopes.items[scope_index].tagbody;
        try self.exitTo(scope_index, scope.depth, scope.level, scope.state_slot, 0);
        try self.emitJump(.jump, scope.labels[index]);
        self.deadResult(start, ctx);
    }

    // --- destructuring ---

    fn noteSpecial(self: *Emitter, made: bool, specials: *u32) Error!void {
        if (!made) return;
        if (specials.* == 0) try self.scopes.append(self.arena, .special);
        specials.* += 1;
    }

    fn bindPatternFromSlot(self: *Emitter, target: convert.PatternTarget, slot: u32, specials: *u32) Error!void {
        switch (target) {
            .target => |t| try self.noteSpecial(try self.bindFromSlot(t, slot), specials),
            .nested => |p| try self.emitPattern(p, slot, specials),
            .empty => try self.emit(.check_end, slot),
        }
    }

    fn patternSlot(self: *Emitter, target: convert.PatternTarget) Error!u32 {
        return switch (target) {
            .target => |t| self.slotFor(t),
            else => self.hiddenSlot(),
        };
    }

    fn bindPatternTop(self: *Emitter, target: convert.PatternTarget, specials: *u32) Error!void {
        const slot = try self.patternSlot(target);
        try self.emit(.store_local, slot);
        self.shrink(1);
        try self.bindPatternFromSlot(target, slot, specials);
    }

    /// Bind `p` against the list in `list`, which is used up as the
    /// pattern is walked.
    fn emitPattern(self: *Emitter, p: *convert.Pattern, list: u32, specials: *u32) Error!void {
        if (p.whole) |whole| {
            try self.emit(.load_local, list);
            self.grow(1);
            try self.bindPatternTop(whole, specials);
        }
        for (p.required) |target| {
            try self.emit(.pop_list, list);
            self.grow(1);
            try self.bindPatternTop(target, specials);
        }
        for (p.optional) |opt| {
            const missing = try self.newLabel();
            const done = try self.newLabel();
            const slot = try self.patternSlot(opt.target);
            const supplied_slot = if (opt.supplied) |s| try self.slotFor(s) else 0;
            try self.emit(.jump_if_atom, list);
            try self.labelWord(missing);
            try self.emit(.pop_list, list);
            try self.emit(.store_local, slot);
            if (opt.supplied != null) {
                try self.emit(.load_t, 0);
                try self.emit(.store_local, supplied_slot);
            }
            try self.emitJump(.jump, done);
            self.place(missing);
            try self.compile(opt.init, .single);
            try self.emit(.store_local, slot);
            self.shrink(1);
            if (opt.supplied != null) {
                try self.emit(.load_nil, 0);
                try self.emit(.store_local, supplied_slot);
            }
            self.place(done);
            self.grow(1);
            self.shrink(1);
            try self.bindPatternFromSlot(opt.target, slot, specials);
            if (opt.supplied) |s| try self.noteSpecial(try self.bindFromSlot(s, supplied_slot), specials);
        }
        if (p.rest) |rest| {
            const slot = try self.patternSlot(rest);
            try self.emit(.load_local, list);
            try self.emit(.store_local, slot);
            self.grow(1);
            self.shrink(1);
            try self.bindPatternFromSlot(rest, slot, specials);
        }
        if (p.has_key) {
            try self.emit(.check_list_keys, try self.keywordVector(p.keys));
            try self.word(list);
            try self.word(@intFromBool(p.allow_other_keys));
            for (p.keys) |key| {
                const found = try self.newLabel();
                const done = try self.newLabel();
                const slot = try self.patternSlot(key.target);
                const supplied_slot = if (key.supplied) |s| try self.slotFor(s) else 0;
                try self.emit(.list_key, try self.constant(key.keyword));
                try self.word(list);
                try self.word(slot);
                try self.labelWord(found);
                try self.compile(key.init, .single);
                try self.emit(.store_local, slot);
                self.shrink(1);
                if (key.supplied != null) {
                    try self.emit(.load_nil, 0);
                    try self.emit(.store_local, supplied_slot);
                }
                try self.emitJump(.jump, done);
                self.place(found);
                if (key.supplied != null) {
                    try self.emit(.load_t, 0);
                    try self.emit(.store_local, supplied_slot);
                }
                self.place(done);
                try self.bindPatternFromSlot(key.target, slot, specials);
                if (key.supplied) |s| try self.noteSpecial(try self.bindFromSlot(s, supplied_slot), specials);
            }
        } else if (p.rest == null) {
            try self.emit(.check_end, list);
        }
        for (p.aux) |a| {
            try self.compile(a.init, .single);
            try self.noteSpecial(try self.bindTop(a.target), specials);
        }
    }

    fn keywordVector(self: *Emitter, keys: anytype) Error!u32 {
        var held = self.ev.heap.protect();
        defer held.close();
        for (keys) |key| try held.push(key.keyword);
        const vector = try self.ev.heap.allocVector(held.items());
        try self.ev.pin(vector);
        try self.constants.append(self.arena, vector);
        return @intCast(self.constants.items.len - 1);
    }

    // --- the function's own lambda list ---

    fn prologue(self: *Emitter, l: *Lambda) Error!u32 {
        var specials: u32 = 0;
        for (l.required, 0..) |target, i| {
            _ = try self.allocSlot(.{ .raw = 0 });
            if (try self.bindFromSlot(target, @intCast(i))) specials += 1;
        }
        const required: u32 = @intCast(l.required.len);
        for (l.optional) |_| _ = try self.allocSlot(.{ .raw = 0 });
        for (l.optional, 0..) |opt, j| {
            const position: u32 = required + @as(u32, @intCast(j));
            const supplied = try self.newLabel();
            const done = try self.newLabel();
            const supplied_slot = if (opt.supplied) |s| try self.slotFor(s) else 0;
            try self.emit(.optional_arg, position);
            try self.labelWord(supplied);
            try self.compile(opt.init, .single);
            try self.emit(.store_local, position);
            self.shrink(1);
            if (opt.supplied != null) {
                try self.emit(.load_nil, 0);
                try self.emit(.store_local, supplied_slot);
                try self.emitJump(.jump, done);
                self.place(supplied);
                try self.emit(.load_t, 0);
                try self.emit(.store_local, supplied_slot);
            } else {
                self.place(supplied);
            }
            self.place(done);
            if (try self.bindFromSlot(opt.target, position)) specials += 1;
            if (opt.supplied) |s| {
                if (try self.bindFromSlot(s, supplied_slot)) specials += 1;
            }
        }
        if (l.rest) |rest| {
            const slot = try self.slotFor(rest);
            try self.emit(.rest_arg, slot);
            if (try self.bindFromSlot(rest, slot)) specials += 1;
        }
        if (l.has_key) {
            try self.emit(.check_keys, try self.keywordVector(l.keys));
            try self.word(@intFromBool(l.allow_other_keys));
            for (l.keys) |key| {
                const found = try self.newLabel();
                const done = try self.newLabel();
                const slot = try self.slotFor(key.target);
                const supplied_slot = if (key.supplied) |s| try self.slotFor(s) else 0;
                try self.emit(.key_arg, try self.constant(key.keyword));
                try self.word(slot);
                try self.labelWord(found);
                try self.compile(key.init, .single);
                try self.emit(.store_local, slot);
                self.shrink(1);
                if (key.supplied != null) {
                    try self.emit(.load_nil, 0);
                    try self.emit(.store_local, supplied_slot);
                }
                try self.emitJump(.jump, done);
                self.place(found);
                if (key.supplied != null) {
                    try self.emit(.load_t, 0);
                    try self.emit(.store_local, supplied_slot);
                }
                self.place(done);
                if (try self.bindFromSlot(key.target, slot)) specials += 1;
                if (key.supplied) |s| {
                    if (try self.bindFromSlot(s, supplied_slot)) specials += 1;
                }
            }
        }
        for (l.aux) |a| {
            try self.compile(a.init, .single);
            if (try self.bindTop(a.target)) specials += 1;
        }
        return specials;
    }

    fn finish(self: *Emitter, l: *Lambda) Error!*bytecode.Code {
        for (self.fixups.items) |fix| {
            const target = self.labels.items[fix.label].?;
            if (fix.whole_word) {
                self.words.items[fix.index] = target;
            } else {
                const op = bytecode.opOf(self.words.items[fix.index]);
                self.words.items[fix.index] = bytecode.encode(op, target);
            }
        }
        const allocator = self.ev.heap.allocator;
        const tables = try allocator.alloc([]const u32, self.tables.items.len);
        for (self.tables.items, 0..) |labels, i| {
            const offsets = try allocator.alloc(u32, labels.len);
            for (labels, 0..) |label, j| offsets[j] = self.labels.items[label].?;
            tables[i] = offsets;
        }
        const positional: u32 = @intCast(l.required.len + l.optional.len);
        const caches = try allocator.alloc(bytecode.CallCache, self.call_sites);
        @memset(caches, .{});
        const code = try allocator.create(bytecode.Code);
        code.* = .{
            .words = try allocator.dupe(u32, self.words.items),
            .constants = try allocator.dupe(Value, self.constants.items),
            .jump_tables = tables,
            .name = l.name,
            .required = @intCast(l.required.len),
            .optional = @intCast(l.optional.len),
            .takes_extra = l.rest != null or l.has_key,
            .locals = @as(u32, @intCast(self.slot_names.items.len)) - positional,
            .max_stack = self.max_depth + 2,
            .slot_names = try allocator.dupe(Value, self.slot_names.items),
            .caches = caches,
            .check_args = l.policy.safety >= 1,
            .positions = try allocator.dupe(bytecode.Position, self.positions.items),
            .source_file = if (self.source_file) |file| try allocator.dupe(u8, file) else null,
        };
        // Variable names are kept for a listing or a debugger unless the
        // policy says debugging does not matter.
        if (l.policy.debug == 0) @memset(@constCast(code.slot_names), .{ .raw = 0 });
        try self.ev.registerCode(code);
        return code;
    }
};

/// Bytecode for `l`, and for every function inside it.
pub fn compileFunction(ev: *Evaluator, arena: std.mem.Allocator, l: *Lambda) Error!*bytecode.Code {
    var e: Emitter = .{ .ev = ev, .arena = arena, .lambda = l };
    const specials = try e.prologue(l);
    if (specials > 0) {
        try e.compile(l.body, .multiple);
        try e.emit(.return_mv, 0);
    } else {
        try e.compile(l.body, .tail);
    }
    return e.finish(l);
}
