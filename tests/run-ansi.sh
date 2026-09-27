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
#   2. Full eval: bring up the rt framework, load every .lsp under a
#      category, run its tests, and count how many pass.
#         tests/run-ansi.sh                        # all categories
#         tests/run-ansi.sh cons numbers           # selected categories
#
# Common options:
#   VERBOSE=1 tests/run-ansi.sh ...               # show the rt output
#   ZISP=/path/to/zisp tests/run-ansi.sh ...      # override binary path
#
# Output:
#   Per-category pass/fail counts plus an overall percentage.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"
PRELUDE="$ROOT/tests/lisp/ansi-rt.lisp"
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

# Eval-mode sweep: one zisp per category brings the rt framework up with
# tests/lisp/ansi-rt.lisp, loads every .lsp under the category, runs the
# tests they registered, and prints an `ANSI-RT` tally of passed and
# failed tests. A file that will not load counts its tests as failed.
run_category() {
  local cat="$1"
  local dir="$SUITE/$cat"
  [[ -d "$dir" ]] || { echo "skip $cat (no $dir)"; return; }

  local files=()
  while IFS= read -r f; do
    files+=("\"$cat/$(basename "$f")\"")
  done < <(find "$dir" -maxdepth 1 -name '*.lsp' | sort)

  local output
  output="$(cd "$SUITE" && "$ZISP" --batch \
    --load "$PRELUDE" \
    --eval "(in-package :cl-test)" \
    --eval "(run-ansi-files \"$cat\" (list ${files[*]}))" 2>&1)" || true
  [[ "$VERBOSE" == "1" ]] && echo "$output"

  local pass=0 fail=0 tally
  tally="$(grep -E "^ANSI-RT $cat [0-9]+ [0-9]+ [0-9]+ [0-9]+$" <<<"$output" | tail -n1 || true)"
  if [[ -n "$tally" ]]; then
    read -r _ _ pass fail _ _ <<<"$tally"
  else
    fail=${#files[@]}
  fi

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
    echo "Eval summary: $total_pass / $total ($pct%) tests passed"
    print_group_summary
  else
    echo "Eval summary: no files matched"
  fi
  (( total_fail == 0 )) || exit 1
fi
