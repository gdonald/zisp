#!/usr/bin/env bash
# Run the Zig unit test suite.
# For the ANSI Common Lisp compliance suite, run tests/run-ansi.sh instead.

set -euo pipefail
exec zig build test --summary all "$@"
