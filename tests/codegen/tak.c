/*
 * TAK as a code generator emitting C would write it, built with
 * `zig cc`. Values are tagged the way zisp tags them: a fixnum is the
 * number shifted left three bits, with tag zero.
 *
 * `tak_boxed` checks every operand is a fixnum and calls a slow path
 * that is never taken here, and calls itself through a function cell,
 * the way a call to a global function that can be redefined has to.
 * `tak_unboxed` is what the same function comes to once its arguments
 * are known to be fixnums: plain integers and direct calls.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef uint64_t value;

#define TAG_MASK 7u
#define FIXNUM(n) ((value)((int64_t)(n) * 8))
#define UNFIX(v) ((int64_t)(v) >> 3)
#define IS_FIXNUM(v) (((v) & TAG_MASK) == 0)
#define NIL ((value)0x13)

typedef value (*fn3)(value, value, value);

__attribute__((noinline)) static value generic_less(value a, value b) {
    fprintf(stderr, "slow path taken\n");
    exit(1);
    return a < b ? NIL : NIL;
}

__attribute__((noinline)) static value generic_decrement(value a) {
    fprintf(stderr, "slow path taken\n");
    exit(1);
    return a;
}

static value tak_boxed(value x, value y, value z);
static fn3 volatile tak_cell = tak_boxed;

static value tak_boxed(value x, value y, value z) {
    int less = (IS_FIXNUM(x) && IS_FIXNUM(y)) ? (int64_t)y < (int64_t)x : generic_less(y, x) != NIL;
    if (!less) return z;
    value x1 = IS_FIXNUM(x) ? x - FIXNUM(1) : generic_decrement(x);
    value y1 = IS_FIXNUM(y) ? y - FIXNUM(1) : generic_decrement(y);
    value z1 = IS_FIXNUM(z) ? z - FIXNUM(1) : generic_decrement(z);
    value a = tak_cell(x1, y, z);
    value b = tak_cell(y1, z, x);
    value c = tak_cell(z1, x, y);
    return tak_cell(a, b, c);
}

static int64_t tak_unboxed(int64_t x, int64_t y, int64_t z) {
    if (!(y < x)) return z;
    return tak_unboxed(tak_unboxed(x - 1, y, z), tak_unboxed(y - 1, z, x), tak_unboxed(z - 1, x, y));
}

static double seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    int64_t x = argc > 1 ? atoll(argv[1]) : 24;
    int64_t y = argc > 2 ? atoll(argv[2]) : 16;
    int64_t z = argc > 3 ? atoll(argv[3]) : 8;
    double start = seconds();
    value boxed = tak_boxed(FIXNUM(x), FIXNUM(y), FIXNUM(z));
    double middle = seconds();
    volatile int64_t unboxed = tak_unboxed(x, y, z);
    double end = seconds();
    printf("TAK-C boxed %lld %.1f ms, unboxed %lld %.1f ms\n", (long long)UNFIX(boxed),
           (middle - start) * 1000.0, (long long)unboxed, (end - middle) * 1000.0);
    return 0;
}
