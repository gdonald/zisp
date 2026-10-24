#!/usr/bin/env bash
#
# Build zisp once for each way of dispatching bytecode and time the
# compiled Gabriel benchmarks on each build.
#
#   tests/run-dispatch-bench.sh                 # loop, threaded and tail
#   tests/run-dispatch-bench.sh loop threaded   # the ones named
#
# Each build goes to its own prefix under .zig-cache, as ReleaseFast.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/vendor/cl-bench/files/gabriel.lisp"
DRIVER="$ROOT/tests/lisp/dispatch-bench.lisp"
KINDS=("$@")
(( ${#KINDS[@]} > 0 )) || KINDS=(loop threaded tail)

for kind in "${KINDS[@]}"; do
  prefix="$ROOT/.zig-cache/dispatch-$kind"
  (cd "$ROOT" && zig build -Doptimize=ReleaseFast -Ddispatch="$kind" -p "$prefix")
  echo "== $kind"
  "$prefix/bin/zisp" --batch --quiet \
    --eval "(setf ext:*evaluator-mode* :compile)" \
    --load "$SOURCE" --load "$DRIVER" | grep '^DISPATCH-BENCH' | sed 's/^DISPATCH-BENCH //'
done
