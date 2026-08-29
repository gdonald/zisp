//! Integer arithmetic across fixnums and bignums: promotion on overflow,
//! the four divisions, ordering, and the bit operations.

const std = @import("std");
const testing = std.testing;
const zisp = @import("zisp");
const value = zisp.value;
const heap_mod = zisp.heap;
const symbol_mod = zisp.symbol;
const printer = zisp.printer;
const Evaluator = zisp.eval.Evaluator;
const Error = zisp.eval.eval.Error;
const Value = value.Value;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: zisp.Heap,
    ev: Evaluator,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .interner = try symbol_mod.Interner.init(allocator),
            .heap = undefined,
            .ev = undefined,
        };
        try symbol_mod.initStandardSymbols(&fx.interner);
        fx.heap = zisp.Heap.init(fx.arena.allocator());
        fx.ev = Evaluator.init(allocator, &fx.heap, &fx.interner);
        try zisp.eval.registerStandardSpecialForms(&fx.ev);
        try zisp.builtins.registerStandard(&fx.ev);
        return fx;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.ev.deinit();
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

    /// The printed form of what `src` evaluates to, which is how a bignum
    /// is checked without depending on its limb layout.
    fn expectPrints(self: *Fixture, src: []const u8, expected: []const u8) !void {
        const v = try self.evalStr(src);
        const text = try printer.printToOwnedSlice(testing.allocator, v);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    fn expectFix(self: *Fixture, src: []const u8, expected: i64) !void {
        const v = try self.evalStr(src);
        try testing.expect(v.isFixnum());
        try testing.expectEqual(expected, v.toFixnum());
    }

    fn expectT(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.T));
    }

    fn expectNil(self: *Fixture, src: []const u8) !void {
        try testing.expect((try self.evalStr(src)).equalsRaw(value.NIL));
    }

    fn expectErr(self: *Fixture, err: Error, src: []const u8) !void {
        try testing.expectError(err, self.evalStr(src));
    }
};

fn newFx() !*Fixture {
    return Fixture.init(testing.allocator);
}

/// 2^60, the first integer past the fixnum range.
const FIRST_BIGNUM = "1152921504606846976";

// --- promotion ---

test "a fixnum result stays a fixnum" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(+ 1 2 3)", 6);
    try fx.expectFix("(- 10 4)", 6);
    try fx.expectFix("(* 6 7)", 42);
    try fx.expectFix("(+)", 0);
    try fx.expectFix("(*)", 1);
    try fx.expectFix("(- 5)", -5);
}

test "overflowing the fixnum range promotes to a bignum" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(* 1152921504606846975 2)", "2305843009213693950");
    try fx.expectPrints("(+ 1152921504606846975 1)", FIRST_BIGNUM);
    try fx.expectPrints("(- -1152921504606846976 1)", "-1152921504606846977");
    try fx.expectT("(integerp (* 1152921504606846975 2))");
}

test "a bignum result that shrinks back into range becomes a fixnum" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(- (* 1152921504606846976 1) 1152921504606846976)", 0);
    try fx.expectFix("(- 1152921504606846976 1152921504606846975)", 1);
    try fx.expectFix("(ash 1152921504606846976 -60)", 1);
}

test "arithmetic runs on operands of either size" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(* 99999999999999999999 99999999999999999999)", "9999999999999999999800000000000000000001");
    try fx.expectPrints("(+ 123456789012345678901234567890 1)", "123456789012345678901234567891");
    try fx.expectPrints("(- 123456789012345678901234567890 1)", "123456789012345678901234567889");
    try fx.expectPrints("(* 123456789012345678901234567890 -1)", "-123456789012345678901234567890");
    try fx.expectPrints("(1+ 1152921504606846975)", FIRST_BIGNUM);
    try fx.expectPrints("(1+ 123456789012345678901234567890)", "123456789012345678901234567891");
    try fx.expectFix("(1- 1152921504606846976)", 1152921504606846975);
    try fx.expectPrints("(1- -1152921504606846976)", "-1152921504606846977");
}

test "abs works either side of the fixnum boundary" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(abs -5)", 5);
    try fx.expectFix("(abs 5)", 5);
    try fx.expectPrints("(abs -1152921504606846977)", "1152921504606846977");
    try fx.expectPrints("(abs -1152921504606846976)", FIRST_BIGNUM);
}

test "arithmetic rejects a non-integer and a bad argument count" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(+ 1 'x)");
    try fx.expectErr(Error.TypeError, "(- 'x 1)");
    try fx.expectErr(Error.TypeError, "(- 1 'x)");
    try fx.expectErr(Error.TypeError, "(* 1 \"x\")");
    try fx.expectErr(Error.TypeError, "(1+ 'x)");
    try fx.expectErr(Error.TypeError, "(1- 'x)");
    try fx.expectErr(Error.TypeError, "(abs 'x)");
    try fx.expectErr(Error.WrongArgCount, "(-)");
    try fx.expectErr(Error.WrongArgCount, "(1+)");
    try fx.expectErr(Error.WrongArgCount, "(1-)");
    try fx.expectErr(Error.WrongArgCount, "(abs)");
}

// --- ordering ---

test "comparisons work across the fixnum boundary" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(< 1152921504606846976 1152921504606846977)");
    try fx.expectT("(> 1152921504606846977 1152921504606846976)");
    try fx.expectT("(< 1 1152921504606846976)");
    try fx.expectT("(> 1152921504606846976 1)");
    try fx.expectT("(< -1152921504606846977 0)");
    try fx.expectT("(= 1152921504606846976 1152921504606846976)");
    try fx.expectNil("(= 1152921504606846976 1152921504606846977)");
    try fx.expectT("(<= 1 1 2)");
    try fx.expectT("(>= 2 1 1)");
    try fx.expectNil("(<= 2 1)");
    try fx.expectNil("(>= 1 2)");
    try fx.expectT("(/= 1 2 3)");
    try fx.expectNil("(/= 1 2 1)");
}

test "comparisons check their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(<)");
    try fx.expectErr(Error.WrongArgCount, "(/=)");
    try fx.expectErr(Error.TypeError, "(< 1 'x)");
    try fx.expectErr(Error.TypeError, "(/= 1 'x)");
}

test "min and max return the winning argument" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(min 3 1 2)", 1);
    try fx.expectFix("(max 3 1 2)", 3);
    try fx.expectPrints("(max 1 1152921504606846976)", FIRST_BIGNUM);
    try fx.expectFix("(min 1 1152921504606846976)", 1);
    try fx.expectErr(Error.WrongArgCount, "(min)");
    try fx.expectErr(Error.WrongArgCount, "(max)");
    try fx.expectErr(Error.TypeError, "(min 'x)");
    try fx.expectErr(Error.TypeError, "(max 'x)");
}

test "the sign and parity predicates cover both sizes" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(zerop 0)");
    try fx.expectNil("(zerop 1)");
    try fx.expectT("(plusp 1152921504606846976)");
    try fx.expectT("(minusp -1152921504606846977)");
    try fx.expectNil("(plusp -1)");
    try fx.expectNil("(minusp 1)");
    try fx.expectT("(evenp (* 1152921504606846976 2))");
    try fx.expectNil("(oddp (* 1152921504606846976 2))");
    try fx.expectT("(oddp 3)");
    try fx.expectNil("(evenp 3)");
    try fx.expectErr(Error.WrongArgCount, "(zerop)");
    try fx.expectErr(Error.WrongArgCount, "(evenp)");
    try fx.expectErr(Error.TypeError, "(evenp 'x)");
    try fx.expectErr(Error.TypeError, "(zerop 'x)");
}

test "integerp accepts a bignum" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(integerp 1)");
    try fx.expectT("(integerp 1152921504606846976)");
    try fx.expectNil("(integerp 'x)");
    try fx.expectT("(numberp 1152921504606846976)");
    try fx.expectErr(Error.WrongArgCount, "(integerp)");
}

// --- division ---

test "floor and ceiling round toward negative and positive infinity" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(floor 7 2)", 3);
    try fx.expectFix("(floor -7 2)", -4);
    try fx.expectFix("(floor 7 -2)", -4);
    try fx.expectFix("(ceiling 7 2)", 4);
    try fx.expectFix("(ceiling -7 2)", -3);
    try fx.expectFix("(ceiling 6 2)", 3);
    try fx.expectFix("(floor 6 2)", 3);
}

test "truncate rounds toward zero" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(truncate 7 2)", 3);
    try fx.expectFix("(truncate -7 2)", -3);
    try fx.expectFix("(truncate 7 -2)", -3);
}

test "round breaks a tie toward even" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(round 5 2)", 2);
    try fx.expectFix("(round 7 2)", 4);
    try fx.expectFix("(round -5 2)", -2);
    try fx.expectFix("(round -7 2)", -4);
    try fx.expectFix("(round 8 3)", 3);
    try fx.expectFix("(round 7 3)", 2);
}

test "each division returns the remainder as a second value" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(nth-value 1 (floor 7 2))", 1);
    try fx.expectFix("(nth-value 1 (floor -7 2))", 1);
    try fx.expectFix("(nth-value 1 (truncate -7 2))", -1);
    try fx.expectFix("(nth-value 1 (ceiling 7 2))", -1);
    try fx.expectFix("(nth-value 1 (round 5 2))", 1);
}

test "a one-argument division divides by one" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(floor 7)", 7);
    try fx.expectFix("(nth-value 1 (floor 7))", 0);
}

test "division works on bignums and reduces back where it can" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(floor 2305843009213693952 1152921504606846976)", 2);
    try fx.expectPrints("(floor 9999999999999999999800000000000000000001 99999999999999999999)", "99999999999999999999");
    try fx.expectFix("(nth-value 1 (floor 2305843009213693953 1152921504606846976))", 1);
    try fx.expectFix("(floor -2305843009213693953 1152921504606846976)", -3);
    try fx.expectFix("(ceiling 2305843009213693953 1152921504606846976)", 3);
    try fx.expectFix("(truncate -2305843009213693953 1152921504606846976)", -2);
    try fx.expectFix("(round 1729382256910270464 1152921504606846976)", 2);
    try fx.expectFix("(round 2882303761517117440 1152921504606846976)", 2);
}

test "division by zero is an error, and the arguments are checked" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.DivisionByZero, "(floor 1 0)");
    try fx.expectErr(Error.DivisionByZero, "(mod 1 0)");
    try fx.expectErr(Error.DivisionByZero, "(rem 1 0)");
    try fx.expectErr(Error.WrongArgCount, "(floor)");
    try fx.expectErr(Error.WrongArgCount, "(floor 1 2 3)");
    try fx.expectErr(Error.WrongArgCount, "(mod 1)");
    try fx.expectErr(Error.WrongArgCount, "(rem 1)");
    try fx.expectErr(Error.TypeError, "(floor 'x 1)");
    try fx.expectErr(Error.TypeError, "(floor 1 'x)");
}

test "mod and rem are the remainders of floor and truncate" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(mod -7 2)", 1);
    try fx.expectFix("(rem -7 2)", -1);
    try fx.expectFix("(mod 7 -2)", -1);
    try fx.expectFix("(rem 7 -2)", 1);
    try fx.expectFix("(mod 2305843009213693953 1152921504606846976)", 1);
}

// --- bit operations ---

test "the bitwise operations fold over their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(logand 12 10)", 8);
    try fx.expectFix("(logior 12 10)", 14);
    try fx.expectFix("(logxor 12 10)", 6);
    try fx.expectFix("(logand)", -1);
    try fx.expectFix("(logior)", 0);
    try fx.expectFix("(logxor)", 0);
    try fx.expectFix("(logand 12)", 12);
    try fx.expectFix("(logxor 1 2 4)", 7);
    try fx.expectErr(Error.TypeError, "(logand 'x)");
}

test "the bitwise operations reach into bignums" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(logior 1152921504606846976 1)", "1152921504606846977");
    try fx.expectFix("(logand 1152921504606846976 1152921504606846975)", 0);
    try fx.expectPrints("(logxor 1152921504606846976 1)", "1152921504606846977");
}

test "lognot is the complement on both sides of the boundary" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(lognot 5)", -6);
    try fx.expectFix("(lognot -1)", 0);
    try fx.expectPrints("(lognot 1152921504606846976)", "-1152921504606846977");
    try fx.expectPrints("(lognot -1152921504606846978)", "1152921504606846977");
    try fx.expectErr(Error.WrongArgCount, "(lognot)");
    try fx.expectErr(Error.TypeError, "(lognot 'x)");
}

test "ash shifts either way" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(ash 1 4)", 16);
    try fx.expectFix("(ash 16 -4)", 1);
    try fx.expectFix("(ash -1 -1)", -1);
    try fx.expectFix("(ash 1 0)", 1);
    try fx.expectPrints("(ash 1 70)", "1180591620717411303424");
    try fx.expectFix("(ash 1180591620717411303424 -70)", 1);
    try fx.expectErr(Error.WrongArgCount, "(ash 1)");
    try fx.expectErr(Error.TypeError, "(ash 'x 1)");
    try fx.expectErr(Error.TypeError, "(ash 1 'x)");
}

test "integer-length counts the bits a value needs" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(integer-length 0)", 0);
    try fx.expectFix("(integer-length 1)", 1);
    try fx.expectFix("(integer-length 255)", 8);
    try fx.expectFix("(integer-length 256)", 9);
    try fx.expectFix("(integer-length -1)", 0);
    try fx.expectFix("(integer-length -256)", 8);
    try fx.expectFix("(integer-length -257)", 9);
    try fx.expectFix("(integer-length 1152921504606846976)", 61);
    try fx.expectFix("(integer-length -1152921504606846977)", 61);
    try fx.expectErr(Error.WrongArgCount, "(integer-length)");
    try fx.expectErr(Error.TypeError, "(integer-length 'x)");
}

// --- identity and hashing ---

test "two bignums of the same value are eql and hash alike" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(eql (* 1152921504606846976 3) (* 1152921504606846976 3))");
    try fx.expectNil("(eql (* 1152921504606846976 3) (* 1152921504606846976 4))");
    try fx.expectT("(equal (* 1152921504606846976 3) (* 1152921504606846976 3))");
    try fx.expectT("(equalp (* 1152921504606846976 3) (* 1152921504606846976 3))");
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'eql)))
        \\  (setf (gethash (* 1152921504606846976 3) h) 'found)
        \\  (eq (gethash (* 1152921504606846976 3) h) 'found))
    );
}

test "a bignum key works in an equalp table" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'equalp)))
        \\  (setf (gethash (* 1152921504606846976 3) h) 'found)
        \\  (eq (gethash (* 1152921504606846976 3) h) 'found))
    );
}

// --- rationals ---

test "division of integers yields a reduced ratio" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(/ 1 2)", "1/2");
    try fx.expectPrints("(/ 2 4)", "1/2");
    try fx.expectPrints("(/ 6 -4)", "-3/2");
    try fx.expectFix("(/ 4 2)", 2);
    try fx.expectFix("(/ 6 3)", 2);
    try fx.expectFix("(/ 0 5)", 0);
}

test "a one-argument division is the reciprocal" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(/ 2)", "1/2");
    try fx.expectFix("(/ 1)", 1);
    try fx.expectPrints("(/ 2/3)", "3/2");
}

test "division folds left over several divisors" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(/ 1 2 3)", "1/6");
    try fx.expectFix("(/ 12 2 3)", 2);
}

test "division by zero is caught wherever the zero appears" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.DivisionByZero, "(/ 1 0)");
    try fx.expectErr(Error.DivisionByZero, "(/ 0)");
    try fx.expectErr(Error.DivisionByZero, "(/ 1 2 0)");
    try fx.expectErr(Error.WrongArgCount, "(/)");
    try fx.expectErr(Error.TypeError, "(/ 1 'x)");
}

test "a ratio literal is read in lowest terms" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("3/6", "1/2");
    try fx.expectPrints("-4/8", "-1/2");
    try fx.expectFix("6/3", 2);
    try fx.expectFix("0/5", 0);
    try testing.expectError(error.BadToken, fx.evalStr("1/0"));
}

test "the four operations work on ratios" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(+ 1/2 1/3)", "5/6");
    try fx.expectPrints("(- 1/2 1/3)", "1/6");
    try fx.expectFix("(* 2/3 3/2)", 1);
    try fx.expectPrints("(/ 1/2 1/3)", "3/2");
    try fx.expectPrints("(+ 1/2 1)", "3/2");
    try fx.expectPrints("(- 1 1/2)", "1/2");
    try fx.expectPrints("(* 3 1/2)", "3/2");
    try fx.expectFix("(+ 1/2 1/2)", 1);
    try fx.expectPrints("(1+ 1/2)", "3/2");
    try fx.expectPrints("(1- 1/2)", "-1/2");
}

test "a ratio can be built over integers of any size" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(/ 1152921504606846976 3)", "1152921504606846976/3");
    try fx.expectPrints("(/ 1 1152921504606846976)", "1/1152921504606846976");
    try fx.expectFix("(/ 2305843009213693952 1152921504606846976)", 2);
}

test "ratios compare against each other and against integers" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(< 1/3 1/2)");
    try fx.expectT("(> 1/2 1/3)");
    try fx.expectT("(= 2/4 1/2)");
    try fx.expectNil("(= 1/3 1/2)");
    try fx.expectT("(< 1/2 1)");
    try fx.expectT("(> 3/2 1)");
    try fx.expectT("(<= 1/2 1/2)");
    try fx.expectT("(/= 1/2 1/3)");
    try fx.expectPrints("(max 1/3 1/2)", "1/2");
    try fx.expectPrints("(min 1/3 1/2)", "1/3");
}

test "the sign predicates read a ratio's numerator" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(plusp 1/2)");
    try fx.expectT("(minusp -1/2)");
    try fx.expectNil("(zerop 1/2)");
    try fx.expectPrints("(abs -1/2)", "1/2");
}

test "numerator and denominator read any rational" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(numerator 3/6)", 1);
    try fx.expectFix("(denominator 3/6)", 2);
    try fx.expectFix("(numerator 5)", 5);
    try fx.expectFix("(denominator 5)", 1);
    try fx.expectErr(Error.TypeError, "(numerator 'x)");
    try fx.expectErr(Error.TypeError, "(denominator 'x)");
    try fx.expectErr(Error.WrongArgCount, "(numerator)");
    try fx.expectErr(Error.WrongArgCount, "(denominator)");
}

test "rationalp accepts integers and ratios" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(rationalp 1/2)");
    try fx.expectT("(rationalp 1)");
    try fx.expectT("(rationalp 1152921504606846976)");
    try fx.expectNil("(rationalp 'x)");
    try fx.expectNil("(integerp 1/2)");
    try fx.expectErr(Error.WrongArgCount, "(rationalp)");
}

test "the divisions round a ratio and leave a rational remainder" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(floor 7/2)", 3);
    try fx.expectPrints("(nth-value 1 (floor 7/2))", "1/2");
    try fx.expectFix("(ceiling 7/2)", 4);
    try fx.expectPrints("(nth-value 1 (ceiling 7/2))", "-1/2");
    try fx.expectFix("(truncate -7/2)", -3);
    try fx.expectFix("(round 7/2)", 4);
    try fx.expectFix("(round 5/2)", 2);
    try fx.expectFix("(floor -7/2)", -4);
    try fx.expectPrints("(mod 7/2 1)", "1/2");
    try fx.expectFix("(floor 1/2 1/3)", 1);
    try fx.expectPrints("(nth-value 1 (floor 1/2 1/3))", "1/6");
}

test "the integer-only operations reject a ratio" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(evenp 1/2)");
    try fx.expectErr(Error.TypeError, "(logand 1/2)");
    try fx.expectErr(Error.TypeError, "(lognot 1/2)");
    try fx.expectErr(Error.TypeError, "(ash 1/2 1)");
    try fx.expectErr(Error.TypeError, "(integer-length 1/2)");
    try fx.expectErr(Error.TypeError, "(gcd 1/2)");
    try fx.expectErr(Error.TypeError, "(lcm 1/2)");
}

test "gcd and lcm fold over their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(gcd)", 0);
    try fx.expectFix("(gcd 12 18)", 6);
    try fx.expectFix("(gcd 12 18 8)", 2);
    try fx.expectFix("(gcd -12 18)", 6);
    try fx.expectFix("(gcd 0 5)", 5);
    try fx.expectFix("(lcm)", 1);
    try fx.expectFix("(lcm 4 6)", 12);
    try fx.expectFix("(lcm 4 6 5)", 60);
    try fx.expectFix("(lcm 4 0)", 0);
    try fx.expectFix("(lcm -4 6)", 12);
    try fx.expectPrints("(gcd 2305843009213693952 1152921504606846976)", FIRST_BIGNUM);
    try fx.expectPrints("(lcm 1152921504606846976 2)", FIRST_BIGNUM);
}

test "two ratios of the same value are eql and hash alike" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(eql (/ 1 2) (/ 2 4))");
    try fx.expectNil("(eql (/ 1 2) (/ 1 3))");
    try fx.expectT("(equalp 1/2 (/ 2 4))");
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'eql)))
        \\  (setf (gethash (/ 1 2) h) 'found)
        \\  (eq (gethash (/ 2 4) h) 'found))
    );
}

// --- contagion ---

test "a float anywhere makes the result a float" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(+ 1 1.0)", "2.0");
    try fx.expectPrints("(* 2 1.5)", "3.0");
    try fx.expectPrints("(- 1 0.5)", "0.5");
    try fx.expectPrints("(/ 1 2.0)", "0.5");
    try fx.expectPrints("(+ 1/2 0.5)", "1.0");
    try fx.expectPrints("(1+ 1.5)", "2.5");
    try fx.expectPrints("(1- 1.5)", "0.5");
    try fx.expectPrints("(abs -1.5)", "1.5");
}

test "the widest float format wins" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(+ 1.0 2.0d0)", "3.0d0");
    try fx.expectPrints("(+ 1 2.0d0)", "3.0d0");
    try fx.expectPrints("(+ 1.0 2.0)", "3.0");
    try fx.expectPrints("(* 1.0d0 2)", "2.0d0");
    try fx.expectPrints("(- 1.0d0 0.5)", "0.5d0");
    try fx.expectPrints("(/ 1.0d0 2)", "0.5d0");
}

test "a single-argument operation keeps its float format" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(- 1.5)", "-1.5");
    try fx.expectPrints("(- 1.5d0)", "-1.5d0");
    try fx.expectPrints("(/ 2.0)", "0.5");
    try fx.expectPrints("(/ 2.0d0)", "0.5d0");
    try fx.expectPrints("(abs -1.5d0)", "1.5d0");
    try fx.expectPrints("(1+ 1.5d0)", "2.5d0");
}

test "comparisons are exact between a float and a rational" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(= 1 1.0)");
    try fx.expectT("(= 1/2 0.5)");
    try fx.expectNil("(= 1/3 0.33333334)");
    try fx.expectT("(< 0.5 1)");
    try fx.expectT("(> 1 0.5)");
    try fx.expectT("(<= 1.0 1)");
    try fx.expectT("(/= 1 1.5)");
    try fx.expectT("(< 1.0 2.0d0)");
}

test "a bignum compares exactly against a float that is near it" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    // 2^60 is exactly representable as a double, and its neighbors are not.
    try fx.expectT("(= 1152921504606846976 1.152921504606847d18)");
    try fx.expectT("(< 1152921504606846975 1.152921504606847d18)");
    try fx.expectT("(> 1152921504606846977 1.152921504606847d18)");
}

test "min, max and the sign predicates take floats" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(max 1 2.0)", "2.0");
    try fx.expectPrints("(min 1 0.5)", "0.5");
    try fx.expectT("(zerop 0.0)");
    try fx.expectT("(zerop -0.0)");
    try fx.expectT("(plusp 1.5)");
    try fx.expectT("(minusp -1.5)");
    try fx.expectNil("(plusp -1.5)");
}

test "the divisions take floats, returning an integer and a float" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(floor 5.5)", 5);
    try fx.expectPrints("(nth-value 1 (floor 5.5))", "0.5");
    try fx.expectFix("(ceiling 5.5)", 6);
    try fx.expectFix("(truncate -5.5)", -5);
    try fx.expectFix("(round 5.5)", 6);
    try fx.expectFix("(round 4.5)", 4);
    try fx.expectPrints("(mod 5.5 2)", "1.5");
    try fx.expectPrints("(rem -5.5 2)", "-1.5");
    try fx.expectPrints("(nth-value 1 (floor 5.5d0))", "0.5d0");
    try fx.expectErr(Error.DivisionByZero, "(floor 1.0 0)");
}

test "the float predicates and conversions" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(floatp 1.5)");
    try fx.expectT("(floatp 1.5d0)");
    try fx.expectNil("(floatp 1)");
    try fx.expectT("(realp 1/2)");
    try fx.expectT("(realp 1.5)");
    try fx.expectNil("(realp 'x)");
    try fx.expectNil("(rationalp 1.5)");
    try fx.expectT("(numberp 1.5)");
    try fx.expectErr(Error.WrongArgCount, "(floatp)");
    try fx.expectErr(Error.WrongArgCount, "(realp)");
}

test "float converts a real into a float of the chosen format" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(float 1/2)", "0.5");
    try fx.expectPrints("(float 1)", "1.0");
    try fx.expectPrints("(float 1 1.0d0)", "1.0d0");
    try fx.expectPrints("(float 1.5d0 1.0)", "1.5");
    try fx.expectErr(Error.TypeError, "(float 1 2)");
    try fx.expectErr(Error.TypeError, "(float 'x)");
    try fx.expectErr(Error.WrongArgCount, "(float)");
    try fx.expectErr(Error.WrongArgCount, "(float 1 1.0 1.0)");
}

test "rational gives the exact value a float denotes" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(rational 0.5)", "1/2");
    try fx.expectPrints("(rational 0.1d0)", "3602879701896397/36028797018963968");
    try fx.expectFix("(rational 2.0)", 2);
    try fx.expectFix("(rational 0.0)", 0);
    try fx.expectFix("(rational 5)", 5);
    try fx.expectPrints("(rational 1/2)", "1/2");
    try fx.expectPrints("(rational -0.5)", "-1/2");
    try fx.expectErr(Error.TypeError, "(rational 'x)");
    try fx.expectErr(Error.WrongArgCount, "(rational)");
}

test "a subnormal converts to an exact rational and back" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(= (float (rational 5.0d-324) 1.0d0) 5.0d-324)");
    try fx.expectT("(= (float (rational 2.2250738585072014d-308) 1.0d0) 2.2250738585072014d-308)");
}

test "the integer-only operations still reject a float" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(evenp 1.0)");
    try fx.expectErr(Error.TypeError, "(logand 1.0)");
    try fx.expectErr(Error.TypeError, "(ash 1.0 1)");
    try fx.expectErr(Error.TypeError, "(gcd 1.0)");
    try fx.expectErr(Error.TypeError, "(numerator 1.5)");
}

// --- complex numbers ---

test "a complex reads and prints in #C form" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("#C(1 2)", "#C(1 2)");
    try fx.expectPrints("#C(1.5 -2.5)", "#C(1.5 -2.5)");
    try fx.expectPrints("(complex 1 2)", "#C(1 2)");
}

test "a rational zero imaginary part collapses to the real" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("#C(1 0)", 1);
    try fx.expectFix("(complex 5)", 5);
    try fx.expectNil("(complexp #C(1 0))");
    try fx.expectT("(complexp #C(1.0 0.0))");
}

test "a float in either part makes both parts floats of that format" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(complex 1 2.0)", "#C(1.0 2.0)");
    try fx.expectPrints("(complex 1.0 2)", "#C(1.0 2.0)");
    try fx.expectPrints("(complex 1 2.0d0)", "#C(1.0d0 2.0d0)");
    try fx.expectPrints("(complex 1.0 2.0d0)", "#C(1.0d0 2.0d0)");
}

test "a malformed complex literal is rejected" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.BadToken, fx.evalStr("#C(1)"));
    try testing.expectError(error.BadToken, fx.evalStr("#C(1 2 3)"));
    try testing.expectError(error.BadToken, fx.evalStr("#C 1"));
    try testing.expectError(error.BadToken, fx.evalStr("#C(a b)"));
}

test "complex arithmetic stays exact over rationals" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(+ #C(1 2) #C(3 4))", "#C(4 6)");
    try fx.expectPrints("(- #C(1 2) #C(3 4))", "#C(-2 -2)");
    try fx.expectPrints("(* #C(1 2) #C(3 4))", "#C(-5 10)");
    try fx.expectPrints("(/ #C(1 1) #C(1 -1))", "#C(0 1)");
    try fx.expectPrints("(/ #C(1 2) 2)", "#C(1/2 1)");
    try fx.expectFix("(- #C(1 2) #C(1 2))", 0);
    try fx.expectPrints("(+ #C(1 2) 1)", "#C(2 2)");
    try fx.expectPrints("(* #C(1 2) 2)", "#C(2 4)");
}

test "a one-argument complex operation negates or inverts" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(- #C(1 2))", "#C(-1 -2)");
    try fx.expectPrints("(/ #C(0 1))", "#C(0 -1)");
}

test "the complex accessors read either kind of number" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(realpart #C(1 2))", 1);
    try fx.expectFix("(imagpart #C(1 2))", 2);
    try fx.expectFix("(realpart 5)", 5);
    try fx.expectFix("(imagpart 5)", 0);
    try fx.expectPrints("(imagpart 5.0)", "0.0");
    try fx.expectPrints("(imagpart 5.0d0)", "0.0d0");
    try fx.expectPrints("(conjugate #C(1 2))", "#C(1 -2)");
    try fx.expectFix("(conjugate 5)", 5);
}

test "the complex operations check their arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(complex)");
    try fx.expectErr(Error.WrongArgCount, "(complex 1 2 3)");
    try fx.expectErr(Error.TypeError, "(complex 'x 1)");
    try fx.expectErr(Error.TypeError, "(complex #C(1 2) 1)");
    try fx.expectErr(Error.WrongArgCount, "(realpart)");
    try fx.expectErr(Error.WrongArgCount, "(imagpart)");
    try fx.expectErr(Error.WrongArgCount, "(conjugate)");
    try fx.expectErr(Error.WrongArgCount, "(complexp)");
    try fx.expectErr(Error.TypeError, "(realpart 'x)");
    try fx.expectErr(Error.TypeError, "(imagpart 'x)");
    try fx.expectErr(Error.TypeError, "(conjugate 'x)");
}

test "equality reaches complex numbers but ordering does not" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(= #C(1 2) #C(1 2))");
    try fx.expectNil("(= #C(1 2) #C(1 3))");
    try fx.expectT("(= #C(1 0.0) 1)");
    try fx.expectNil("(= #C(1 2) 1)");
    try fx.expectT("(/= #C(1 2) #C(1 3))");
    try fx.expectNil("(/= #C(1 2) #C(1 2))");
    try fx.expectT("(zerop #C(0 0.0))");
    try fx.expectNil("(zerop #C(1 0.0))");
    try fx.expectErr(Error.TypeError, "(< #C(1 2) 3)");
    try fx.expectErr(Error.TypeError, "(> 3 #C(1 2))");
    try fx.expectErr(Error.TypeError, "(plusp #C(1 2))");
}

test "eql on complex numbers compares both parts" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(eql (complex 1 2) (complex 1 2))");
    try fx.expectNil("(eql (complex 1 2) (complex 1 3))");
    try fx.expectNil("(eql (complex 1.0 2.0) (complex 1 2))");
    try fx.expectT(
        \\(let ((h (make-hash-table :test 'eql)))
        \\  (setf (gethash (complex 1 2) h) 'found)
        \\  (eq (gethash (complex 1 2) h) 'found))
    );
}

test "abs and phase of a complex number" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(abs #C(3 4))", "5.0");
    try fx.expectPrints("(abs #C(3.0d0 4.0d0))", "5.0d0");
    try fx.expectPrints("(phase 1.0)", "0.0");
    try fx.expectErr(Error.WrongArgCount, "(phase)");
    try fx.expectErr(Error.TypeError, "(phase 'x)");
}

// --- transcendental functions ---

test "a real argument gives a real result where the function allows one" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(sqrt 4)", "2.0");
    try fx.expectPrints("(sqrt 4.0d0)", "2.0d0");
    try fx.expectPrints("(exp 0)", "1.0");
    try fx.expectPrints("(log 1)", "0.0");
    try fx.expectPrints("(sin 0)", "0.0");
    try fx.expectPrints("(cos 0)", "1.0");
    try fx.expectPrints("(tan 0)", "0.0");
    try fx.expectPrints("(asin 0)", "0.0");
    try fx.expectPrints("(atan 0)", "0.0");
    try fx.expectPrints("(sinh 0)", "0.0");
    try fx.expectPrints("(cosh 0)", "1.0");
    try fx.expectPrints("(tanh 0)", "0.0");
    try fx.expectPrints("(asinh 0)", "0.0");
    try fx.expectPrints("(acosh 1)", "0.0");
    try fx.expectPrints("(atanh 0)", "0.0");
    try fx.expectPrints("(acos 1)", "0.0");
}

test "leaving the real domain produces a complex result" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(complexp (sqrt -1))");
    try fx.expectT("(complexp (log -1))");
    try fx.expectT("(complexp (asin 2))");
    try fx.expectT("(complexp (acos 2))");
    try fx.expectT("(complexp (acosh 0))");
    try fx.expectT("(complexp (atanh 2))");
    try fx.expectNil("(complexp (sqrt 2))");
    try fx.expectNil("(complexp (asinh -5))");
}

test "a rational argument gives a single-float and a double gives a double" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(sqrt 2)", "1.4142135");
    try fx.expectPrints("(sqrt 2.0d0)", "1.4142135623730951d0");
    try fx.expectPrints("(exp 1)", "2.7182817");
    try fx.expectPrints("(sqrt 1/4)", "0.5");
    try fx.expectPrints("(sqrt (complex 0.0d0 2.0d0))", "#C(1.0d0 1.0d0)");
}

test "log takes an optional base and rejects zero" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(log 100 10)", "2.0");
    try fx.expectPrints("(log 8 2)", "3.0");
    try fx.expectErr(Error.ArithmeticError, "(log 0)");
    try fx.expectErr(Error.ArithmeticError, "(log 0.0)");
    try fx.expectErr(Error.WrongArgCount, "(log)");
    try fx.expectErr(Error.WrongArgCount, "(log 1 2 3)");
    try fx.expectErr(Error.TypeError, "(log 'x)");
}

test "atan takes one or two arguments" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("(atan 0 1)", "0.0");
    try fx.expectT("(> (atan 1 -1) 0)");
    try fx.expectT("(< (atan -1 -1) 0)");
    try fx.expectErr(Error.WrongArgCount, "(atan)");
    try fx.expectErr(Error.WrongArgCount, "(atan 1 2 3)");
    try fx.expectErr(Error.TypeError, "(atan #C(1 2) 1)");
    try fx.expectErr(Error.TypeError, "(atan 'x)");
}

test "the unary transcendentals check their argument count and type" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.WrongArgCount, "(sqrt)");
    try fx.expectErr(Error.WrongArgCount, "(exp 1 2)");
    try fx.expectErr(Error.TypeError, "(sqrt 'x)");
    try fx.expectErr(Error.TypeError, "(sin \"x\")");
}

test "isqrt is exact at any magnitude" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(isqrt 0)", 0);
    try fx.expectFix("(isqrt 1)", 1);
    try fx.expectFix("(isqrt 15)", 3);
    try fx.expectFix("(isqrt 16)", 4);
    try fx.expectFix("(isqrt 17)", 4);
    try fx.expectFix("(isqrt 1000000000000000000000000)", 1000000000000);
    try fx.expectPrints("(isqrt (* 1152921504606846976 1152921504606846976))", "1152921504606846976");
    try fx.expectErr(Error.TypeError, "(isqrt -1)");
    try fx.expectErr(Error.TypeError, "(isqrt 1.5)");
    try fx.expectErr(Error.WrongArgCount, "(isqrt)");
}

test "expt with an integer power stays exact" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectFix("(expt 2 10)", 1024);
    try fx.expectFix("(expt 0 0)", 1);
    try fx.expectFix("(expt 5 1)", 5);
    try fx.expectFix("(expt -2 3)", -8);
    try fx.expectPrints("(expt 2 -1)", "1/2");
    try fx.expectPrints("(expt 1/2 3)", "1/8");
    try fx.expectPrints("(expt #C(0 1) 2)", "-1");
    try fx.expectT("(> (expt 2 1000) (expt 2 999))");
    try fx.expectFix("(integer-length (expt 2 1000))", 1001);
}

test "expt with a non-integer power goes through the complex plane" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(complexp (expt -2 1/2))");
    try fx.expectPrints("(expt 4 1/2)", "2.0");
    try fx.expectPrints("(expt 0 2.0)", "0.0");
    try fx.expectErr(Error.ArithmeticError, "(expt 0 -1.0)");
    try fx.expectErr(Error.WrongArgCount, "(expt 2)");
    try fx.expectErr(Error.TypeError, "(expt 'x 2)");
    try fx.expectErr(Error.TypeError, "(expt 2 'x)");
}

test "the standard numeric constants are bound" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectPrints("pi", "3.141592653589793d0");
    try fx.expectFix("most-positive-fixnum", 1152921504606846975);
    try fx.expectFix("most-negative-fixnum", -1152921504606846976);
    try fx.expectT("(> (* most-positive-fixnum 2) most-positive-fixnum)");
}

// --- random ---

test "random returns a value below its limit" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((ok t) (i 0))
        \\  (tagbody
        \\   step
        \\     (when (< i 200)
        \\       (let ((n (random 10)))
        \\         (unless (and (integerp n) (>= n 0) (< n 10)) (setq ok nil)))
        \\       (setq i (1+ i))
        \\       (go step)))
        \\  ok)
    );
    try fx.expectFix("(random 1)", 0);
}

test "a float limit gives a float below it, in the limit's format" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(let ((x (random 1.0))) (and (floatp x) (>= x 0) (< x 1)))");
    try fx.expectT("(let ((x (random 2.0d0))) (and (floatp x) (>= x 0) (< x 2)))");
    try fx.expectT("(= (imagpart (random 1.0)) 0.0)");
}

test "random spans a bignum limit" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let ((limit (expt 2 100)))
        \\  (let ((n (random limit)))
        \\    (and (integerp n) (>= n 0) (< n limit))))
    );
    try fx.expectT(
        \\(let ((limit (+ (expt 2 100) 1)) (big nil) (i 0))
        \\  (tagbody
        \\   step
        \\     (when (< i 20)
        \\       (when (> (random limit) (expt 2 90)) (setq big t))
        \\       (setq i (1+ i))
        \\       (go step)))
        \\  big)
    );
}

test "random rejects a limit that is not a positive real" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectErr(Error.TypeError, "(random 0)");
    try fx.expectErr(Error.TypeError, "(random -1)");
    try fx.expectErr(Error.TypeError, "(random 0.0)");
    try fx.expectErr(Error.TypeError, "(random -1.0)");
    try fx.expectErr(Error.TypeError, "(random 'x)");
    try fx.expectErr(Error.TypeError, "(random 1/2)");
    try fx.expectErr(Error.WrongArgCount, "(random)");
    try fx.expectErr(Error.WrongArgCount, "(random 10 *random-state* 3)");
    try fx.expectErr(Error.TypeError, "(random 10 5)");
}

test "a copied state repeats the sequence its original would have given" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let* ((a (make-random-state))
        \\       (b (make-random-state a)))
        \\  (and (= (random 1000 a) (random 1000 b))
        \\       (= (random 1000 a) (random 1000 b))))
    );
    try fx.expectT("(let ((a (make-random-state))) (/= (random 1000 a) (random 1000 a)))");
}

test "make-random-state reads its argument the three ways CLHS names" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(random-state-p (make-random-state))");
    try fx.expectT("(random-state-p (make-random-state nil))");
    try fx.expectT("(random-state-p (make-random-state t))");
    try fx.expectT("(random-state-p (make-random-state *random-state*))");
    try fx.expectT("(not (eq (make-random-state) *random-state*))");
    try fx.expectErr(Error.TypeError, "(make-random-state 5)");
    try fx.expectErr(Error.WrongArgCount, "(make-random-state nil nil)");
}

test "a freshly seeded state diverges from the one it came from" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT(
        \\(let* ((a (make-random-state))
        \\       (b (make-random-state t)))
        \\  (/= (random 1000000 a) (random 1000000 b)))
    );
}

test "random-state-p and the state variable" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    try fx.expectT("(random-state-p *random-state*)");
    try fx.expectNil("(random-state-p 5)");
    try fx.expectErr(Error.WrongArgCount, "(random-state-p)");
}

test "a random state prints as an unreadable object" {
    const fx = try newFx();
    defer fx.deinit(testing.allocator);
    const v = try fx.evalStr("*random-state*");
    const text = try printer.printToOwnedSlice(testing.allocator, v);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("#<random-state>", text);
}
