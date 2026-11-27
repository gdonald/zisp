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
#   2. Full eval: load each category the way the suite's gclload2.lsp
#      does, gclload1.lsp and then the category's load.lsp, run its
#      tests, and count how many pass. tests/run-ansi-suite.sh runs the
#      whole suite in one session instead.
#         tests/run-ansi.sh                        # all categories
#         tests/run-ansi.sh cons numbers           # selected categories
#
# Common options:
#   VERBOSE=1 tests/run-ansi.sh ...               # show the rt output
#   ZISP=/path/to/zisp tests/run-ansi.sh ...      # override binary path
#   MODE=compile tests/run-ansi.sh ...            # every test runs as bytecode
#
# Output:
#   Per-category pass/fail counts plus an overall percentage.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"
DRIVER="$ROOT/tests/lisp/ansi-category.lisp"
VERBOSE="${VERBOSE:-0}"
MODE="${MODE:-interpret}"

READ_ONLY=0
if [[ "${1:-}" == "--read-only" ]]; then
  READ_ONLY=1
  shift
fi

# The categories the suite's gclload2.lsp loads, in its order.
CATEGORIES=(
  symbols
  eval-and-compile
  data-and-control-flow
  iteration
  objects
  conditions
  cons
  arrays
  hash-tables
  packages
  numbers
  sequences
  structures
  types-and-classes
  strings
  characters
  pathnames
  files
  streams
  printer
  reader
  system-construction
  environment
  misc
)

# Each category belongs to one implementation stage. The stage summary groups
# the flat per-category numbers so progress reads at a glance.
group_of() {
  case "$1" in
    reader|printer) echo "syntax" ;;
    cons|symbols|packages|eval-and-compile|data-and-control-flow|environment) echo "evaluator" ;;
    strings|arrays|sequences|hash-tables|numbers|characters|structures|types-and-classes) echo "data types" ;;
    pathnames|files|streams) echo "files and streams" ;;
    conditions) echo "conditions" ;;
    objects) echo "objects" ;;
    iteration) echo "iteration" ;;
    system-construction|misc) echo "the rest" ;;
    *) echo "other" ;;
  esac
}

# Ordered stage labels, used to print the grouped summary in a stable order.
STAGES=(syntax evaluator "data types" "files and streams" conditions objects iteration "the rest" other)

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
# Each slice runs from inside the suite, so a relative path has to be
# made absolute first.
ZISP="$(cd "$(dirname "$ZISP")" && pwd)/$(basename "$ZISP")"

if (( ! READ_ONLY )); then
  COPY="$(mktemp -d)"
  trap 'rm -rf "$COPY"' EXIT
  rsync -a --exclude '*.zfasl' --exclude '.git' "$SUITE/" "$COPY/"
fi

if (( $# > 0 )); then
  selected=("$@")
else
  selected=("${CATEGORIES[@]}")
fi

# Eval-mode sweep: one zisp per category, in a copy of the suite with no
# fasls in it, loads the category through tests/lisp/ansi-category.lisp,
# runs the tests it registered, and prints an `ANSI-RT` tally of passed
# and failed tests. A category that does not load or does not report
# counts as one failure, and what it printed last is shown.
run_category() {
  local cat="$1"
  [[ -f "$COPY/$cat/load.lsp" ]] || { echo "skip $cat (no $cat/load.lsp)"; return; }

  local output
  output="$(cd "$COPY" && "$ZISP" --batch \
    --eval "(setf ext:*evaluator-mode* :$MODE)" \
    --eval "(defvar cl-user::*ansi-category* \"$cat\")" \
    --load "$DRIVER" 2>&1 | tr -d '\000')" || true
  [[ "$VERBOSE" == "1" ]] && echo "$output"

  local pass=0 fail=0 tally
  tally="$(grep -E "^ANSI-RT $cat [0-9]+ [0-9]+$" <<<"$output" | tail -n1 || true)"
  if [[ -n "$tally" ]]; then
    read -r _ _ pass fail <<<"$tally"
  else
    fail=1
    grep '^ANSI-LOAD-ERROR' <<<"$output" || tail -n 5 <<<"$output"
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
