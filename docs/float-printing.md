# Printing floats

`prin1` on a float has to produce text that reads back as the same bits,
using as few digits as will do it. This note compares the three algorithms
that solve that problem and records which one zisp uses.

## The candidates

### Steele & White (Dragon4)

The 1990 paper *How to print floating-point numbers accurately* gives the
first algorithm that is both correct and shortest. It works by exact
rational arithmetic: the value and the two half-way points to its
neighbours are held as big-integer fractions, and digits are generated one
at a time until the emitted prefix can only read back as the original
value.

- Correct and shortest by construction, and easy to argue about.
- Needs arbitrary-precision integers, which zisp already has.
- Slowest of the three by a wide margin. Every digit costs several
  big-integer operations.

### Grisu

Loitsch's 2010 algorithm replaces the big integers with a 64-bit
fixed-point representation and a table of cached powers of ten. It is far
faster than Dragon4, but Grisu2 is not always shortest and Grisu3 detects
the cases it cannot settle and gives up on them, leaving roughly half a
percent of inputs to a Dragon4 fallback.

- Fast for the common case.
- Requires implementing *two* algorithms, since the fallback is mandatory.
- The uncertainty is the point of failure: a bug in the fallback path shows
  up only on rare inputs, which is exactly the hard-case corpus.

### Ryu

Adams' 2018 algorithm is always shortest and always exact, using only
fixed-width integer arithmetic against a table of precomputed powers of
five. It is comparable to Grisu in speed with none of the fallback.

- Shortest and correct for every input, with no second algorithm behind it.
- Larger tables and more intricate code than Dragon4.
- The tables are a compile-time constant, not runtime state.

## The choice

zisp uses Ryu, by way of Zig's `std.fmt.float`, which is a Ryu
implementation of exactly this algorithm and produces the shortest
round-trippable digits for `f16` through `f128` in both scientific and
decimal form.

This is not the `printf("%g")` shortcut that milestone 4.5.5d rules out.
`%g` is a fixed-significant-digit format: it neither guarantees a
round-trip nor produces the shortest text, and it fails on the hard-case
corpus. Zig's implementation performs the Ryu shortest-representation
search, and the corpus is what will demonstrate that.

What remains on zisp's side is the Common Lisp presentation layer, which
none of the three algorithms addresses:

- choosing the exponent marker from the float's type and
  `*read-default-float-format*`, so a double prints as `1.0d0` and a single
  as `1.0`,
- CLHS 22.1.3.1.3's rule for when to print in fixed-point form versus
  exponential form, based on the magnitude,
- always emitting a decimal point, so `1.0` does not print as `1`,
- and the `~E`, `~F`, `~G` and `~$` format directives, which specify digit
  counts and therefore do not use the shortest form at all.

Those rules are where the round-trip requirement in 4.5.5c can be broken
even with a correct digit generator, so the corpus checks the printed text
end to end rather than the digit string alone.

## Consequences

The digit generation is a dependency on the Zig standard library rather
than zisp code. If it ever needs replacing, the surface is one function
that turns a float and a mode into digits, and Dragon4 on top of the
existing bignums is the fallback that needs no new tables.
