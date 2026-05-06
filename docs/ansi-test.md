# ansi-test

The [ansi-test](https://gitlab.common-lisp.net/ansi-test/ansi-test) suite is the
compliance gate for ROADMAP.md. Each phase declares which categories it expects
to make pass, and `tests/run-ansi.sh` is what produces the numbers.

## Running

```sh
zig build ansi-test                         # all categories
ZISP=/path/to/zisp tests/run-ansi.sh        # override binary path
tests/run-ansi.sh cons numbers              # only listed categories
VERBOSE=1 tests/run-ansi.sh                 # show every test
```

`zig build ansi-test` builds zisp first, then invokes the harness with
`ZISP` set to the install path. The script exits non-zero on any failure
so it can gate CI without parsing output.

`zig build -Dansi-tests=true` folds the ansi-test run into the default
build — useful for "run everything before I push" but too slow for
day-to-day iteration.

## Layout

`vendor/ansi-test/` is the upstream suite as a git submodule (GPL — kept
out of our tree on purpose). Initialize with:

```sh
git submodule update --init --recursive
```

The suite is organized into ~22 category subdirectories (`reader/`,
`cons/`, `numbers/`, …). Each category contains many `.lsp` files; each
file contains many `(deftest)` calls.

The framework itself lives in two files at the suite root:

- `rt-package.lsp` — package definition for `:cl-test`
- `rt.lsp` — `deftest`, `do-tests`, `pending-tests`

Per-category runs follow this shape (see `run_category` in
`tests/run-ansi.sh`):

```lisp
(load "gclload1.lsp")                   ; sets up :cl-test
(dolist (f (directory "<cat>/*.lsp"))   ; load each file
  (load f))
(in-package :cl-test)
(let ((failed (length (pending-tests))))
  (format t "~&PASS=~A FAIL=~A~%" pass-count failed))
```

The harness parses the trailing `PASS=N FAIL=M` line.

## Phase mapping

The categories enumerated at the top of `tests/run-ansi.sh` are ordered so
partial runs are meaningful early in the project. Roughly:

| Phase | Categories landed (cumulative)              |
|-------|---------------------------------------------|
| 1     | `reader/`                                    |
| 2     | + `cons/`, `eval-and-compile/`, `data-and-control-flow/` (subset) |
| 3     | + macros, `setf`, `printer/`, full `symbols/` |
| 4     | + strings, arrays, sequences, hash-tables, numbers, characters, packages, pathnames, streams, types-and-classes |
| 6     | + `conditions/`                              |
| 7     | + `objects/`                                 |
| 8     | + `iteration/`                               |

Phase 5 (GC) and Phase 9 (compilation) don't add new categories — they
make the existing suite run without OOM and faster, respectively.

The compliance table in ROADMAP.md tracks file pass rates at each phase
boundary.

## Status

Until Phase 2 lands `--eval` and `load`, the harness can't actually drive
the suite. Today it prints `STUB: would run <cat> (N .lsp files)` per
category to prove the submodule and binary are wired up end-to-end.

The TODO marker in `run_category()` is where the real `--eval` invocation
goes; phase 2.9 wires it in.
