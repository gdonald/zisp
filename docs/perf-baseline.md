# Performance baseline

Numbers the collector is held to, and where they stand. Each one names
the command that produces it, so a figure that drifts can be re-measured
rather than argued about.

Everything here is measured on a `ReleaseFast` build. A `Debug` build
runs the interpreter about ten times slower than the collector, which
flatters every ratio on this page.

    zig build -Doptimize=ReleaseFast

## Collector share of a run

**Target: the collector stops the program for no more than 5% of the
time the program itself gets.**

    zig build gc-pause -Doptimize=ReleaseFast

`tests/lisp/gc-pause.lisp` keeps a working set of five thousand cells and
replaces it over and over for sixty seconds, so every collection has both
survivors to keep and garbage to reclaim. It fails if the share is above
`*gc-pause-limit-percent*`, and prints its figures on a `GC-PAUSE` line:
microseconds in the collector, microseconds in the program, the two
together, and how many collections there were.

| Measured on | Collector | Mutator | Share | Collections | Mean pause | Longest pause |
| --- | --- | --- | --- | --- | --- | --- |
| macOS, aarch64, 2026-08-25, cards charged | 2.079 s | 57.922 s | 3.59% | 10919 (1 major) | 190 us | 620 us |
| macOS, aarch64, 2026-08-25 | 2.322 s | 57.679 s | 4.03% | 10746 (1 major) | 216 us | 2.57 ms |
| macOS, aarch64, 2026-08-24 | 3.216 s | 56.786 s | 5.66% | 10824 | 297 us | 1.35 ms |
| CI Linux runner | | | | | | |

The figure first came down when collections stopped walking the whole
live heap. Before the minor and major collections were told apart, every
one of them marked everything reachable from the roots, so a pause cost
what the program had kept rather than what it had just made. A minor
collection now reads the dirty cards and the roots and stops at the
tenured space, and the mean pause fell from 297 us to 216 us.

It came down again when the interval between young collections was
charged for what the last one read from the cards, which is what the
Boyer gate below asked for. The mean pause is 190 us and the longest is
the one major collection in the run.

Pauses are bucketed by order of magnitude and reported by `(room)` as
`:gc-pauses`, longest bucket last: under a microsecond, under ten, and so
on up to everything a second and over. The run above put all 10921 of
its collections in the 100 us to 1 ms bucket.

## Long-running allocation

    zig build gc-stress -Doptimize=ReleaseFast

`tests/lisp/gc-stress.lisp` hands out cells for a hundred million
iterations twice over, keeping every two hundredth cell on the first pass
and every hundredth on the second.

| Measured on | Wall clock | Retained | Tenured | Peak RSS | Collections |
| --- | --- | --- | --- | --- | --- |
| macOS, aarch64, 2026-08-24 | 114 s | 500000 then 1000000 cells | 16.0 MB then 32.0 MB | ~120 MB | 1298 |

Two facts the run is there to establish: 3.2 GB of garbage passed through
a heap that never grew past what was retained, and twice the retained
cells cost exactly twice the tenured space.

## Boyer against a collector without generations

**Target: the generational collector is no more than 5% slower than the
same interpreter collecting by marking and sweeping alone.**

    zig build boyer -Doptimize=ReleaseFast

`tests/run-boyer.sh` runs cl-bench's Boyer benchmark twice: once as zisp
collects by default, and once with `*gc-nursery-bytes*` set to zero,
which turns the nursery off so every allocation goes to the tenured
space and is reclaimed by marking and sweeping. Boyer is a rewrite
engine that conses heavily and keeps its lemmas on symbol plists, so the
run has both a live set to walk and a stream of garbage to reclaim. The
benchmark comes from `vendor/cl-bench`, and the driver that times it is
`tests/lisp/boyer.lisp`.

Each configuration is measured several times and the best is kept, since
what a slower measurement records is the machine rather than the
collector. `RUNS`, `REPEATS` and `LIMIT` set the iterations per
measurement, the measurements per configuration, and the percentage the
gate allows.

| Measured on | Generational | Mark and sweep | Regression | Collections | Major |
| --- | --- | --- | --- | --- | --- |
| macOS, aarch64, 2026-08-25 | 5.31 s | 5.22 s | 1.69% | 1013 | 321 |
| CI Linux runner | | | | | |

Two iterations, best of four. The first time this gate ran it read 30%.
A young collection that cannot move leaves its survivors in the nursery,
so a tenured object pointing at one keeps its card dirty, and Boyer made
enough of those pointers that every collection re-read most of the
tenured cells before it reached anything of its own.
The interval between young collections is now charged for what the last
one read from the cards, and what the nursery cannot hold spills to the
tenured space, where a major collection reclaims it.
