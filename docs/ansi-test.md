# ansi-test

The [ansi-test](https://gitlab.common-lisp.net/ansi-test/ansi-test) suite is the
compliance gate for zisp. `tests/run-ansi.sh` runs it and produces the numbers.

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

The slices that need rt and the auxiliary files the suite compiles
before loading have a harness of their own:

```sh
tests/run-rt-tests.sh format                # pass rate, non-zero below the floor
tests/run-rt-tests.sh typep subtypep        # several slices
FLOOR=95 tests/run-rt-tests.sh typep        # raise the floor
```

A slice is a driver at `tests/lisp/ansi-<name>.lisp` naming the files it
wants. `tests/lisp/ansi-rt.lisp` brings the framework up ahead of it.

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

The categories enumerated at the top of `tests/run-ansi.sh` are ordered so
partial runs are meaningful early in the project.

## Status

The harness drives the suite in two modes. `--read-only` parses every
`.lsp` without evaluating and reports the parse rate. The default mode
loads each file and counts the ones that load and run to completion; when
a file emits a `do-tests` tally the harness accumulates those per-test
counts instead.

The framework itself runs: `rt-package.lsp` defines the package, `rt.lsp`
defines `deftest`, `do-tests`, and the entry structure, and a test defined
with `deftest` is reported by `(do-tests)`.

Loading a category's own test files goes through `gclload1.lsp`, which
loads `universe.lsp`. That file builds a generic function with `defgeneric`
and asks for `find-class` and `find-method`, so the whole-suite driver
waits on the object system.
