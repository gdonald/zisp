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

# Each category belongs to one implementation stage. The stage summary groups
# the flat per-category numbers so progress reads at a glance.
group_of() {
  case "$1" in
    reader|printer) echo "syntax" ;;
    cons|symbols|eval-and-compile|data-and-control-flow) echo "evaluator" ;;
    strings|arrays|sequences|hash-tables|numbers|characters|packages|pathnames|streams|structures|types-and-classes) echo "data types" ;;
    conditions) echo "conditions" ;;
    objects) echo "objects" ;;
    iteration) echo "iteration" ;;
    *) echo "other" ;;
  esac
}

# Ordered stage labels, used to print the grouped summary in a stable order.
STAGES=(syntax evaluator "data types" conditions objects iteration other)

# Per-category results captured as the run proceeds, for the grouped summary.
result_cats=()
result_pass=()
result_fail=()

record_result() {
  result_cats+=("$1")
  result_pass+=("$2")
  result_fail+=("$3")
}

print_group_summary() {
  echo
  echo "By stage:"
  local group idx cat gp gf saw
  for group in "${STAGES[@]}"; do
    gp=0
    gf=0
    saw=0
    for idx in "${!result_cats[@]}"; do
      cat="${result_cats[$idx]}"
      if [[ "$(group_of "$cat")" == "$group" ]]; then
        gp=$((gp + result_pass[idx]))
        gf=$((gf + result_fail[idx]))
        saw=1
      fi
    done
    if (( saw )); then
      printf "  %-14s PASS=%d FAIL=%d\n" "$group" "$gp" "$gf"
    fi
  done
}

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SUITE" ]] || die "ansi-test suite not found at $SUITE — initialize the submodule"
[[ -x "$ZISP"  ]] || die "zisp binary not found at $ZISP — run 'zig build' first"

if (( $# > 0 )); then
  selected=("$@")
else
  selected=("${CATEGORIES[@]}")
fi

# Eval-mode sweep: load each .lsp under the category in batch mode. If zisp
# emits a do-tests `PASS=N FAIL=M` tally, accumulate those per-test counts;
# otherwise a clean load counts as one pass and a failing load as one fail.
# Once the rt framework loads (after the macro and package layers) the tally
# appears and the counts sharpen without any harness change.
run_category() {
  local cat="$1"
  local dir="$SUITE/$cat"
  [[ -d "$dir" ]] || { echo "skip $cat (no $dir)"; return; }

  local pass=0 fail=0
  while IFS= read -r f; do
    local ran_ok=1
    (cd "$SUITE" && "$ZISP" --batch --load "$f") >/tmp/zisp-eval.$$.out 2>&1 || ran_ok=0
    [[ "$VERBOSE" == "1" ]] && cat /tmp/zisp-eval.$$.out

    # A do-tests run prints a trailing `PASS=N FAIL=M` tally; trust those
    # per-test counts when present. Before the rt framework loads, no tally
    # appears and the whole-file load is the unit (one pass or one fail).
    local tally p m
    tally="$(grep -oE 'PASS=[0-9]+ FAIL=[0-9]+' /tmp/zisp-eval.$$.out | tail -n1 || true)"
    if [[ -n "$tally" ]]; then
      p="${tally#PASS=}"; p="${p%% *}"
      m="${tally#*FAIL=}"
      pass=$((pass + p))
      fail=$((fail + m))
    elif (( ran_ok )); then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.lsp' | sort)
  rm -f /tmp/zisp-eval.$$.out

  printf "%-26s PASS=%d FAIL=%d\n" "$cat" "$pass" "$fail"
  record_result "$cat" "$pass" "$fail"
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
  record_result "$cat" "$pass" "$fail"
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
    print_group_summary
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
    print_group_summary
  else
    echo "Eval summary: no files matched"
  fi
  (( total_fail == 0 )) || exit 1
fi
