#!/usr/bin/env bash
# Runs everything CI runs, in the same order.
# For the ANSI Common Lisp compliance suite, run tests/run-ansi.sh instead.

set -euo pipefail

echo "==> zig fmt --check"
zig fmt --check src tests build.zig build.zig.zon

echo "==> zig build"
zig build

echo "==> zig build test"
zig build test --summary all "$@"

echo "==> zig build coverage"
zig build coverage

# kcov writes a coverage.json next to the per-file HTML. Pull the headline
# numbers out without depending on jq (CI runners shouldn't need extra tools).
SUMMARY="coverage/test/coverage.json"
REPORT="coverage/test/index.html"
if [[ -f "$SUMMARY" ]]; then
  python3 - "$SUMMARY" "$PWD/$REPORT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"==> coverage: {d['percent_covered']}% "
      f"({d['covered_lines']}/{d['total_lines']} lines)")
print(f"    file://{sys.argv[2]}")
PY
else
  echo "==> coverage: no summary at $SUMMARY"
  exit 1
fi
