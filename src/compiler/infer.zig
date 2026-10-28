//! The typing pass, between converting a form and emitting its code.
//!
//! It runs once the whole tree is converted, so it knows which variables
//! are ever assigned. It finds what it can of each form's type, from
//! declarations, `the`, constants, the initial values of variables
//! nothing assigns, `typep` tests, and the result types the compiler
//! derived for global functions, and gives each primitive whose
//! arguments it has types for the instruction that does not check them.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const convert = @import("convert.zig");
const bytecode = @import("bytecode.zig");

const Value = value.Value;
const Error = eval_mod.Error;
const Node = convert.Node;
const Lambda = convert.Lambda;
const Type = convert.Type;
const Range = convert.Range;
const Op = bytecode.Op;

/// The largest fixnum whose single-float is exact, so that a constant of
/// at most this size can stand in for its float in single-float
/// arithmetic.
const EXACT_SINGLE_FLOAT_INTEGER: i64 = 1 << 24;

/// Type the tree of `l`, and say what its body's type is.
pub fn run(converter: *convert.Converter, l: *Lambda) Error!Type {
    const ev = converter.ev;
    var inferrer: Inferrer = .{
        .converter = converter,
        .sym_typep = try ev.interner.intern("TYPEP"),
        .derived_key = try ev.interner.intern(DERIVED_TYPE_KEY),
        .derive = derivingFunctionTypes(ev),
    };
    defer inferrer.block_types.deinit(converter.arena);
    return inferrer.lambdaBody(l);
}

/// Record `result` as the type calls to the global function `sym` return.
pub fn recordDerivedType(ev: *eval_mod.Evaluator, sym: Value, result: Type) Error!void {
    var held = ev.heap.protect();
    defer held.close();
    try held.push(try typeSpec(ev, result));
    try symbol_mod.plistPut(ev.heap, sym, try ev.interner.intern(DERIVED_TYPE_KEY), held.items()[0]);
}

const DERIVED_TYPE_KEY = "%DERIVED-TYPE";

/// The name of the variable that says whether a call to a global
/// function is typed by the result type derived for it.
pub const DERIVE_FUNCTION_TYPES = "*DERIVE-FUNCTION-TYPES*";

fn derivingFunctionTypes(ev: *eval_mod.Evaluator) bool {
    const sym = ev.interner.internExtension(DERIVE_FUNCTION_TYPES) catch return false;
    const setting = symbol_mod.symbol(sym).value_cell;
    return !setting.equalsRaw(value.NIL) and !setting.equalsRaw(value.SPECIAL_UNBOUND);
}

/// The Lisp type specifier for `t`, or NIL when it is unknown.
pub fn typeSpec(ev: *eval_mod.Evaluator, t: Type) Error!Value {
    return switch (t) {
        .unknown => value.NIL,
        .single_float => try ev.interner.intern("SINGLE-FLOAT"),
        .fixnum => |r| blk: {
            if (r.lo == Range.all.lo and r.hi == Range.all.hi) break :blk try ev.interner.intern("FIXNUM");
            break :blk try ev.heap.list(&.{ try ev.interner.intern("INTEGER"), Value.fromFixnum(r.lo), Value.fromFixnum(r.hi) });
        },
    };
}

const Inferrer = struct {
    converter: *convert.Converter,
    sym_typep: Value,
    derived_key: Value,
    derive: bool,
    /// What each block's `return-from`s have handed it so far.
    block_types: std.AutoHashMapUnmanaged(*convert.Block, Type) = .empty,
    policy: eval_mod.Policy = .{},

    fn lambdaBody(self: *Inferrer, l: *Lambda) Error!Type {
        const saved = self.policy;
        defer self.policy = saved;
        self.policy = l.policy;
        for (l.optional) |o| _ = try self.visit(o.init);
        for (l.keys) |k| _ = try self.visit(k.init);
        try self.bindings(l.aux);
        return self.visit(l.body);
    }

    fn bindings(self: *Inferrer, list: []const convert.Binding) Error!void {
        for (list) |b| {
            const t = try self.visit(b.init);
            switch (b.target) {
                .lexical => |v| if (!v.assigned) {
                    v.known = Type.meet(v.known, t);
                },
                .special => {},
            }
        }
    }

    fn visitAll(self: *Inferrer, nodes: []const *Node) Error!void {
        for (nodes) |n| _ = try self.visit(n);
    }

    fn visit(self: *Inferrer, n: *Node) Error!Type {
        switch (n.*) {
            .constant => |v| {
                if (v.isFixnum()) return .{ .fixnum = .{ .lo = v.toFixnum(), .hi = v.toFixnum() } };
                if (v.isSingleFloat()) return .single_float;
                return .unknown;
            },
            .local_ref => |v| return v.known,
            .local_set => |set| return self.visit(set.value),
            .global_ref, .function_ref, .interpret => return .unknown,
            .global_set => |set| return self.visit(set.value),
            .call_global => |call| {
                try self.visitAll(call.args);
                return self.typeCallResult(n);
            },
            .call => |call| {
                _ = try self.visit(call.callee);
                try self.visitAll(call.args);
                return .unknown;
            },
            .apply => |call| {
                _ = try self.visit(call.callee);
                try self.visitAll(call.args);
                return .unknown;
            },
            .primitive => return self.primitive(n),
            .if_ => |branch| {
                _ = try self.visit(branch.test_form);
                const then = try self.narrowed(branch.test_form, branch.then);
                return Type.join(then, try self.visit(branch.otherwise));
            },
            .progn => |forms| {
                var last: Type = .unknown;
                for (forms) |f| last = try self.visit(f);
                return last;
            },
            .let => |let| {
                try self.bindings(let.bindings);
                return self.visit(let.body);
            },
            .lambda => |l| {
                _ = try self.lambdaBody(l);
                return .unknown;
            },
            .local_functions => |local| {
                for (local.lambdas) |l| _ = try self.lambdaBody(l);
                return self.visit(local.body);
            },
            .block => |b| {
                const body = try self.visit(b.body);
                const returned = self.block_types.get(b) orelse return body;
                return Type.join(body, returned);
            },
            .return_from => |exit| {
                const t = try self.visit(exit.value);
                const slot = try self.block_types.getOrPut(self.converter.arena, exit.block);
                slot.value_ptr.* = if (slot.found_existing) Type.join(slot.value_ptr.*, t) else t;
                return .unknown;
            },
            .tagbody => |t| {
                for (t.items) |item| switch (item) {
                    .form => |f| _ = try self.visit(f),
                    .tag => {},
                };
                return .unknown;
            },
            .go => return .unknown,
            .catch_ => |c| {
                _ = try self.visit(c.tag);
                _ = try self.visit(c.body);
                return .unknown;
            },
            .throw => |t| {
                _ = try self.visit(t.tag);
                _ = try self.visit(t.value);
                return .unknown;
            },
            .unwind_protect => |u| {
                const t = try self.visit(u.protected);
                _ = try self.visit(u.cleanup);
                return t;
            },
            .errors => |e| {
                _ = try self.visit(e.body);
                return .unknown;
            },
            .values => |forms| {
                try self.visitAll(forms);
                return .unknown;
            },
            .values_list, .mv_list => |form| {
                _ = try self.visit(form);
                return .unknown;
            },
            .mv_call => |call| {
                _ = try self.visit(call.callee);
                try self.visitAll(call.args);
                return .unknown;
            },
            .mv_prog1 => |mv| {
                const t = try self.visit(mv.first);
                _ = try self.visit(mv.rest);
                return t;
            },
            .mv_bind => |mv| {
                _ = try self.visit(mv.form);
                return self.visit(mv.body);
            },
            .progv => |p| {
                _ = try self.visit(p.symbols);
                _ = try self.visit(p.values);
                return self.visit(p.body);
            },
            .destructure => |d| {
                _ = try self.visit(d.value);
                return self.visit(d.body);
            },
            .the_ => |the| return Type.meet(convert.specType(the.spec), try self.visit(the.form)),
            .define_function => |def| {
                try recordDerivedType(self.converter.ev, def.sym, try self.lambdaBody(def.lambda));
                return .unknown;
            },
            .define_variable => |def| {
                if (def.init) |init| _ = try self.visit(init);
                return .unknown;
            },
        }
    }

    /// The type of a call to a global function, from the result type
    /// derived for it, with the call wrapped in a `the` of that type so
    /// a function redefined since cannot hand back something else.
    fn typeCallResult(self: *Inferrer, n: *Node) Error!Type {
        if (!self.derive) return .unknown;
        const sym = n.call_global.sym;
        const spec = symbol_mod.plistGet(sym, self.derived_key) orelse return .unknown;
        const t = convert.specType(spec);
        if (t == .unknown) return .unknown;
        const call = try self.converter.node(n.*);
        n.* = .{ .the_ = .{ .spec = try self.converter.keep(spec), .form = call, .check = self.policy.safety >= 1 } };
        return t;
    }

    /// The type of `then`, with the variable a `(typep var 'type)` test
    /// names taken to be of that type, when nothing assigns it.
    fn narrowed(self: *Inferrer, test_form: *const Node, then: *Node) Error!Type {
        if (test_form.* != .call_global) return self.visit(then);
        const call = test_form.call_global;
        if (!call.sym.equalsRaw(self.sym_typep) or call.args.len != 2) return self.visit(then);
        if (call.args[0].* != .local_ref or call.args[1].* != .constant) return self.visit(then);
        const v = call.args[0].local_ref;
        if (v.assigned) return self.visit(then);
        const outer = v.known;
        defer v.known = outer;
        v.known = Type.meet(outer, convert.specType(call.args[1].constant));
        return self.visit(then);
    }

    fn primitive(self: *Inferrer, n: *Node) Error!Type {
        const prim = &n.primitive;
        var types: [2]Type = .{ .unknown, .unknown };
        for (prim.args, 0..) |arg, i| types[i] = try self.visit(arg);
        switch (prim.op) {
            .add, .sub, .mul => {
                if (bothFixnums(types)) |r| {
                    prim.op = switch (prim.op) {
                        .add => .add_fixnums,
                        .sub => .sub_fixnums,
                        else => .mul_fixnums,
                    };
                    const range = switch (prim.op) {
                        .add_fixnums => Range.of(@as(i128, r[0].lo) + r[1].lo, @as(i128, r[0].hi) + r[1].hi),
                        .sub_fixnums => Range.of(@as(i128, r[0].lo) - r[1].hi, @as(i128, r[0].hi) - r[1].lo),
                        else => productRange(r[0], r[1]),
                    };
                    return if (range) |within| .{ .fixnum = within } else .unknown;
                }
                if (try self.singleFloatOperands(prim.args, types)) {
                    prim.op = switch (prim.op) {
                        .add => .add_single_floats,
                        .sub => .sub_single_floats,
                        else => .mul_single_floats,
                    };
                    return .single_float;
                }
                return .unknown;
            },
            .inc, .dec => {
                const is_inc = prim.op == .inc;
                switch (types[0]) {
                    .fixnum => |r| {
                        prim.op = if (is_inc) .inc_fixnum else .dec_fixnum;
                        const range = if (is_inc) Range.of(@as(i128, r.lo) + 1, @as(i128, r.hi) + 1) else Range.of(@as(i128, r.lo) - 1, @as(i128, r.hi) - 1);
                        return if (range) |within| .{ .fixnum = within } else .unknown;
                    },
                    .single_float => {
                        const args = try self.converter.arena.alloc(*Node, 2);
                        args[0] = prim.args[0];
                        args[1] = try self.converter.node(.{ .constant = Value.fromSingleFloat(1) });
                        prim.args = args;
                        prim.op = if (is_inc) .add_single_floats else .sub_single_floats;
                        return .single_float;
                    },
                    .unknown => return .unknown,
                }
            },
            .less, .greater, .less_equal, .greater_equal, .num_equal => {
                if (bothFixnums(types) != null) {
                    prim.op = switch (prim.op) {
                        .less => .less_fixnums,
                        .greater => .greater_fixnums,
                        .less_equal => .less_equal_fixnums,
                        .greater_equal => .greater_equal_fixnums,
                        else => .num_equal_fixnums,
                    };
                } else if (try self.singleFloatOperands(prim.args, types)) {
                    prim.op = switch (prim.op) {
                        .less => .less_single_floats,
                        .greater => .greater_single_floats,
                        .less_equal => .less_equal_single_floats,
                        .greater_equal => .greater_equal_single_floats,
                        else => .num_equal_single_floats,
                    };
                }
                return .unknown;
            },
            else => return .unknown,
        }
    }

    fn bothFixnums(types: [2]Type) ?[2]Range {
        if (types[0] != .fixnum or types[1] != .fixnum) return null;
        return .{ types[0].fixnum, types[1].fixnum };
    }

    /// Whether both arguments are single-floats, once an integer constant
    /// whose float is exact is put in place of that float. Contagion
    /// makes the result the same.
    fn singleFloatOperands(self: *Inferrer, args: []*Node, types: [2]Type) Error!bool {
        _ = self;
        if (types[0] != .single_float and types[1] != .single_float) return false;
        for (args, 0..) |arg, i| {
            if (types[i] == .single_float) continue;
            if (!exactSingleFloatConstant(arg)) return false;
        }
        for (args, 0..) |arg, i| {
            if (types[i] != .single_float) arg.* = .{ .constant = Value.fromSingleFloat(@floatFromInt(arg.constant.toFixnum())) };
        }
        return true;
    }

    fn exactSingleFloatConstant(n: *const Node) bool {
        if (n.* != .constant or !n.constant.isFixnum()) return false;
        const k = n.constant.toFixnum();
        return k >= -EXACT_SINGLE_FLOAT_INTEGER and k <= EXACT_SINGLE_FLOAT_INTEGER;
    }

    fn productRange(a: Range, b: Range) ?Range {
        const corners = [_]i128{
            @as(i128, a.lo) * b.lo, @as(i128, a.lo) * b.hi,
            @as(i128, a.hi) * b.lo, @as(i128, a.hi) * b.hi,
        };
        var lo = corners[0];
        var hi = corners[0];
        for (corners[1..]) |c| {
            lo = @min(lo, c);
            hi = @max(hi, c);
        }
        return Range.of(lo, hi);
    }
};
