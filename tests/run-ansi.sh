#!/usr/bin/env bash
#
# Run the ANSI Common Lisp test suite against zisp.
#
# Two modes:
#   1. Reader-only: parse every .lsp without evaluating, report
#      per-category PASS/FAIL counts. Measures the parse rate before the
#      evaluator exists.
#         tests/run-ansi.sh --read-only            # all categories
#         tests/run-ansi.sh --read-only reader     # one category
#
#   2. Full eval: load every .lsp under a category and count how many load
#      and run to completion without error.
#         tests/run-ansi.sh                        # all categories
#         tests/run-ansi.sh cons numbers           # selected categories
#      The rt-based (do-tests) play depends on the macro and package layers;
#      until those land, this sweep measures the load rate, which is the
#      meaningful pre-rt signal (analogous to the reader-only parse rate).
#
# Common options:
#   VERBOSE=1 tests/run-ansi.sh ...               # show per-file lines
#   ZISP=/path/to/zisp tests/run-ansi.sh ...      # override binary path
#
# Output:
#   Per-category pass/fail counts plus an overall percentage.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"
VERBOSE="${VERBOSE:-0}"

READ_ONLY=0
if [[ "${1:-}" == "--read-only" ]]; then
  READ_ONLY=1
  shift
fi

# Categories are subdirectories of vendor/ansi-test. Each contains many .lsp
# files; running a category means loading all of them and then (do-tests).
# Ordered so partial runs are meaningful early.
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
# Eval-mode sweep: load each .lsp under the category in batch mode and count
# clean loads. Once the rt framework loads (after the macro and package
# layers), this becomes a (do-tests) run that parses a trailing
# `PASS=N FAIL=M` line printed by zisp; the parsing below already expects that
# shape, so only the per-file inner loop changes.
run_category() {
  local cat="$1"
  local dir="$SUITE/$cat"
  [[ -d "$dir" ]] || { echo "skip $cat (no $dir)"; return; }

  local pass=0 fail=0
  while IFS= read -r f; do
    if (cd "$SUITE" && "$ZISP" --batch --load "$f") >/tmp/zisp-eval.$$.out 2>&1; then
      pass=$((pass + 1))
      [[ "$VERBOSE" == "1" ]] && cat /tmp/zisp-eval.$$.out
    else
      fail=$((fail + 1))
      [[ "$VERBOSE" == "1" ]] && cat /tmp/zisp-eval.$$.out
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.lsp' | sort)
  rm -f /tmp/zisp-eval.$$.out

  printf "%-26s PASS=%d FAIL=%d\n" "$cat" "$pass" "$fail"
  total_pass=$((total_pass + pass))
  total_fail=$((total_fail + fail))
}

# Reader-only run: each .lsp gets a single zisp --read-only invocation. The
# binary prints `OK ... forms=N` on success and `FAIL ... line:col` on the
# first parse error. Aggregated counts feed the overall parse-rate number.
run_category_read_only() {
  local cat="$1"
  local dir="$SUITE/$cat"
  [[ -d "$dir" ]] || { echo "skip $cat (no $dir)"; return; }

  local pass=0 fail=0
  while IFS= read -r f; do
    if "$ZISP" --read-only "$f" >/tmp/zisp-readonly.$$.out 2>&1; then
      pass=$((pass + 1))
      [[ "$VERBOSE" == "1" ]] && cat /tmp/zisp-readonly.$$.out
    else
      fail=$((fail + 1))
      cat /tmp/zisp-readonly.$$.out
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.lsp' | sort)
  rm -f /tmp/zisp-readonly.$$.out
  printf "%-26s PASS=%d FAIL=%d\n" "$cat" "$pass" "$fail"
  total_pass=$((total_pass + pass))
  total_fail=$((total_fail + fail))
}

total_pass=0
total_fail=0

if (( READ_ONLY )); then
  for cat in "${selected[@]}"; do
    run_category_read_only "$cat"
  done
  echo
  total=$((total_pass + total_fail))
  if (( total > 0 )); then
    pct=$(awk -v p="$total_pass" -v t="$total" 'BEGIN{printf "%.1f", 100*p/t}')
    echo "Reader-only summary: $total_pass / $total ($pct%) parsed"
  else
    echo "Reader-only summary: no files matched"
  fi
  (( total_fail == 0 )) || exit 1
else
  for cat in "${selected[@]}"; do
    run_category "$cat"
  done
  echo
  total=$((total_pass + total_fail))
  if (( total > 0 )); then
    pct=$(awk -v p="$total_pass" -v t="$total" 'BEGIN{printf "%.1f", 100*p/t}')
    echo "Eval summary: $total_pass / $total ($pct%) loaded and ran"
  else
    echo "Eval summary: no files matched"
  fi
  (( total_fail == 0 )) || exit 1
fi
