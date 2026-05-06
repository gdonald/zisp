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
