#!/usr/bin/env bash
#
# Time TAK three ways: compiled to bytecode by zisp, and as C built with
# `zig cc -O2`, once with tagged values checked on every operation and
# once with plain integers. `docs/codegen-backend.md` records the
# figures and how long `zig cc` took to build the C.
#
#   ZISP=/path/to/zisp tests/run-codegen-tak.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
OUT="$ROOT/.zig-cache/codegen-tak"
mkdir -p "$OUT"

start=$(perl -MTime::HiRes=time -e 'print time')
zig cc -O2 -o "$OUT/tak" "$ROOT/tests/codegen/tak.c"
end=$(perl -MTime::HiRes=time -e 'print time')
awk -v s="$start" -v e="$end" 'BEGIN{printf "ZIG-CC build %.0f ms\n", (e-s)*1000}'

"$OUT/tak"
"$ZISP" --batch --quiet --load "$ROOT/tests/codegen/tak.lisp" | grep '^TAK-BYTECODE'
