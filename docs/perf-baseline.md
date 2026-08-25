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
survivors to keep and garbage to reclaim. It reports through `(room)` and
fails if the share is above `*gc-pause-limit-percent*`.

| Measured on | Collector | Mutator | Share | Collections | Mean pause | Longest pause |
| --- | --- | --- | --- | --- | --- | --- |
| macOS, aarch64, 2026-08-25 | 2.322 s | 57.679 s | 4.03% | 10746 (1 major) | 216 us | 2.57 ms |
| macOS, aarch64, 2026-08-24 | 3.216 s | 56.786 s | 5.66% | 10824 | 297 us | 1.35 ms |
| CI Linux runner | | | | | | |

The figure came down when collections stopped walking the whole live
heap. Before the minor and major collections were told apart, every one
of them marked everything reachable from the roots, so a pause cost what
the program had kept rather than what it had just made. A minor
collection now reads the dirty cards and the roots and stops at the
tenured space, and the mean pause fell from 297 us to 216 us. The
longest pause is the one major collection in the run.

Pauses are bucketed by order of magnitude and reported by `(room)` as
`:gc-pauses`, longest bucket last: under a microsecond, under ten, and so
on up to everything a second and over. The run above put 10744
collections in the 100 us to 1 ms bucket and 2 in the 1 ms to 10 ms
bucket.

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
