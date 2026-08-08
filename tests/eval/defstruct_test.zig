//! `defstruct`: the generated constructor, accessors, setf expanders,
//! predicate and copier, the option set that renames or suppresses each of
//! them, and the structure primitives underneath.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    aw: std.Io.Writer.Allocating,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .aw = std.Io.Writer.Allocating.init(allocator),
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        fx.ev.out = &fx.aw.writer;
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
        self.aw.deinit();
        self.interner.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn evalStr(self: *Fixture, src: []const u8) !Value {
        var tk = zisp.reader.Tokenizer.init(src);
        var rd = zisp.reader.Reader.init(&tk, &self.heap, &self.interner);
        var result = value.NIL;
        while (try rd.read()) |form| {
            result = try self.ev.eval(form);
        }
        return result;
    }

    fn expectFix(self: *Fixture, src: []const u8, expected: i64) !void {
        try testing.expectEqual(expected, (try self.evalStr(src)).toFixnum());
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    /// Evaluate `src` and return what `format nil "~S"` prints for it.
    fn printed(self: *Fixture, src: []const u8) ![]const u8 {
        const v = try self.evalStr(src);
        return heap_mod.asString(v).constSlice();
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

const point = "(defstruct point x y)";

test "defstruct returns the structure name" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr(point);
    try testing.expectEqualStrings("POINT", symbol_mod.name(v));
}

test "the constructor takes one keyword per slot" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(point);
    try fx.expectFix("(point-x (make-point :x 3 :y 4))", 3);
    try fx.expectFix("(point-y (make-point :x 3 :y 4))", 4);
}

test "an omitted slot takes its initform, defaulting to nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(defstruct sized (width 10) height)");
    try fx.expectFix("(sized-width (make-sized))", 10);
    try fx.expectNil("(sized-height (make-sized))");
}

test "an initform is evaluated, not taken literally" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(defstruct computed (total (+ 2 3)))");
    try fx.expectFix("(computed-total (make-computed))", 5);
}

test "accessors are setf-able places" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(point);
    try fx.expectFix("(let ((p (make-point :x 1 :y 2))) (setf (point-y p) 9) (point-y p))", 9);
}

test "incf works through a structure accessor" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(point);
    try fx.expectFix("(let ((p (make-point :x 1 :y 2))) (incf (point-x p) 5) (point-x p))", 6);
}

test "the predicate accepts its own structures and rejects everything else" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(point);
    _ = try fx.evalStr("(defstruct other a)");
    try fx.expectT("(point-p (make-point))");
    try fx.expectNil("(point-p (make-other))");
    try fx.expectNil("(point-p 5)");
    try fx.expectNil("(point-p '(point 1 2))");
}

test "the copier produces an independent structure" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(point);
    try fx.expectFix(
        \\(let* ((p (make-point :x 1 :y 2)) (q (copy-point p)))
        \\  (setf (point-x q) 99)
        \\  (point-x p))
    , 1);
    try fx.expectFix("(point-y (copy-point (make-point :x 1 :y 2)))", 2);
}

test "typep recognizes the structure name and structure-object" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(point);
    _ = try fx.evalStr("(defstruct other a)");
    try fx.expectT("(typep (make-point) 'point)");
    try fx.expectNil("(typep (make-other) 'point)");
    try fx.expectT("(typep (make-point) 'structure-object)");
    try fx.expectNil("(typep 5 'structure-object)");
}

test "conc-name nil names accessors after the slots themselves" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(defstruct (entry (:conc-name nil)) pend name)");
    try fx.expectFix("(pend (make-entry :pend 7))", 7);
    try fx.expectFix("(let ((e (make-entry))) (setf (name e) 4) (name e))", 4);
}

test "an explicit conc-name replaces the default prefix" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(defstruct (node (:conc-name n/)) left)");
    try fx.expectFix("(n/left (make-node :left 2))", 2);
}

test "constructor predicate and copier can be renamed" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(
        \\(defstruct (cell (:constructor build-cell)
        \\                 (:predicate cellp)
        \\                 (:copier clone-cell))
        \\  slot)
    );
    try fx.expectT("(cellp (clone-cell (build-cell :slot 1)))");
    try fx.expectFix("(cell-slot (build-cell :slot 1))", 1);
}

test "constructor predicate and copier can be suppressed with nil" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr(
        \\(defstruct (quiet (:constructor nil) (:predicate nil) (:copier nil)) slot)
    );
    try testing.expectError(Error.UnboundFunction, fx.evalStr("(make-quiet)"));
    try testing.expectError(Error.UnboundFunction, fx.evalStr("(quiet-p 1)"));
    try testing.expectError(Error.UnboundFunction, fx.evalStr("(copy-quiet 1)"));
    // The accessor is still defined.
    try fx.expectNil("(quiet-slot (%make-structure 'quiet nil))");
}

test "an unsupported defstruct option is an error" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(Error.ProgramError, fx.evalStr("(defstruct (bad (:include point)) a)"));
    try testing.expectError(Error.ProgramError, fx.evalStr("(defstruct (bad (:type list)) a)"));
}

test "a slotless structure is legal" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    _ = try fx.evalStr("(defstruct empty)");
    try fx.expectT("(empty-p (make-empty))");
}

test "structures print with their slot names" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try zisp.builtins.registerSystem(&fx.ev);
    _ = try fx.evalStr(point);
    try testing.expectEqualStrings(
        "#S(POINT :X 1 :Y 2)",
        try fx.printed("(format nil \"~S\" (make-point :x 1 :y 2))"),
    );
}

test "a structure with no registered slot names still prints its values" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try zisp.builtins.registerSystem(&fx.ev);
    try testing.expectEqualStrings(
        "#S(RAW 1 2)",
        try fx.printed("(format nil \"~S\" (%make-structure 'raw 1 2))"),
    );
}

test "structure primitives reject non-structures" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(Error.TypeError, fx.evalStr("(%structure-name 5)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(%structure-ref 5 0)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(%set-structure-ref 5 0 1)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(%copy-structure 5)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(%make-structure \"not-a-symbol\")"));
}

test "structure slot access is bounds-checked" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(Error.TypeError, fx.evalStr("(%structure-ref (%make-structure 'r 1) 1)"));
    try testing.expectError(Error.TypeError, fx.evalStr("(%set-structure-ref (%make-structure 'r 1) 1 0)"));
}

test "structure primitives check their argument counts" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(%make-structure)"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(%structure-p)"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(%structure-name)"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(%structure-ref (%make-structure 'r 1))"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(%set-structure-ref (%make-structure 'r 1) 0)"));
    try testing.expectError(Error.WrongArgCount, fx.evalStr("(%copy-structure)"));
}

test "%structure-p is false for every non-structure value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectNil("(%structure-p 5)");
    try fx.expectNil("(%structure-p \"s\")");
    try fx.expectNil("(%structure-p '(1 2))");
    try fx.expectT("(%structure-p (%make-structure 'r))");
}

test "a non-symbol in the slot-name list prints as a bare value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try zisp.builtins.registerSystem(&fx.ev);
    _ = try fx.evalStr("(%put 'raw '%structure-slots '(1 b))");
    try testing.expectEqualStrings(
        "#S(RAW 7 :B 8)",
        try fx.printed("(format nil \"~S\" (%make-structure 'raw 7 8))"),
    );
}

test "an odd plist on the structure name falls back to bare values" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try zisp.builtins.registerSystem(&fx.ev);
    _ = try fx.evalStr("(setf (symbol-plist 'raw) '(some-key))");
    try testing.expectEqualStrings(
        "#S(RAW 7)",
        try fx.printed("(format nil \"~S\" (%make-structure 'raw 7))"),
    );
}

test "a plist entry before the slot list is skipped" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try zisp.builtins.registerSystem(&fx.ev);
    _ = try fx.evalStr("(%put 'raw 'unrelated 1)");
    _ = try fx.evalStr("(%put 'raw '%structure-slots '(a))");
    try testing.expectEqualStrings(
        "#S(RAW :A 7)",
        try fx.printed("(format nil \"~S\" (%make-structure 'raw 7))"),
    );
}
