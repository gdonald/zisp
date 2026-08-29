#!/usr/bin/env bash
#
# Run one rt-based slice of the ansi-test suite against zisp and report
# the pass rate.
#
#   tests/run-rt-tests.sh format              # report, exit non-zero below the floor
#   tests/run-rt-tests.sh typep subtypep      # several slices
#   ZISP=/path/to/zisp tests/run-rt-tests.sh format
#   FLOOR=95 tests/run-rt-tests.sh typep      # the rate each slice has to clear
#
# A slice is a driver at tests/lisp/ansi-<name>.lisp naming the files it
# wants. `tests/lisp/ansi-rt.lisp` brings the framework up first.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"
PRELUDE="$ROOT/tests/lisp/ansi-rt.lisp"
FLOOR="${FLOOR:-90}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SUITE" ]] || die "ansi-test suite not found at $SUITE. Initialize the submodule."
[[ -x "$ZISP"  ]] || die "zisp binary not found at $ZISP. Run 'zig build' first."
(( $# > 0 )) || die "usage: $(basename "$0") <slice>..."

status=0

for slice in "$@"; do
  driver="$ROOT/tests/lisp/ansi-$slice.lisp"
  [[ -f "$driver" ]] || die "no driver at $driver"

  output="$(cd "$SUITE" && "$ZISP" --batch --load "$PRELUDE" --load "$driver" 2>&1)" || true

  tally="$(grep -E "^ANSI-RT $slice [0-9]+ [0-9]+ [0-9]+ [0-9]+$" <<<"$output" | tail -n1 || true)"
  if [[ -z "$tally" ]]; then
    echo "$output" | tail -n 20
    echo "error: the $slice driver produced no tally" >&2
    status=1
    continue
  fi

  read -r _ _ passed failed loaded files <<<"$tally"
  total=$((passed + failed))
  if (( total == 0 )); then
    echo "error: no $slice tests ran" >&2
    status=1
    continue
  fi

  rate="$(awk -v p="$passed" -v t="$total" 'BEGIN{printf "%.1f", 100*p/t}')"
  printf "%-10s PASS=%d FAIL=%d  files=%d/%d  %s%%\n" \
    "$slice" "$passed" "$failed" "$loaded" "$files" "$rate"

  unloadable="$(grep -E '^ANSI-RT-UNLOADABLE ' <<<"$output" | tail -n1 || true)"
  if [[ -n "$unloadable" && "$unloadable" != "ANSI-RT-UNLOADABLE NIL" ]]; then
    echo "  ${unloadable#ANSI-RT-UNLOADABLE }"
  fi

  awk -v r="$rate" -v f="$FLOOR" 'BEGIN{exit !(r+0 >= f+0)}' || {
    echo "error: $slice pass rate $rate% is below the $FLOOR% floor" >&2
    status=1
  }
done

exit "$status"
