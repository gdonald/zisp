# Bignums

## The choice

Arbitrary-precision integers wrap Zig's `std.math.big.int` rather than a
hand-rolled limb representation.

`std.math.big.int` already provides everything the numeric tower needs:
addition, subtraction, multiplication, floor and truncating division, the
bitwise operations, shifts, ordering, and base-N string conversion. It is
part of the standard library, so it is maintained and tested outside this
project, and its `Managed` API handles limb growth.

A hand-rolled implementation would mean writing and testing schoolbook
multiplication, Knuth algorithm D division, and decimal conversion before
any of the Lisp-level work could start. That is a large amount of code
whose only advantage would be control over allocation, which is not a
constraint worth paying for at this stage. If profiling later shows the
allocation pattern is the bottleneck, the internals can be replaced behind
the same interface without touching any caller.

## Representation

A bignum is a heap object holding a limb pointer, a limb count, and a sign,
which is exactly `std.math.big.int.Const` split into fields. Converting a
heap bignum to a `Const` is free; converting back stores the limbs the
arithmetic already allocated.

Integers are normalized on the way out: a result that fits the fixnum range
is returned as a fixnum, so a bignum only ever exists for a value that
needs one. Two consequences follow, and both are relied on elsewhere:

- `eql` on two integers of the same value never has to compare a fixnum
  against a bignum, because the bignum could not exist.
- `integerp` has to accept both tags, but every other predicate can test
  the fixnum tag first and fall through.

## Allocation

Results are computed into a `Managed` backed by the heap's allocator and
the limbs are then handed to the bignum object without copying. The heap is
an arena today, so the `Managed` bookkeeping is abandoned rather than freed.
A real collector will need the limb block to be traced as a leaf; the limb
pointer is stored in the object for that reason rather than being allocated
inline.
