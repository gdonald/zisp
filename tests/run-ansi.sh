#!/usr/bin/env bash
#
# Run the ANSI Common Lisp test suite against zisp.
#
# STUB: this script is wired up but cannot run yet. It needs:
#   1. vendor/ansi-test/ submodule initialized
#   2. zig-out/bin/zisp built and able to (load ...) a file
#      (Phase 2 of ROADMAP.md at the earliest)
#
# Usage:
#   tests/run-ansi.sh                # run all categories
#   tests/run-ansi.sh cons numbers   # run only listed categories
#   VERBOSE=1 tests/run-ansi.sh      # show every test, not just summary
#   ZISP=/path/to/zisp tests/run-ansi.sh   # override binary path
#
# Output:
#   Per-category pass/fail counts plus an overall percentage. The percentage
#   is the number tracked against the compliance table in ROADMAP.md.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"
VERBOSE="${VERBOSE:-0}"

# Categories are subdirectories of vendor/ansi-test. Each contains many .lsp
# files; running a category means loading all of them and then (do-tests).
# Order roughly tracks ROADMAP phases so partial runs are meaningful early.
CATEGORIES=(
  reader
  printer
  cons
  symbols
  eval-and-compile
  data-and-control-flow
  strings
  arrays
  sequences
  hash-tables
  numbers
  characters
  packages
  pathnames
  streams
  structures
  types-and-classes
  conditions
  objects
  iteration
)

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SUITE" ]] || die "ansi-test suite not found at $SUITE — initialize the submodule"
[[ -x "$ZISP"  ]] || die "zisp binary not found at $ZISP — run 'zig build' first"

if (( $# > 0 )); then
  selected=("$@")
else
  selected=("${CATEGORIES[@]}")
fi

# Per-category: load gclload (which sets up the rt framework), load every .lsp
# in the category directory, then (do-tests) and exit. The full upstream play
# is just (load "gclload.lsp") which loads everything — useful for a final run,
# not for per-phase tracking.
run_category() {
  local cat="$1"
  local dir="$SUITE/$cat"
  [[ -d "$dir" ]] || { echo "skip $cat (no $dir)"; return; }

  # TODO: replace with real invocation once zisp can (load ...) and (do-tests).
  # Expected shape (run from $SUITE so relative paths in the suite resolve):
  #
  #   cd "$SUITE"
  #   "$ZISP" --batch \
  #     --eval "(load \"gclload1.lsp\")" \
  #     --eval "(dolist (f (directory \"$cat/*.lsp\")) (load f))" \
  #     --eval "(in-package :cl-test)" \
  #     --eval "(let ((r (do-tests))) (format t \"~&PASS=~A FAIL=~A~%\" (length (pending-tests)) ...))" \
  #     --eval "(quit)"
  #
  # Then parse the trailing PASS=N FAIL=M line.
  local count
  count=$(find "$dir" -maxdepth 1 -name '*.lsp' | wc -l | tr -d ' ')
  echo "STUB: would run $cat ($count .lsp files)"
}

total_pass=0
total_fail=0

for cat in "${selected[@]}"; do
  run_category "$cat"
  # TODO: parse output, accumulate into total_pass / total_fail.
done

# TODO: print summary table once parsing is in place.
echo
echo "Summary (stub): $total_pass passed, $total_fail failed"
