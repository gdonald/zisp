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

Until `--eval` and `load` exist, the harness can't actually drive the
suite. Today it prints `STUB: would run <cat> (N .lsp files)` per category
to prove the submodule and binary are wired up end-to-end.

The TODO marker in `run_category()` is where the real `--eval` invocation
goes.
