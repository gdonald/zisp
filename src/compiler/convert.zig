//! The first pass: a form, fully macroexpanded, as a tree whose variables
//! are resolved. Everything the second pass has to decide before it
//! emits a binding is settled here: which variables a closure captures
//! and which are assigned, and which `block`s and `tagbody`s are left
//! by a non-local exit.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const eval_mod = @import("../eval/eval.zig");
const function = @import("../eval/function.zig");
const env_mod = @import("../eval/env.zig");
const lambda_list = @import("../eval/lambda_list.zig");
const quasiquote = @import("../eval/quasiquote.zig");
const special_forms = @import("../eval/special_forms.zig");
const bytecode = @import("bytecode.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
pub const Error = eval_mod.Error;
const Op = bytecode.Op;

pub const Var = struct {
    /// The symbol it was bound for, or raw 0 for one the compiler made.
    sym: Value,
    owner: *Lambda,
    captured: bool = false,
    assigned: bool = false,
    slot: u32 = 0,
    /// The type it was declared with, or raw 0.
    declared: Value = .{ .raw = 0 },
    /// Whether what is bound or assigned to it is checked against the
    /// declared type.
    check: bool = false,
    /// Whether the declared type holds only fixnums.
    fixnum: bool = false,

    /// A variable a closure captures and that is assigned lives in a
    /// cell, so every closure over the binding sees one value.
    pub fn boxed(self: *const Var) bool {
        return self.captured and self.assigned;
    }
};

pub const Target = union(enum) {
    lexical: *Var,
    special: Value,
};

pub const Binding = struct { target: Target, init: *Node };
pub const Optional = struct { target: Target, init: *Node, supplied: ?Target };
pub const Key = struct { keyword: Value, target: Target, init: *Node, supplied: ?Target };

pub const Lambda = struct {
    parent: ?*Lambda,
    name: ?[]const u8,
    required: []Target = &.{},
    optional: []Optional = &.{},
    rest: ?Target = null,
    has_key: bool = false,
    keys: []Key = &.{},
    allow_other_keys: bool = false,
    aux: []Binding = &.{},
    body: *Node = undefined,
    policy: eval_mod.Policy = .{},
    /// The variables of enclosing functions this one reads, directly or
    /// through a function inside it, in the order its closure holds them.
    captures: std.ArrayListUnmanaged(*Var) = .empty,

    fn captureIndex(self: *const Lambda, v: *const Var) ?u32 {
        for (self.captures.items, 0..) |held, i| {
            if (held == v) return @intCast(i);
        }
        return null;
    }

    pub fn closedIndex(self: *const Lambda, v: *const Var) u32 {
        return self.captureIndex(v).?;
    }
};

pub const Block = struct {
    name: Value,
    owner: *Lambda,
    body: *Node = undefined,
    /// Some exit reaches it from another function or through an
    /// `unwind-protect`, so it is established at run time.
    dynamic: bool = false,
    /// Some local exit crosses something that changes the stack depth
    /// or the dynamic state, so its entry records both.
    needs_state: bool = false,
    id_var: ?*Var = null,
};

pub const Item = union(enum) {
    tag: u32,
    form: *Node,
};

pub const Tagbody = struct {
    owner: *Lambda,
    items: []Item = &.{},
    tag_count: u32 = 0,
    dynamic: bool = false,
    needs_state: bool = false,
    id_var: ?*Var = null,
};

pub const Exit = enum { local, dynamic };

pub const PatternTarget = union(enum) {
    target: Target,
    nested: *Pattern,
    /// An empty list in the pattern, which matches only NIL.
    empty,
};

pub const PatternOptional = struct { target: PatternTarget, init: *Node, supplied: ?Target };
pub const PatternKey = struct { keyword: Value, target: PatternTarget, init: *Node, supplied: ?Target };

pub const Pattern = struct {
    whole: ?PatternTarget = null,
    required: []PatternTarget = &.{},
    optional: []PatternOptional = &.{},
    rest: ?PatternTarget = null,
    has_key: bool = false,
    keys: []PatternKey = &.{},
    allow_other_keys: bool = false,
    aux: []Binding = &.{},
};

pub const Node = union(enum) {
    constant: Value,
    local_ref: *Var,
    local_set: struct { v: *Var, value: *Node },
    global_ref: Value,
    global_set: struct { sym: Value, value: *Node },
    function_ref: Value,
    /// `form` is the call as it was written, where a source position
    /// can be found for it, or raw 0.
    call_global: struct { sym: Value, args: []*Node, form: Value = .{ .raw = 0 } },
    call: struct { callee: *Node, args: []*Node, form: Value = .{ .raw = 0 } },
    apply: struct { callee: *Node, args: []*Node },
    primitive: struct { op: Op, args: []*Node },
    if_: struct { test_form: *Node, then: *Node, otherwise: *Node },
    progn: []*Node,
    let: struct { sequential: bool, bindings: []Binding, body: *Node },
    lambda: *Lambda,
    local_functions: struct { recursive: bool, vars: []*Var, lambdas: []*Lambda, body: *Node },
    block: *Block,
    return_from: struct { block: *Block, value: *Node, exit: Exit },
    tagbody: *Tagbody,
    go: struct { tagbody: *Tagbody, index: u32, exit: Exit },
    catch_: struct { tag: *Node, body: *Node },
    throw: struct { tag: *Node, value: *Node },
    unwind_protect: struct { protected: *Node, cleanup: *Node },
    errors: struct { kind: bytecode.ErrorsKind, body: *Node },
    values: []*Node,
    values_list: *Node,
    mv_list: *Node,
    mv_call: struct { callee: *Node, args: []*Node },
    mv_prog1: struct { first: *Node, rest: *Node },
    mv_bind: struct { targets: []Target, form: *Node, body: *Node },
    progv: struct { symbols: *Node, values: *Node, body: *Node },
    destructure: struct { pattern: *Pattern, value: *Node, body: *Node },
    interpret: Value,
    the_: struct { spec: Value, form: *Node, check: bool },
    /// `expansion` is what calls to the function can be expanded into
    /// where it is declared inline, or raw 0.
    define_function: struct { sym: Value, lambda: *Lambda, result: Value, expansion: Value },
    define_variable: struct { kind: DefineKind, sym: Value, init: ?*Node },
};

pub const DefineKind = enum(u32) { defvar = 0, defparameter = 1, defconstant = 2 };

pub const TypeDecl = struct { sym: Value, spec: Value };
const InlineDecl = struct { sym: Value, inline_: bool };

/// What the `declare` forms at the head of a body say.
pub const Decls = struct {
    specials: []const Value = &.{},
    types: []const TypeDecl = &.{},
    optimize: []const Value = &.{},
    inlines: []const InlineDecl = &.{},

    fn isSpecial(self: *const Decls, sym: Value) bool {
        for (self.specials) |s| if (s.equalsRaw(sym)) return true;
        return false;
    }

    fn typeOf(self: *const Decls, sym: Value) ?Value {
        for (self.types) |t| if (t.sym.equalsRaw(sym)) return t.spec;
        return null;
    }
};

/// Whether every object of type `spec` is a fixnum.
pub fn fixnumType(spec: Value) bool {
    if (spec.isSymbol()) {
        const name = symbol_mod.symbol(spec).name;
        return std.mem.eql(u8, name, "FIXNUM") or std.mem.eql(u8, name, "BIT");
    }
    if (!spec.isCons() or !heap.car(spec).isSymbol()) return false;
    const head = symbol_mod.symbol(heap.car(spec)).name;
    const args = heap.cdr(spec);
    if (!args.isCons()) return false;
    const first = heap.car(args);
    if (std.mem.eql(u8, head, "INTEGER")) {
        const after = heap.cdr(args);
        if (!after.isCons()) return false;
        return first.isFixnum() and heap.car(after).isFixnum();
    }
    if (!first.isFixnum()) return false;
    const n = first.toFixnum();
    if (std.mem.eql(u8, head, "SIGNED-BYTE")) return n >= 1 and n <= 61;
    if (std.mem.eql(u8, head, "UNSIGNED-BYTE")) return n >= 1 and n <= 60;
    if (std.mem.eql(u8, head, "MOD")) return n >= 1 and n - 1 <= value.FIXNUM_MAX;
    return false;
}

const VarEntry = struct {
    sym: Value,
    kind: union(enum) { lexical: *Var, special },
};

/// A local function, or a local macro that hides any function of the
/// same name further out.
const FunctionEntry = struct { sym: Value, v: ?*Var };

const BlockEntry = struct { name: Value, block: *Block };
const TagEntry = struct { tag: Value, tagbody: *Tagbody, index: u32 };

/// What lies between an exit and its target.
const Control = union(enum) {
    lambda: *Lambda,
    block: *Block,
    tagbody: *Tagbody,
    cleanup,
    state,
    unknown_depth,
};

const Primitive = struct { name: []const u8, op: Op, arity: u32 };

const primitives = [_]Primitive{
    .{ .name = "+", .op = .add, .arity = 2 },
    .{ .name = "-", .op = .sub, .arity = 2 },
    .{ .name = "<", .op = .less, .arity = 2 },
    .{ .name = ">", .op = .greater, .arity = 2 },
    .{ .name = "<=", .op = .less_equal, .arity = 2 },
    .{ .name = ">=", .op = .greater_equal, .arity = 2 },
    .{ .name = "=", .op = .num_equal, .arity = 2 },
    .{ .name = "1+", .op = .inc, .arity = 1 },
    .{ .name = "1-", .op = .dec, .arity = 1 },
    .{ .name = "EQ", .op = .eq, .arity = 2 },
    .{ .name = "CONS", .op = .cons, .arity = 2 },
    .{ .name = "CAR", .op = .car, .arity = 1 },
    .{ .name = "CDR", .op = .cdr, .arity = 1 },
    .{ .name = "NOT", .op = .not, .arity = 1 },
    .{ .name = "NULL", .op = .not, .arity = 1 },
};

pub const Converter = struct {
    ev: *Evaluator,
    arena: std.mem.Allocator,
    lambda: *Lambda = undefined,
    vars: std.ArrayListUnmanaged(VarEntry) = .empty,
    functions: std.ArrayListUnmanaged(FunctionEntry) = .empty,
    blocks: std.ArrayListUnmanaged(BlockEntry) = .empty,
    tags: std.ArrayListUnmanaged(TagEntry) = .empty,
    control: std.ArrayListUnmanaged(Control) = .empty,
    /// What `optimize` declarations in scope say, over what is proclaimed.
    policy: eval_mod.Policy = .{},
    inline_decls: std.ArrayListUnmanaged(InlineDecl) = .empty,
    /// How deep the expansion of each inline function in progress goes,
    /// which is what ends a recursive one.
    inline_depth: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    primitive_syms: [primitives.len]Value = undefined,
    sym_lambda: Value = undefined,
    sym_function: Value = undefined,
    sym_setf: Value = undefined,
    sym_funcall: Value = undefined,
    sym_apply: Value = undefined,
    sym_quote: Value = undefined,
    sym_block: Value = undefined,
    sym_return_from: Value = undefined,
    sym_macroexpand_1: Value = undefined,
    sym_macroexpand: Value = undefined,

    pub fn init(ev: *Evaluator, arena: std.mem.Allocator) !Converter {
        var self: Converter = .{ .ev = ev, .arena = arena, .policy = ev.policy };
        for (primitives, 0..) |p, i| self.primitive_syms[i] = try ev.interner.intern(p.name);
        self.sym_lambda = try ev.interner.intern("LAMBDA");
        self.sym_function = try ev.interner.intern("FUNCTION");
        self.sym_setf = try ev.interner.intern("SETF");
        self.sym_funcall = try ev.interner.intern("FUNCALL");
        self.sym_apply = try ev.interner.intern("APPLY");
        self.sym_quote = try ev.interner.intern("QUOTE");
        self.sym_block = try ev.interner.intern("BLOCK");
        self.sym_return_from = try ev.interner.intern("RETURN-FROM");
        self.sym_macroexpand_1 = try ev.interner.intern("%MACROEXPAND-1");
        self.sym_macroexpand = try ev.interner.intern("%MACROEXPAND");
        return self;
    }

    fn node(self: *Converter, n: Node) !*Node {
        const made = try self.arena.create(Node);
        made.* = n;
        return made;
    }

    fn constant(self: *Converter, v: Value) !*Node {
        try self.ev.pin(v);
        return self.node(.{ .constant = v });
    }

    fn newVar(self: *Converter, sym: Value) !*Var {
        const v = try self.arena.create(Var);
        v.* = .{ .sym = sym, .owner = self.lambda };
        return v;
    }

    /// Keep a value the tree refers to alive until the code holding it
    /// is built. A macro's expansion is fresh structure nothing else
    /// holds.
    fn keep(self: *Converter, v: Value) !Value {
        try self.ev.pin(v);
        return v;
    }

    // --- the lambda the whole compilation starts from ---

    /// Convert `(lambda params . body)`, given as its params and body.
    pub fn convertLambda(
        self: *Converter,
        parent: ?*Lambda,
        name: ?[]const u8,
        params: Value,
        body: Value,
        block_name: ?Value,
    ) Error!*Lambda {
        try lambda_list.validate(self.ev, params, false);
        const l = try self.arena.create(Lambda);
        l.* = .{ .parent = parent, .name = name };
        const outer = if (parent == null) null else self.lambda;
        self.lambda = l;
        defer {
            if (outer) |o| self.lambda = o;
        }
        try self.control.append(self.arena, .{ .lambda = l });
        defer _ = self.control.pop();

        const split = try self.splitBody(body, true);
        const saved_decls = try self.enterDecls(&split.decls);
        defer self.leaveDecls(saved_decls);
        l.policy = self.policy;
        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();

        var required: std.ArrayListUnmanaged(Target) = .empty;
        var optional: std.ArrayListUnmanaged(Optional) = .empty;
        var keys: std.ArrayListUnmanaged(Key) = .empty;
        var aux: std.ArrayListUnmanaged(Binding) = .empty;
        const Section = enum { required, optional, rest, key, aux };
        var section: Section = .required;
        var rest = params;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const item = heap.car(rest);
            if (item.isSymbol()) {
                const n = symbol_mod.symbol(item).name;
                if (std.mem.eql(u8, n, "&OPTIONAL")) {
                    section = .optional;
                    continue;
                } else if (std.mem.eql(u8, n, "&REST")) {
                    section = .rest;
                    continue;
                } else if (std.mem.eql(u8, n, "&KEY")) {
                    section = .key;
                    l.has_key = true;
                    continue;
                } else if (std.mem.eql(u8, n, "&AUX")) {
                    section = .aux;
                    continue;
                } else if (std.mem.eql(u8, n, "&ALLOW-OTHER-KEYS")) {
                    l.allow_other_keys = true;
                    continue;
                }
            }
            switch (section) {
                .required => try required.append(self.arena, try self.bindTarget(item, &split.decls)),
                .optional => {
                    const spec = try parseInitSpec(item);
                    const init_node = try self.convert(spec.init);
                    const target = try self.bindTarget(spec.name, &split.decls);
                    const supplied = if (spec.supplied.equalsRaw(value.NIL)) null else try self.bindTarget(spec.supplied, &split.decls);
                    try optional.append(self.arena, .{ .target = target, .init = init_node, .supplied = supplied });
                },
                .rest => l.rest = try self.bindTarget(item, &split.decls),
                .key => {
                    var keyword: Value = undefined;
                    var var_name: Value = undefined;
                    var tail = value.NIL;
                    if (item.isSymbol()) {
                        var_name = item;
                        keyword = try self.ev.interner.internKeyword(symbol_mod.symbol(item).name);
                    } else {
                        const head = heap.car(item);
                        tail = heap.cdr(item);
                        if (head.isSymbol()) {
                            var_name = head;
                            keyword = try self.ev.interner.internKeyword(symbol_mod.symbol(head).name);
                        } else {
                            keyword = heap.car(head);
                            var_name = heap.car(heap.cdr(head));
                        }
                    }
                    const init_form = if (tail.isCons()) heap.car(tail) else value.NIL;
                    const supplied_name = if (tail.isCons() and heap.cdr(tail).isCons()) heap.car(heap.cdr(tail)) else value.NIL;
                    const init_node = try self.convert(init_form);
                    const target = try self.bindTarget(var_name, &split.decls);
                    const supplied = if (supplied_name.equalsRaw(value.NIL)) null else try self.bindTarget(supplied_name, &split.decls);
                    try keys.append(self.arena, .{ .keyword = keyword, .target = target, .init = init_node, .supplied = supplied });
                },
                .aux => {
                    const spec = try parseInitSpec(item);
                    const init_node = try self.convert(spec.init);
                    try aux.append(self.arena, .{ .target = try self.bindTarget(spec.name, &split.decls), .init = init_node });
                },
            }
        }
        l.required = required.items;
        l.optional = optional.items;
        l.keys = keys.items;
        l.aux = aux.items;
        try self.declareFreeSpecials(&split.decls);

        if (block_name) |b| {
            l.body = try self.convertBlockBody(b, split.forms);
        } else {
            l.body = try self.convertBody(split.forms);
        }
        return l;
    }

    const InitSpec = struct { name: Value, init: Value, supplied: Value };

    fn parseInitSpec(item: Value) Error!InitSpec {
        if (item.isSymbol()) return .{ .name = item, .init = value.NIL, .supplied = value.NIL };
        if (!item.isCons()) return Error.BadArgList;
        const tail = heap.cdr(item);
        return .{
            .name = heap.car(item),
            .init = if (tail.isCons()) heap.car(tail) else value.NIL,
            .supplied = if (tail.isCons() and heap.cdr(tail).isCons()) heap.car(heap.cdr(tail)) else value.NIL,
        };
    }

    // --- bodies and declarations ---

    const Split = struct { forms: Value, decls: Decls };

    /// Take the docstring and `declare` forms off the front of a body,
    /// and collect what they declare.
    fn splitBody(self: *Converter, body: Value, allow_doc: bool) Error!Split {
        var specials: std.ArrayListUnmanaged(Value) = .empty;
        var types: std.ArrayListUnmanaged(TypeDecl) = .empty;
        var optimize: std.ArrayListUnmanaged(Value) = .empty;
        var inlines: std.ArrayListUnmanaged(InlineDecl) = .empty;
        var rest = body;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const form = heap.car(rest);
            if (allow_doc and heap.isString(form) and heap.cdr(rest).isCons()) continue;
            if (!form.isCons() or !heap.car(form).equalsRaw(self.ev.sym_declare)) break;
            var specs = heap.cdr(form);
            while (specs.isCons()) : (specs = heap.cdr(specs)) {
                const spec = heap.car(specs);
                if (!spec.isCons() or !heap.car(spec).isSymbol()) continue;
                const kind = symbol_mod.symbol(heap.car(spec)).name;
                var names = heap.cdr(spec);
                if (std.mem.eql(u8, kind, "SPECIAL")) {
                    while (names.isCons()) : (names = heap.cdr(names)) {
                        if (heap.car(names).isSymbol()) try specials.append(self.arena, heap.car(names));
                    }
                } else if (std.mem.eql(u8, kind, "OPTIMIZE")) {
                    while (names.isCons()) : (names = heap.cdr(names)) try optimize.append(self.arena, heap.car(names));
                } else if (std.mem.eql(u8, kind, "INLINE") or std.mem.eql(u8, kind, "NOTINLINE")) {
                    while (names.isCons()) : (names = heap.cdr(names)) {
                        const sym = self.ev.functionNameSymbol(heap.car(names)) catch continue;
                        try inlines.append(self.arena, .{ .sym = sym, .inline_ = kind[0] == 'I' });
                    }
                } else if (std.mem.eql(u8, kind, "TYPE")) {
                    if (!names.isCons()) continue;
                    const type_spec = heap.car(names);
                    names = heap.cdr(names);
                    while (names.isCons()) : (names = heap.cdr(names)) {
                        if (heap.car(names).isSymbol()) try types.append(self.arena, .{ .sym = heap.car(names), .spec = type_spec });
                    }
                } else if (std.mem.eql(u8, kind, "FIXNUM")) {
                    while (names.isCons()) : (names = heap.cdr(names)) {
                        if (heap.car(names).isSymbol()) try types.append(self.arena, .{ .sym = heap.car(names), .spec = heap.car(spec) });
                    }
                }
            }
        }
        return .{ .forms = rest, .decls = .{
            .specials = specials.items,
            .types = types.items,
            .optimize = optimize.items,
            .inlines = inlines.items,
        } };
    }

    const SavedDecls = struct { policy: eval_mod.Policy, inlines: usize };

    /// Put the optimize and inline declarations of a body in effect.
    fn enterDecls(self: *Converter, decls: *const Decls) Error!SavedDecls {
        const saved: SavedDecls = .{ .policy = self.policy, .inlines = self.inline_decls.items.len };
        for (decls.optimize) |entry| special_forms.applyOptimize(&self.policy, entry) catch {};
        try self.inline_decls.appendSlice(self.arena, decls.inlines);
        return saved;
    }

    fn leaveDecls(self: *Converter, saved: SavedDecls) void {
        self.policy = saved.policy;
        self.inline_decls.shrinkRetainingCapacity(saved.inlines);
    }

    fn convertDeclaredBody(self: *Converter, split: *const Split) Error!*Node {
        const saved = try self.enterDecls(&split.decls);
        defer self.leaveDecls(saved);
        return self.convertBody(split.forms);
    }

    /// Bind `sym` in the scope being built: dynamically when it is
    /// special, and as a fresh variable of the current function
    /// otherwise.
    fn bindTarget(self: *Converter, sym: Value, decls: *const Decls) Error!Target {
        if (!sym.isSymbol()) return Error.TypeError;
        try self.ev.env.top_value.?.bind(self.ev.env.frameAllocator(), sym, value.NIL);
        if (symbol_mod.symbol(sym).special or decls.isSpecial(sym)) {
            try self.vars.append(self.arena, .{ .sym = sym, .kind = .special });
            return .{ .special = sym };
        }
        const v = try self.newVar(sym);
        if (decls.typeOf(sym)) |spec| {
            v.declared = try self.keep(spec);
            v.fixnum = fixnumType(spec);
            v.check = self.policy.safety >= 1;
        }
        try self.vars.append(self.arena, .{ .sym = sym, .kind = .{ .lexical = v } });
        return .{ .lexical = v };
    }

    /// The names declared special that the binding form did not bind,
    /// which the body reads as special variables.
    fn declareFreeSpecials(self: *Converter, decls: *const Decls) Error!void {
        const frame = self.ev.env.top_value.?;
        for (decls.specials) |sym| {
            var bound = false;
            var i = self.vars.items.len;
            while (i > 0) {
                i -= 1;
                if (self.vars.items[i].sym.equalsRaw(sym) and self.vars.items[i].kind == .special) {
                    bound = true;
                    break;
                }
            }
            if (bound and frame.find(sym) != null) continue;
            try self.vars.append(self.arena, .{ .sym = sym, .kind = .special });
            if (frame.find(sym) == null) try frame.bind(self.ev.env.frameAllocator(), sym, value.SPECIAL_DYNAMIC);
        }
    }

    fn convertBody(self: *Converter, forms: Value) Error!*Node {
        var nodes: std.ArrayListUnmanaged(*Node) = .empty;
        var rest = forms;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            try nodes.append(self.arena, try self.convert(heap.car(rest)));
        }
        if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
        if (nodes.items.len == 1) return nodes.items[0];
        return self.node(.{ .progn = nodes.items });
    }

    fn convertBlockBody(self: *Converter, name: Value, forms: Value) Error!*Node {
        const b = try self.arena.create(Block);
        b.* = .{ .name = name, .owner = self.lambda };
        try self.blocks.append(self.arena, .{ .name = name, .block = b });
        defer _ = self.blocks.pop();
        try self.control.append(self.arena, .{ .block = b });
        defer _ = self.control.pop();
        b.body = try self.convertBody(forms);
        return self.node(.{ .block = b });
    }

    // --- forms ---

    pub fn convert(self: *Converter, form: Value) Error!*Node {
        if (form.isSymbol()) return self.convertSymbol(form);
        if (!form.isCons()) return self.constant(form);
        const head = heap.car(form);
        const args = heap.cdr(form);
        if (head.isSymbol()) {
            if (self.ev.lookupSpecialForm(head) != null) return self.convertSpecial(form, head, args);
            if (self.localFunction(head)) |entry| {
                if (entry.v) |v| return self.convertLocalCall(v, args, form);
            }
            if (try self.ev.macro_expander(self.ev, form)) |expansion| {
                return self.convert(try self.keep(expansion));
            }
            return self.convertGlobalCall(head, args, form);
        }
        if (head.isCons() and heap.car(head).equalsRaw(self.sym_lambda)) {
            const callee = try self.convertFunctionLambda(heap.cdr(head), null);
            return self.node(.{ .call = .{ .callee = callee, .args = try self.convertArgs(args) } });
        }
        return self.node(.{ .interpret = try self.keep(form) });
    }

    fn convertSymbol(self: *Converter, sym: Value) Error!*Node {
        if (sym.equalsRaw(value.NIL) or sym.equalsRaw(value.T) or symbol_mod.isKeyword(sym, self.ev.interner)) {
            return self.constant(sym);
        }
        if (try self.ev.macroexpand1(sym)) |expansion| return self.convert(try self.keep(expansion));
        if (self.lookupVar(sym)) |entry| switch (entry.kind) {
            .lexical => |v| {
                try self.noteReference(v);
                return self.node(.{ .local_ref = v });
            },
            .special => {},
        };
        return self.node(.{ .global_ref = sym });
    }

    fn lookupVar(self: *const Converter, sym: Value) ?VarEntry {
        var i = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (self.vars.items[i].sym.equalsRaw(sym)) return self.vars.items[i];
        }
        return null;
    }

    fn localFunction(self: *const Converter, sym: Value) ?FunctionEntry {
        var i = self.functions.items.len;
        while (i > 0) {
            i -= 1;
            if (self.functions.items[i].sym.equalsRaw(sym)) return self.functions.items[i];
        }
        return null;
    }

    /// A reference from inside a closure: every function between the
    /// reference and the variable's own carries it in its closure.
    fn noteReference(self: *Converter, v: *Var) Error!void {
        if (v.owner == self.lambda) return;
        v.captured = true;
        var l: ?*Lambda = self.lambda;
        while (l) |current| : (l = current.parent) {
            if (current == v.owner) break;
            if (current.captureIndex(v) == null) try current.captures.append(self.arena, v);
        }
    }

    fn convertArgs(self: *Converter, args: Value) Error![]*Node {
        var nodes: std.ArrayListUnmanaged(*Node) = .empty;
        var rest = args;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            try nodes.append(self.arena, try self.convert(heap.car(rest)));
        }
        if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
        return nodes.items;
    }

    fn convertLocalCall(self: *Converter, v: *Var, args: Value, form: Value) Error!*Node {
        try self.noteReference(v);
        const callee = try self.node(.{ .local_ref = v });
        return self.node(.{ .call = .{ .callee = callee, .args = try self.convertArgs(args), .form = form } });
    }

    fn convertGlobalCall(self: *Converter, head: Value, args: Value, form: Value) Error!*Node {
        if (self.inlineAllowed(head)) {
            if (symbol_mod.plistGet(head, try self.ev.interner.intern("%INLINE-EXPANSION"))) |expansion| {
                if (try self.inlineCall(head, expansion, args)) |expanded| return expanded;
            }
        }
        const nodes = try self.convertArgs(args);
        if (self.policy.speed >= 1) {
            for (primitives, 0..) |p, i| {
                if (head.equalsRaw(self.primitive_syms[i]) and nodes.len == p.arity) {
                    return self.node(.{ .primitive = .{ .op = typedOp(p.op, nodes), .args = nodes } });
                }
            }
        }
        if (head.equalsRaw(self.sym_funcall) and nodes.len >= 1) {
            return self.node(.{ .call = .{ .callee = nodes[0], .args = nodes[1..], .form = form } });
        }
        if (head.equalsRaw(self.sym_apply) and nodes.len >= 2) {
            return self.node(.{ .apply = .{ .callee = nodes[0], .args = nodes[1..] } });
        }
        return self.node(.{ .call_global = .{ .sym = head, .args = nodes, .form = form } });
    }

    /// Whether `n`'s value is known to be a fixnum.
    fn isFixnumNode(n: *const Node) bool {
        return switch (n.*) {
            .constant => |v| v.isFixnum(),
            .local_ref => |v| v.fixnum,
            .the_ => |t| fixnumType(t.spec),
            else => false,
        };
    }

    /// The instruction for a primitive whose arguments are all known to
    /// be fixnums, which needs no check on them.
    fn typedOp(op: Op, args: []*Node) Op {
        for (args) |arg| if (!isFixnumNode(arg)) return op;
        return switch (op) {
            .add => .add_fixnums,
            .sub => .sub_fixnums,
            .less => .less_fixnums,
            .greater => .greater_fixnums,
            .less_equal => .less_equal_fixnums,
            .greater_equal => .greater_equal_fixnums,
            .num_equal => .num_equal_fixnums,
            .inc => .inc_fixnum,
            .dec => .dec_fixnum,
            else => op,
        };
    }

    /// Whether a call to the global function `sym` is expanded in place:
    /// it is declared inline, and the policy puts speed ahead of space.
    fn inlineAllowed(self: *Converter, sym: Value) bool {
        if (self.policy.speed == 0) return false;
        if (self.policy.space > self.policy.speed and self.policy.speed < 3) return false;
        var i = self.inline_decls.items.len;
        while (i > 0) {
            i -= 1;
            if (self.inline_decls.items[i].sym.equalsRaw(sym)) return self.inline_decls.items[i].inline_;
        }
        const key = self.ev.interner.intern("%INLINE") catch return false;
        const status = symbol_mod.plistGet(sym, key) orelse return false;
        return status.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(status).name, "INLINE");
    }

    /// The calls an inline function's expansion is expanded within one
    /// another before a call is made instead.
    const INLINE_DEPTH = 3;

    /// `(sym . args)` with `sym`'s inline expansion in place of the call:
    /// a binding of its parameters to the arguments around its body,
    /// which sees the global environment and nothing of the caller's.
    /// Null when the lambda list or the argument count is one this does
    /// not expand.
    fn inlineCall(self: *Converter, sym: Value, expansion: Value, args: Value) Error!?*Node {
        const depth = self.inline_depth.get(sym.raw) orelse 0;
        if (depth >= INLINE_DEPTH) return null;
        if (!expansion.isCons() or !heap.cdr(expansion).isCons()) return null;
        const params = heap.car(heap.cdr(expansion));
        const body = heap.cdr(heap.cdr(expansion));

        var required: std.ArrayListUnmanaged(Value) = .empty;
        var optional: std.ArrayListUnmanaged(InitSpec) = .empty;
        var rest_name: ?Value = null;
        var section: enum { required, optional, rest, done } = .required;
        var cursor = params;
        while (cursor.isCons()) : (cursor = heap.cdr(cursor)) {
            const item = heap.car(cursor);
            if (item.isSymbol() and symbol_mod.symbol(item).name.len > 0 and symbol_mod.symbol(item).name[0] == '&') {
                const n = symbol_mod.symbol(item).name;
                if (std.mem.eql(u8, n, "&OPTIONAL") and section == .required) {
                    section = .optional;
                } else if (std.mem.eql(u8, n, "&REST") and section != .rest and section != .done) {
                    section = .rest;
                } else return null;
                continue;
            }
            switch (section) {
                .required => {
                    if (!item.isSymbol()) return null;
                    try required.append(self.arena, item);
                },
                .optional => {
                    const spec = try parseInitSpec(item);
                    if (!spec.name.isSymbol() or !spec.supplied.equalsRaw(value.NIL)) return null;
                    try optional.append(self.arena, spec);
                },
                .rest => {
                    if (!item.isSymbol()) return null;
                    rest_name = item;
                    section = .done;
                },
                .done => return null,
            }
        }
        if (!cursor.equalsRaw(value.NIL) or section == .rest) return null;

        var count: usize = 0;
        var walk = args;
        while (walk.isCons()) : (walk = heap.cdr(walk)) count += 1;
        if (count < required.items.len) return null;
        if (rest_name == null and count > required.items.len + optional.items.len) return null;
        const arg_nodes = try self.convertArgs(args);

        // The expansion is converted where only the global environment
        // is visible.
        const saved_vars = self.vars;
        const saved_functions = self.functions;
        const saved_blocks = self.blocks;
        const saved_tags = self.tags;
        const saved_inlines = self.inline_decls;
        self.vars = .empty;
        self.functions = .empty;
        self.blocks = .empty;
        self.tags = .empty;
        self.inline_decls = .empty;
        defer {
            self.vars = saved_vars;
            self.functions = saved_functions;
            self.blocks = saved_blocks;
            self.tags = saved_tags;
            self.inline_decls = saved_inlines;
        }
        const chains = try self.ev.env.saveChains();
        defer self.ev.env.restoreChains(chains);
        self.ev.env.top_value = null;
        self.ev.env.top_function = null;
        try self.inline_depth.put(self.arena, sym.raw, depth + 1);
        defer self.inline_depth.put(self.arena, sym.raw, depth) catch {};

        const split = try self.splitBody(body, true);
        const saved_decls = try self.enterDecls(&split.decls);
        defer self.leaveDecls(saved_decls);
        const control_mark = self.control.items.len;
        defer self.control.shrinkRetainingCapacity(control_mark);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();

        // What the call passed is bound all at once, the way a call
        // binds it; a defaulted optional parameter then sees the ones
        // before it.
        const supplied_optionals = @min(optional.items.len, count - required.items.len);
        var passed: std.ArrayListUnmanaged(Binding) = .empty;
        var stateful = false;
        for (required.items, 0..) |name, i| {
            const target = try self.bindTarget(name, &split.decls);
            if (target == .special) stateful = true;
            try passed.append(self.arena, .{ .target = target, .init = arg_nodes[i] });
        }
        for (optional.items[0..supplied_optionals], 0..) |spec, i| {
            const target = try self.bindTarget(spec.name, &split.decls);
            if (target == .special) stateful = true;
            try passed.append(self.arena, .{ .target = target, .init = arg_nodes[required.items.len + i] });
        }
        if (rest_name) |name| {
            const extra = arg_nodes[required.items.len + supplied_optionals ..];
            const list_node = try self.node(.{ .call_global = .{ .sym = try self.ev.interner.intern("LIST"), .args = extra } });
            const target = try self.bindTarget(name, &split.decls);
            if (target == .special) stateful = true;
            try passed.append(self.arena, .{ .target = target, .init = list_node });
        }
        if (stateful) try self.control.append(self.arena, .state);
        var defaulted: std.ArrayListUnmanaged(Binding) = .empty;
        for (optional.items[supplied_optionals..]) |spec| {
            const init_node = try self.convert(spec.init);
            const target = try self.bindTarget(spec.name, &split.decls);
            if (target == .special and !stateful) {
                stateful = true;
                try self.control.append(self.arena, .state);
            }
            try defaulted.append(self.arena, .{ .target = target, .init = init_node });
        }
        try self.declareFreeSpecials(&split.decls);
        var inner = try self.convertBody(split.forms);
        if (defaulted.items.len > 0) {
            inner = try self.node(.{ .let = .{ .sequential = true, .bindings = defaulted.items, .body = inner } });
        }
        return try self.node(.{ .let = .{ .sequential = false, .bindings = passed.items, .body = inner } });
    }

    fn convertSpecial(self: *Converter, form: Value, head: Value, args: Value) Error!*Node {
        const name = symbol_mod.symbol(head).name;
        const eql = std.mem.eql;
        if (eql(u8, name, "QUOTE")) return self.constant(try oneArg(args));
        if (eql(u8, name, "IF")) return self.convertIf(args);
        if (eql(u8, name, "PROGN")) return self.convertBody(args);
        if (eql(u8, name, "SETQ")) return self.convertSetq(args);
        if (eql(u8, name, "LET")) return self.convertLet(args, false);
        if (eql(u8, name, "LET*")) return self.convertLet(args, true);
        if (eql(u8, name, "LAMBDA")) return self.convertFunctionLambda(args, null);
        if (eql(u8, name, "FUNCTION")) return self.convertFunction(try oneArg(args));
        if (eql(u8, name, "FLET")) return self.convertLocalFunctions(args, false);
        if (eql(u8, name, "LABELS")) return self.convertLocalFunctions(args, true);
        if (eql(u8, name, "MACROLET")) return self.convertMacrolet(args);
        if (eql(u8, name, "SYMBOL-MACROLET")) return self.convertSymbolMacrolet(args);
        if (eql(u8, name, "BLOCK")) return self.convertBlock(args);
        if (eql(u8, name, "RETURN-FROM")) return self.convertReturnFrom(args, form);
        if (eql(u8, name, "RETURN")) return self.convertReturnFrom(try self.ev.heap.allocCons(value.NIL, args), form);
        if (eql(u8, name, "TAGBODY")) return self.convertTagbody(args);
        if (eql(u8, name, "GO")) return self.convertGo(args, form);
        if (eql(u8, name, "CATCH")) return self.convertCatch(args);
        if (eql(u8, name, "THROW")) {
            const parts = try self.convertArgs(args);
            if (parts.len != 2) return Error.BadArgList;
            return self.node(.{ .throw = .{ .tag = parts[0], .value = parts[1] } });
        }
        if (eql(u8, name, "UNWIND-PROTECT")) return self.convertUnwindProtect(args);
        if (eql(u8, name, "%IGNORE-ERRORS")) return self.convertErrors(args, .ignore);
        if (eql(u8, name, "%CATCH-ERROR")) return self.convertErrors(args, .catch_error);
        if (eql(u8, name, "THE")) {
            if (!args.isCons() or !heap.cdr(args).isCons()) return Error.BadArgList;
            const spec = heap.car(args);
            const inner = try self.convert(heap.car(heap.cdr(args)));
            const values_type = spec.isCons() and heap.car(spec).isSymbol() and eql(u8, symbol_mod.symbol(heap.car(spec)).name, "VALUES");
            if (values_type or spec.equalsRaw(value.T)) return inner;
            return self.node(.{ .the_ = .{ .spec = try self.keep(spec), .form = inner, .check = self.policy.safety >= 1 } });
        }
        if (eql(u8, name, "PROGV")) return self.convertProgv(args);
        if (eql(u8, name, "LOAD-TIME-VALUE")) return self.convertLoadTimeValue(args);
        if (eql(u8, name, "DECLARE")) return self.constant(value.NIL);
        if (eql(u8, name, "VALUES")) return self.node(.{ .values = try self.convertArgs(args) });
        if (eql(u8, name, "VALUES-LIST")) return self.node(.{ .values_list = try self.convert(try oneArg(args)) });
        if (eql(u8, name, "MULTIPLE-VALUE-LIST")) return self.node(.{ .mv_list = try self.convert(try oneArg(args)) });
        if (eql(u8, name, "MULTIPLE-VALUE-CALL")) return self.convertMvCall(args);
        if (eql(u8, name, "MULTIPLE-VALUE-PROG1")) return self.convertMvProg1(args);
        if (eql(u8, name, "MULTIPLE-VALUE-BIND")) return self.convertMvBind(args);
        if (eql(u8, name, "EVAL-WHEN")) {
            if (!args.isCons()) return Error.BadArgList;
            const situations = try special_forms.parseSituations(self.ev, heap.car(args));
            if (situations.execute) return self.convertBody(heap.cdr(args));
            return self.constant(value.NIL);
        }
        if (eql(u8, name, "DEFUN")) return self.convertDefun(args);
        if (eql(u8, name, "DESTRUCTURING-BIND")) return self.convertDestructuringBind(args);
        if (eql(u8, name, "QUASIQUOTE")) {
            const expansion = try quasiquote.expand(self.ev, try oneArg(args));
            return self.convert(try self.keep(expansion));
        }
        if (eql(u8, name, "DEFVAR")) return self.convertDefine(args, .defvar);
        if (eql(u8, name, "DEFPARAMETER")) return self.convertDefine(args, .defparameter);
        if (eql(u8, name, "DEFCONSTANT")) return self.convertDefine(args, .defconstant);
        if (eql(u8, name, "DECLAIM")) {
            // A proclamation also governs how the rest of this
            // compilation binds the names it makes special.
            _ = try self.ev.eval(form);
            return self.node(.{ .interpret = try self.keep(form) });
        }
        if (eql(u8, name, "MACROEXPAND-1")) return self.convertMacroexpand(args, self.sym_macroexpand_1);
        if (eql(u8, name, "MACROEXPAND")) return self.convertMacroexpand(args, self.sym_macroexpand);
        return self.node(.{ .interpret = try self.keep(form) });
    }

    fn oneArg(args: Value) Error!Value {
        if (!args.isCons() or !heap.cdr(args).equalsRaw(value.NIL)) return Error.BadArgList;
        return heap.car(args);
    }

    fn convertIf(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons() or !heap.cdr(args).isCons()) return Error.BadArgList;
        const test_form = try self.convert(heap.car(args));
        const then = try self.convert(heap.car(heap.cdr(args)));
        const after = heap.cdr(heap.cdr(args));
        if (after.isCons() and !heap.cdr(after).equalsRaw(value.NIL)) return Error.BadArgList;
        const otherwise = if (after.isCons()) try self.convert(heap.car(after)) else try self.constant(value.NIL);
        return self.node(.{ .if_ = .{ .test_form = test_form, .then = then, .otherwise = otherwise } });
    }

    fn convertSetq(self: *Converter, args: Value) Error!*Node {
        var nodes: std.ArrayListUnmanaged(*Node) = .empty;
        var rest = args;
        while (rest.isCons()) {
            const sym = heap.car(rest);
            if (!sym.isSymbol()) return Error.TypeError;
            const after = heap.cdr(rest);
            if (!after.isCons()) return Error.BadArgList;
            const value_form = heap.car(after);
            rest = heap.cdr(after);
            if (try self.ev.macroexpand1(sym)) |expansion| {
                try self.ev.pin(expansion);
                const setf_form = try self.keep(try self.ev.heap.list(&.{ self.sym_setf, expansion, value_form }));
                try nodes.append(self.arena, try self.convert(setf_form));
                continue;
            }
            const v = try self.convert(value_form);
            if (self.lookupVar(sym)) |entry| switch (entry.kind) {
                .lexical => |target| {
                    target.assigned = true;
                    try self.noteReference(target);
                    try nodes.append(self.arena, try self.node(.{ .local_set = .{ .v = target, .value = v } }));
                    continue;
                },
                .special => {},
            };
            try nodes.append(self.arena, try self.node(.{ .global_set = .{ .sym = sym, .value = v } }));
        }
        if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
        if (nodes.items.len == 0) return self.constant(value.NIL);
        if (nodes.items.len == 1) return nodes.items[0];
        return self.node(.{ .progn = nodes.items });
    }

    const BindingSpec = struct { sym: Value, init: Value };

    fn parseBinding(entry: Value) Error!BindingSpec {
        if (entry.isSymbol()) return .{ .sym = entry, .init = value.NIL };
        if (!entry.isCons()) return Error.BadArgList;
        const sym = heap.car(entry);
        if (!sym.isSymbol()) return Error.TypeError;
        const tail = heap.cdr(entry);
        if (tail.equalsRaw(value.NIL)) return .{ .sym = sym, .init = value.NIL };
        if (!tail.isCons() or !heap.cdr(tail).equalsRaw(value.NIL)) return Error.BadArgList;
        return .{ .sym = sym, .init = heap.car(tail) };
    }

    fn convertLet(self: *Converter, args: Value, sequential: bool) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const split = try self.splitBody(heap.cdr(args), false);
        var bindings: std.ArrayListUnmanaged(Binding) = .empty;
        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        const control_mark = self.control.items.len;
        defer self.control.shrinkRetainingCapacity(control_mark);

        var specs: std.ArrayListUnmanaged(BindingSpec) = .empty;
        var rest = heap.car(args);
        while (rest.isCons()) : (rest = heap.cdr(rest)) try specs.append(self.arena, try parseBinding(heap.car(rest)));
        if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;

        if (sequential) {
            const saved_decls = try self.enterDecls(&split.decls);
            defer self.leaveDecls(saved_decls);
            _ = try self.ev.env.pushValueFrame();
            defer self.ev.env.popValueFrame();
            var stateful = false;
            for (specs.items) |spec| {
                const init_node = try self.convert(spec.init);
                const target = try self.bindTarget(spec.sym, &split.decls);
                if (target == .special and !stateful) {
                    stateful = true;
                    try self.control.append(self.arena, .state);
                }
                try bindings.append(self.arena, .{ .target = target, .init = init_node });
            }
            try self.declareFreeSpecials(&split.decls);
            const body = try self.convertBody(split.forms);
            return self.node(.{ .let = .{ .sequential = true, .bindings = bindings.items, .body = body } });
        }

        var inits: std.ArrayListUnmanaged(*Node) = .empty;
        for (specs.items) |spec| try inits.append(self.arena, try self.convert(spec.init));
        const saved_decls = try self.enterDecls(&split.decls);
        defer self.leaveDecls(saved_decls);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();
        var stateful = false;
        for (specs.items, inits.items) |spec, init_node| {
            const target = try self.bindTarget(spec.sym, &split.decls);
            if (target == .special) stateful = true;
            try bindings.append(self.arena, .{ .target = target, .init = init_node });
        }
        if (stateful) try self.control.append(self.arena, .state);
        try self.declareFreeSpecials(&split.decls);
        const body = try self.convertBody(split.forms);
        return self.node(.{ .let = .{ .sequential = false, .bindings = bindings.items, .body = body } });
    }

    fn convertFunctionLambda(self: *Converter, lambda_args: Value, name: ?[]const u8) Error!*Node {
        if (!lambda_args.isCons()) return Error.BadArgList;
        const l = try self.convertLambda(self.lambda, name, heap.car(lambda_args), heap.cdr(lambda_args), null);
        return self.node(.{ .lambda = l });
    }

    fn convertFunction(self: *Converter, arg: Value) Error!*Node {
        if (arg.isSymbol()) {
            if (self.localFunction(arg)) |entry| {
                if (entry.v) |v| {
                    try self.noteReference(v);
                    return self.node(.{ .local_ref = v });
                }
            }
            return self.node(.{ .function_ref = arg });
        }
        if (!arg.isCons()) return Error.TypeError;
        const head = heap.car(arg);
        if (head.equalsRaw(self.sym_lambda)) return self.convertFunctionLambda(heap.cdr(arg), null);
        if (head.equalsRaw(self.sym_setf)) {
            const sym = try self.ev.functionNameSymbol(arg);
            if (self.localFunction(sym)) |entry| {
                if (entry.v) |v| {
                    try self.noteReference(v);
                    return self.node(.{ .local_ref = v });
                }
            }
            return self.node(.{ .function_ref = sym });
        }
        return Error.TypeError;
    }

    fn blockName(given: Value) Value {
        if (given.isCons()) return heap.car(heap.cdr(given));
        return given;
    }

    fn convertLocalFunctions(self: *Converter, args: Value, recursive: bool) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const definitions = heap.car(args);
        const split = try self.splitBody(heap.cdr(args), false);

        var names: std.ArrayListUnmanaged(Value) = .empty;
        var vars: std.ArrayListUnmanaged(*Var) = .empty;
        var rest = definitions;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const def = heap.car(rest);
            if (!def.isCons()) return Error.BadArgList;
            const sym = try self.ev.functionNameSymbol(heap.car(def));
            try names.append(self.arena, sym);
            const v = try self.newVar(sym);
            if (recursive) v.assigned = true;
            try vars.append(self.arena, v);
        }

        const function_mark = self.functions.items.len;
        defer self.functions.shrinkRetainingCapacity(function_mark);
        const frame = try self.ev.env.pushFunctionFrame();
        defer self.ev.env.popFunctionFrame();

        if (recursive) {
            for (names.items, vars.items) |sym, v| {
                try self.functions.append(self.arena, .{ .sym = sym, .v = v });
                try frame.bind(self.ev.env.frameAllocator(), sym, value.NIL);
            }
        }

        var lambdas: std.ArrayListUnmanaged(*Lambda) = .empty;
        {
            // FLET's definitions see the functions outside it, not each
            // other, so the frame holding them is set aside meanwhile.
            const saved = if (recursive) null else self.ev.env.setFunctionChain(frame.parent);
            defer if (!recursive) {
                _ = self.ev.env.setFunctionChain(saved);
            };
            rest = definitions;
            for (names.items) |sym| {
                const def = heap.car(rest);
                rest = heap.cdr(rest);
                const after_name = heap.cdr(def);
                if (!after_name.isCons()) return Error.BadArgList;
                const l = try self.convertLambda(
                    self.lambda,
                    symbol_mod.symbol(sym).name,
                    heap.car(after_name),
                    heap.cdr(after_name),
                    blockName(heap.car(def)),
                );
                try lambdas.append(self.arena, l);
            }
        }

        if (!recursive) {
            for (names.items, vars.items) |sym, v| {
                try self.functions.append(self.arena, .{ .sym = sym, .v = v });
                try frame.bind(self.ev.env.frameAllocator(), sym, value.NIL);
            }
        }

        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();
        try self.declareFreeSpecials(&split.decls);
        const body = try self.convertDeclaredBody(&split);
        return self.node(.{ .local_functions = .{
            .recursive = recursive,
            .vars = vars.items,
            .lambdas = lambdas.items,
            .body = body,
        } });
    }

    fn convertMacrolet(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const function_mark = self.functions.items.len;
        defer self.functions.shrinkRetainingCapacity(function_mark);
        const frame = try self.ev.env.pushFunctionFrame();
        defer self.ev.env.popFunctionFrame();
        const enclosing = frame.parent;

        var rest = heap.car(args);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const def = heap.car(rest);
            if (!def.isCons()) return Error.BadArgList;
            const name = heap.car(def);
            if (!name.isSymbol()) return Error.TypeError;
            const after_name = heap.cdr(def);
            if (!after_name.isCons()) return Error.BadArgList;
            const params = heap.car(after_name);
            try lambda_list.validate(self.ev, params, true);
            const body = try self.keep(try self.wrapBlock(name, heap.cdr(after_name)));
            try self.ev.env.retainChain(self.ev.env.top_value);
            try self.ev.env.retainChain(enclosing);
            const expander = try function.allocMacro(
                self.ev.heap.allocator,
                symbol_mod.symbol(name).name,
                params,
                body,
                self.ev.env.top_value,
                enclosing,
                null,
            );
            try frame.bind(self.ev.env.frameAllocator(), name, expander);
            try self.functions.append(self.arena, .{ .sym = name, .v = null });
        }
        const split = try self.splitBody(heap.cdr(args), false);
        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();
        try self.declareFreeSpecials(&split.decls);
        return self.convertDeclaredBody(&split);
    }

    /// A macro body inside the block its name calls for, with its
    /// docstring and declarations left in front.
    fn wrapBlock(self: *Converter, name: Value, body: Value) Error!Value {
        var held = self.ev.heap.protect();
        defer held.close();
        var prefix: usize = 0;
        var rest = body;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const form = heap.car(rest);
            const docstring = heap.isString(form) and heap.cdr(rest).isCons();
            const declaration = form.isCons() and heap.car(form).equalsRaw(self.ev.sym_declare);
            if (!docstring and !declaration) break;
            try held.push(form);
            prefix += 1;
        }
        try held.push(try self.ev.heap.allocCons(name, rest));
        try held.push(try self.ev.heap.allocCons(self.sym_block, held.items()[prefix]));
        try held.push(try self.ev.heap.allocCons(held.items()[prefix + 1], value.NIL));
        return self.ev.heap.listWithTail(held.items()[0..prefix], held.items()[prefix + 2]);
    }

    fn convertSymbolMacrolet(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        const frame = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();
        const marker_name = try self.ev.interner.intern(Evaluator.SYMBOL_MACRO_NAME);
        var rest = heap.car(args);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const def = heap.car(rest);
            if (!def.isCons()) return Error.BadArgList;
            const name = heap.car(def);
            if (!name.isSymbol()) return Error.TypeError;
            if (symbol_mod.symbol(name).special or symbol_mod.symbol(name).constant) return Error.ProgramError;
            const after = heap.cdr(def);
            if (!after.isCons() or !heap.cdr(after).equalsRaw(value.NIL)) return Error.BadArgList;
            const marker = try self.keep(try self.ev.heap.allocStructure(marker_name, &.{heap.car(after)}));
            try frame.bind(self.ev.env.frameAllocator(), name, marker);
            // A symbol macro hides a variable of the same name further
            // out, which is what an entry with no variable says.
            try self.vars.append(self.arena, .{ .sym = name, .kind = .special });
        }
        const split = try self.splitBody(heap.cdr(args), false);
        try self.declareFreeSpecials(&split.decls);
        return self.convertDeclaredBody(&split);
    }

    fn convertBlock(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const name = heap.car(args);
        if (!name.isSymbol()) return Error.TypeError;
        return self.convertBlockBody(name, heap.cdr(args));
    }

    const Crossing = struct { dynamic: bool, stateful: bool };

    /// What an exit from here to the scope `target` passes through.
    fn crossing(self: *const Converter, target: Control) Crossing {
        var result: Crossing = .{ .dynamic = false, .stateful = false };
        var i = self.control.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.control.items[i];
            switch (target) {
                .block => |b| if (scope == .block and scope.block == b) return result,
                .tagbody => |t| if (scope == .tagbody and scope.tagbody == t) return result,
                else => unreachable,
            }
            switch (scope) {
                .lambda, .cleanup => result.dynamic = true,
                .block, .tagbody, .state, .unknown_depth => result.stateful = true,
            }
        }
        return result;
    }

    fn idVar(self: *Converter, owner: *Lambda, slot: *?*Var) Error!*Var {
        if (slot.*) |v| return v;
        const v = try self.arena.create(Var);
        v.* = .{ .sym = .{ .raw = 0 }, .owner = owner };
        slot.* = v;
        return v;
    }

    fn convertReturnFrom(self: *Converter, args: Value, form: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const name = heap.car(args);
        if (!name.isSymbol()) return Error.TypeError;
        const after = heap.cdr(args);
        if (after.isCons() and !heap.cdr(after).equalsRaw(value.NIL)) return Error.BadArgList;
        var target: ?*Block = null;
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            if (self.blocks.items[i].name.equalsRaw(name)) {
                target = self.blocks.items[i].block;
                break;
            }
        }
        const b = target orelse return self.node(.{ .interpret = try self.keep(form) });
        const value_node = if (after.isCons()) try self.convert(heap.car(after)) else try self.constant(value.NIL);
        const passes = self.crossing(.{ .block = b });
        if (passes.dynamic) {
            b.dynamic = true;
            const v = try self.idVar(b.owner, &b.id_var);
            try self.noteReference(v);
            return self.node(.{ .return_from = .{ .block = b, .value = value_node, .exit = .dynamic } });
        }
        if (passes.stateful) b.needs_state = true;
        return self.node(.{ .return_from = .{ .block = b, .value = value_node, .exit = .local } });
    }

    fn convertTagbody(self: *Converter, args: Value) Error!*Node {
        const t = try self.arena.create(Tagbody);
        t.* = .{ .owner = self.lambda };
        const tag_mark = self.tags.items.len;
        defer self.tags.shrinkRetainingCapacity(tag_mark);
        var rest = args;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const item = heap.car(rest);
            if (item.isCons()) continue;
            try self.tags.append(self.arena, .{ .tag = item, .tagbody = t, .index = t.tag_count });
            t.tag_count += 1;
        }
        if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
        try self.control.append(self.arena, .{ .tagbody = t });
        defer _ = self.control.pop();

        var items: std.ArrayListUnmanaged(Item) = .empty;
        var index: u32 = 0;
        rest = args;
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const item = heap.car(rest);
            if (item.isCons()) {
                try items.append(self.arena, .{ .form = try self.convert(item) });
            } else {
                try items.append(self.arena, .{ .tag = index });
                index += 1;
            }
        }
        t.items = items.items;
        return self.node(.{ .tagbody = t });
    }

    fn convertGo(self: *Converter, args: Value, form: Value) Error!*Node {
        const tag = try oneArg(args);
        if (!tag.isSymbol() and !tag.isFixnum()) return Error.TypeError;
        var found: ?TagEntry = null;
        var i = self.tags.items.len;
        while (i > 0) {
            i -= 1;
            if (self.tags.items[i].tag.equalsRaw(tag)) {
                found = self.tags.items[i];
                break;
            }
        }
        const entry = found orelse return self.node(.{ .interpret = try self.keep(form) });
        const t = entry.tagbody;
        const passes = self.crossing(.{ .tagbody = t });
        if (passes.dynamic) {
            t.dynamic = true;
            const v = try self.idVar(t.owner, &t.id_var);
            try self.noteReference(v);
            return self.node(.{ .go = .{ .tagbody = t, .index = entry.index, .exit = .dynamic } });
        }
        if (passes.stateful) t.needs_state = true;
        return self.node(.{ .go = .{ .tagbody = t, .index = entry.index, .exit = .local } });
    }

    fn convertCatch(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const tag = try self.convert(heap.car(args));
        try self.control.append(self.arena, .state);
        defer _ = self.control.pop();
        const body = try self.convertBody(heap.cdr(args));
        return self.node(.{ .catch_ = .{ .tag = tag, .body = body } });
    }

    fn convertUnwindProtect(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        try self.control.append(self.arena, .cleanup);
        defer _ = self.control.pop();
        const protected = try self.convert(heap.car(args));
        const cleanup = try self.convertBody(heap.cdr(args));
        return self.node(.{ .unwind_protect = .{ .protected = protected, .cleanup = cleanup } });
    }

    fn convertErrors(self: *Converter, args: Value, kind: bytecode.ErrorsKind) Error!*Node {
        try self.control.append(self.arena, .state);
        defer _ = self.control.pop();
        const body = try self.convertBody(args);
        return self.node(.{ .errors = .{ .kind = kind, .body = body } });
    }

    fn convertProgv(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons() or !heap.cdr(args).isCons()) return Error.BadArgList;
        const symbols = try self.convert(heap.car(args));
        const values = try self.convert(heap.car(heap.cdr(args)));
        try self.control.append(self.arena, .state);
        defer _ = self.control.pop();
        const body = try self.convertBody(heap.cdr(heap.cdr(args)));
        return self.node(.{ .progv = .{ .symbols = symbols, .values = values, .body = body } });
    }

    fn convertLoadTimeValue(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const previous = try self.ev.enterEnvironment(value.NIL);
        defer self.ev.leaveEnvironment(previous);
        return self.constant(try self.ev.eval(heap.car(args)));
    }

    fn convertMvCall(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const callee = try self.convert(heap.car(args));
        try self.control.append(self.arena, .unknown_depth);
        defer _ = self.control.pop();
        const parts = try self.convertArgs(heap.cdr(args));
        return self.node(.{ .mv_call = .{ .callee = callee, .args = parts } });
    }

    fn convertMvProg1(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const first = try self.convert(heap.car(args));
        try self.control.append(self.arena, .unknown_depth);
        defer _ = self.control.pop();
        const rest = try self.convertBody(heap.cdr(args));
        return self.node(.{ .mv_prog1 = .{ .first = first, .rest = rest } });
    }

    fn convertMvBind(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons() or !heap.cdr(args).isCons()) return Error.BadArgList;
        const form = try self.convert(heap.car(heap.cdr(args)));
        const split = try self.splitBody(heap.cdr(heap.cdr(args)), false);
        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();
        var targets: std.ArrayListUnmanaged(Target) = .empty;
        var stateful = false;
        var rest = heap.car(args);
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const target = try self.bindTarget(heap.car(rest), &split.decls);
            if (target == .special) stateful = true;
            try targets.append(self.arena, target);
        }
        if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
        const control_mark = self.control.items.len;
        defer self.control.shrinkRetainingCapacity(control_mark);
        if (stateful) try self.control.append(self.arena, .state);
        try self.declareFreeSpecials(&split.decls);
        const body = try self.convertDeclaredBody(&split);
        return self.node(.{ .mv_bind = .{ .targets = targets.items, .form = form, .body = body } });
    }

    fn convertDefun(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const given = heap.car(args);
        const sym = try self.ev.functionNameSymbol(given);
        const after = heap.cdr(args);
        if (!after.isCons()) return Error.BadArgList;
        const l = try self.convertLambda(self.lambda, symbol_mod.symbol(sym).name, heap.car(after), heap.cdr(after), blockName(given));
        // A function proclaimed inline where it is defined keeps the
        // expansion its calls are expanded into, when nothing lexical
        // surrounds it for the expansion to lose.
        var expansion: Value = .{ .raw = 0 };
        const status = symbol_mod.plistGet(sym, try self.ev.interner.intern("%INLINE"));
        const proclaimed = if (status) |st| st.isSymbol() and std.mem.eql(u8, symbol_mod.symbol(st).name, "INLINE") else false;
        if (proclaimed and self.vars.items.len == 0 and self.functions.items.len == 0) {
            const wrapped = try self.keep(try self.wrapBlock(blockName(given), heap.cdr(after)));
            const with_params = try self.keep(try self.ev.heap.allocCons(heap.car(after), wrapped));
            expansion = try self.keep(try self.ev.heap.allocCons(self.sym_lambda, with_params));
            try symbol_mod.plistPut(self.ev.heap, sym, try self.ev.interner.intern("%INLINE-EXPANSION"), expansion);
        }
        return self.node(.{ .define_function = .{ .sym = sym, .lambda = l, .result = try self.keep(given), .expansion = expansion } });
    }

    fn convertDefine(self: *Converter, args: Value, kind: DefineKind) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const sym = heap.car(args);
        if (!sym.isSymbol()) return Error.TypeError;
        const rest = heap.cdr(args);
        if (kind != .defvar and !rest.isCons()) return Error.BadArgList;
        symbol_mod.symbol(sym).special = true;
        const init_node = if (rest.isCons()) try self.convert(heap.car(rest)) else null;
        return self.node(.{ .define_variable = .{ .kind = kind, .sym = sym, .init = init_node } });
    }

    /// `macroexpand` and `macroexpand-1` with no environment argument
    /// expand in the environment the call is compiled in, which outlives
    /// the compilation once its frames are kept.
    fn convertMacroexpand(self: *Converter, args: Value, native: Value) Error!*Node {
        if (!args.isCons()) return Error.BadArgList;
        const form = try self.convert(heap.car(args));
        const after = heap.cdr(args);
        const environment = if (after.isCons())
            try self.convert(heap.car(after))
        else blk: {
            try self.ev.env.retainChain(self.ev.env.top_value);
            try self.ev.env.retainChain(self.ev.env.top_function);
            break :blk try self.constant(try self.ev.captureEnvironment());
        };
        const parts = try self.arena.alloc(*Node, 2);
        parts[0] = form;
        parts[1] = environment;
        return self.node(.{ .call_global = .{ .sym = native, .args = parts } });
    }

    // --- destructuring-bind ---

    fn convertDestructuringBind(self: *Converter, args: Value) Error!*Node {
        if (!args.isCons() or !heap.cdr(args).isCons()) return Error.BadArgList;
        const pattern_form = heap.car(args);
        if (!pattern_form.isCons() and !pattern_form.equalsRaw(value.NIL)) return Error.BadArgList;
        try lambda_list.validate(self.ev, pattern_form, true);
        const value_node = try self.convert(heap.car(heap.cdr(args)));
        const split = try self.splitBody(heap.cdr(heap.cdr(args)), false);
        const var_mark = self.vars.items.len;
        defer self.vars.shrinkRetainingCapacity(var_mark);
        const control_mark = self.control.items.len;
        defer self.control.shrinkRetainingCapacity(control_mark);
        _ = try self.ev.env.pushValueFrame();
        defer self.ev.env.popValueFrame();
        var stateful = false;
        const pattern = try self.convertPattern(pattern_form, &split.decls, &stateful);
        try self.declareFreeSpecials(&split.decls);
        const body = try self.convertDeclaredBody(&split);
        return self.node(.{ .destructure = .{ .pattern = pattern, .value = value_node, .body = body } });
    }

    fn patternTarget(self: *Converter, item: Value, decls: *const Decls, stateful: *bool) Error!PatternTarget {
        if (item.equalsRaw(value.NIL)) return .empty;
        if (item.isCons()) return .{ .nested = try self.convertPattern(item, decls, stateful) };
        return .{ .target = try self.boundTarget(item, decls, stateful) };
    }

    fn boundTarget(self: *Converter, sym: Value, decls: *const Decls, stateful: *bool) Error!Target {
        const target = try self.bindTarget(sym, decls);
        if (target == .special and !stateful.*) {
            stateful.* = true;
            try self.control.append(self.arena, .state);
        }
        return target;
    }

    fn convertPattern(self: *Converter, params: Value, decls: *const Decls, stateful: *bool) Error!*Pattern {
        const p = try self.arena.create(Pattern);
        p.* = .{};
        var required: std.ArrayListUnmanaged(PatternTarget) = .empty;
        var optional: std.ArrayListUnmanaged(PatternOptional) = .empty;
        var keys: std.ArrayListUnmanaged(PatternKey) = .empty;
        var aux: std.ArrayListUnmanaged(Binding) = .empty;
        const Section = enum { required, optional, rest, key, aux };
        var section: Section = .required;
        var rest = params;
        if (rest.isCons() and heap.car(rest).isSymbol() and std.mem.eql(u8, symbol_mod.symbol(heap.car(rest)).name, "&WHOLE")) {
            p.whole = try self.patternTarget(heap.car(heap.cdr(rest)), decls, stateful);
            rest = heap.cdr(heap.cdr(rest));
        }
        while (rest.isCons()) : (rest = heap.cdr(rest)) {
            const item = heap.car(rest);
            if (item.isSymbol()) {
                const n = symbol_mod.symbol(item).name;
                if (std.mem.eql(u8, n, "&OPTIONAL")) {
                    section = .optional;
                    continue;
                } else if (std.mem.eql(u8, n, "&REST") or std.mem.eql(u8, n, "&BODY")) {
                    section = .rest;
                    continue;
                } else if (std.mem.eql(u8, n, "&KEY")) {
                    section = .key;
                    p.has_key = true;
                    continue;
                } else if (std.mem.eql(u8, n, "&AUX")) {
                    section = .aux;
                    continue;
                } else if (std.mem.eql(u8, n, "&ALLOW-OTHER-KEYS")) {
                    p.allow_other_keys = true;
                    continue;
                }
            }
            switch (section) {
                .required => try required.append(self.arena, try self.patternTarget(item, decls, stateful)),
                .optional => {
                    const spec = try parseInitSpec(item);
                    const init_node = try self.convert(spec.init);
                    const target = try self.patternTarget(spec.name, decls, stateful);
                    const supplied = if (spec.supplied.equalsRaw(value.NIL)) null else try self.boundTarget(spec.supplied, decls, stateful);
                    try optional.append(self.arena, .{ .target = target, .init = init_node, .supplied = supplied });
                },
                .rest => p.rest = try self.patternTarget(item, decls, stateful),
                .key => {
                    var keyword: Value = undefined;
                    var var_name: Value = undefined;
                    var tail = value.NIL;
                    if (item.isSymbol()) {
                        var_name = item;
                        keyword = try self.ev.interner.internKeyword(symbol_mod.symbol(item).name);
                    } else {
                        const head = heap.car(item);
                        tail = heap.cdr(item);
                        if (head.isSymbol()) {
                            var_name = head;
                            keyword = try self.ev.interner.internKeyword(symbol_mod.symbol(head).name);
                        } else {
                            keyword = heap.car(head);
                            var_name = heap.car(heap.cdr(head));
                        }
                    }
                    const init_form = if (tail.isCons()) heap.car(tail) else value.NIL;
                    const supplied_name = if (tail.isCons() and heap.cdr(tail).isCons()) heap.car(heap.cdr(tail)) else value.NIL;
                    const init_node = try self.convert(init_form);
                    const target = try self.patternTarget(var_name, decls, stateful);
                    const supplied = if (supplied_name.equalsRaw(value.NIL)) null else try self.boundTarget(supplied_name, decls, stateful);
                    try keys.append(self.arena, .{ .keyword = keyword, .target = target, .init = init_node, .supplied = supplied });
                },
                .aux => {
                    const spec = try parseInitSpec(item);
                    const init_node = try self.convert(spec.init);
                    try aux.append(self.arena, .{ .target = try self.boundTarget(spec.name, decls, stateful), .init = init_node });
                },
            }
        }
        if (!rest.equalsRaw(value.NIL)) p.rest = try self.patternTarget(rest, decls, stateful);
        p.required = required.items;
        p.optional = optional.items;
        p.keys = keys.items;
        p.aux = aux.items;
        return p;
    }
};
