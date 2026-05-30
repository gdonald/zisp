# Value tagging

Zisp uses low-3-bit pointer tagging on 64-bit. Every Lisp value fits in a single `u64`. The low three bits determine the type; the remaining 61 bits hold either an immediate value or an aligned pointer.

## Tag layout

| Tag | Type | Payload |
|-----|------|---------|
| `0b000` | fixnum | 61-bit signed integer in the high bits (`i64 >> 3` recovers the value) |
| `0b001` | cons | aligned pointer to `Cons{car, cdr}` |
| `0b010` | symbol | aligned pointer to `Symbol{name, value, function, plist, package}` |
| `0b011` | heap object | aligned pointer to `HeapObject` whose first byte tags the concrete type (string, vector, hash-table, function, etc.) |
| `0b100` | character | 21-bit Unicode codepoint in the high bits |
| `0b101` | special immediate | low byte after the tag indexes a small table (`unbound-marker`, `eof`, etc.) |
| `0b110` | reserved | — |
| `0b111` | reserved | — |

## Why these choices

**Fixnum tag = 0.** Addition and subtraction of two fixnums require no tag manipulation: `(a << 3) + (b << 3) = (a + b) << 3`. Multiplication needs one untag.

**8-byte alignment.** All heap allocators must return pointers aligned to ≥ 8 bytes so the low 3 bits are zero and available for tagging. Zig's default allocators satisfy this.

**NIL and T as symbols.** NIL is the empty list, the symbol `nil`, and the boolean false. T is the symbol `t` and the boolean true. Both are pre-interned at fixed addresses in the symbol table at startup; their `Value` forms are stored in `runtime.NIL` and `runtime.T`. Identity checks use raw `Value` equality.

**Characters as immediates.** Avoids a heap allocation per character. 21 bits covers all of Unicode.

**Heap-object tag carries everything else.** The heap-object header has a one-byte type tag (`HeapType`) so we don't burn precious low bits on rare types like `package` or `pathname`.

## Fixnum range

61-bit signed:

- `FIXNUM_MIN = -2^60 = -1152921504606846976`
- `FIXNUM_MAX = 2^60 - 1 = 1152921504606846975`

Overflow will promote to a `bignum` heap object (not yet implemented).

## Reserved tags

`0b110` and `0b111` are reserved for future immediate types. Candidates include single-precision floats (28 bits is enough for f32 if we sacrifice some range), small ratios, and SIMD-packed values. Unused for now so we can add them without breaking the encoding.
