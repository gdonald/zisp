#!/usr/bin/env bash
#
# Run cl-bench's Boyer benchmark twice and compare what the collector
# costs each way.
#
#   1. With the nursery, which is how zisp collects by default.
#   2. With `*gc-nursery-bytes*` set to zero, which turns the nursery
#      off: every allocation goes to the tenured space and is reclaimed
#      by marking and sweeping. That is the baseline the generational
#      collector is held against.
#
# The gate is on the first figure against the second: the generational
# run may not be more than LIMIT percent slower. `docs/perf-baseline.md`
# records where the numbers stand.
#
# Options:
#   RUNS=n     boyer iterations per measurement (default 2)
#   REPEATS=n  measurements per configuration, best one kept (default 3)
#   LIMIT=n    percent the generational run may be slower (default 5)
#   ZISP=path  binary to measure

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SOURCE="$ROOT/vendor/cl-bench/files/gabriel.lisp"
DRIVER="$ROOT/tests/lisp/boyer.lisp"
RUNS="${RUNS:-2}"
REPEATS="${REPEATS:-3}"
LIMIT="${LIMIT:-5}"

if [ ! -x "$ZISP" ]; then
  echo "no zisp binary at $ZISP; run: zig build -Doptimize=ReleaseFast" >&2
  exit 1
fi

if [ ! -f "$SOURCE" ]; then
  echo "cl-bench is not vendored: $SOURCE is missing" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
boyer="$work/boyer.lisp"

# The Gabriel file holds a dozen benchmarks in one package. Boyer is the
# first, and the next one's banner ends it. The rest of the file uses
# more of the language than zisp reads today, so taking the slice is
# what lets the benchmark run at all.
awk '/^;;; BOYER/,/^;;; BROWSE/' "$SOURCE" > "$boyer"
for form in '(defun boyer ' '(setup-boyer)'; do
  if ! grep -qF "$form" "$boyer"; then
    echo "the boyer slice of $SOURCE is missing $form" >&2
    exit 1
  fi
done

# One measurement: elapsed microseconds, collector nanoseconds,
# collections, major collections, nursery capacity.
measure() {
  local nursery="$1"
  "$ZISP" --batch --quiet \
    --eval "(defparameter *gc-nursery-bytes* $nursery)" \
    --eval "(defparameter *boyer-runs* $RUNS)" \
    --load "$boyer" \
    --load "$DRIVER" |
    awk '/^BOYER /{print $2, $3, $4, $5, $6}'
}

# The best of several measurements, which is the one least disturbed by
# whatever else the machine was doing.
best() {
  local nursery="$1" line="" chosen="" elapsed=0 lowest=0
  for _ in $(seq "$REPEATS"); do
    line="$(measure "$nursery")"
    if [ -z "$line" ]; then
      echo "boyer produced no figures with nursery $nursery" >&2
      exit 1
    fi
    elapsed="${line%% *}"
    if [ -z "$chosen" ] || [ "$elapsed" -lt "$lowest" ]; then
      chosen="$line"
      lowest="$elapsed"
    fi
  done
  echo "$chosen"
}

default_nursery="$("$ZISP" --batch --quiet \
  --eval '(format t "CAP ~d~%" (getf (room) :nursery-capacity))' |
  awk '/^CAP /{print $2}')"

generational="$(best "$default_nursery")"
baseline="$(best 0)"

report() {
  local label="$1" line="$2"
  set -- $line
  printf '%-16s %8.2f s  %8.2f s  %8d  %8d  %10d\n' \
    "$label" \
    "$(echo "$1" | awk '{print $1 / 1000000}')" \
    "$(echo "$2" | awk '{print $1 / 1000000000}')" \
    "$3" "$4" "$5"
}

echo "boyer x $RUNS, best of $REPEATS"
printf '%-16s %10s  %10s  %8s  %8s  %10s\n' \
  configuration elapsed collector collections major nursery
report generational "$generational"
report "mark and sweep" "$baseline"

generational_us="${generational%% *}"
baseline_us="${baseline%% *}"
regression="$(awk -v a="$generational_us" -v b="$baseline_us" 'BEGIN{printf "%.2f", (a - b) * 100 / b}')"
echo "regression: $regression% (limit $LIMIT%)"

awk -v r="$regression" -v limit="$LIMIT" 'BEGIN{exit (r > limit) ? 1 : 0}' || {
  echo "boyer regressed more than $LIMIT% against the non-generational baseline" >&2
  exit 1
}
