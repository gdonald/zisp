#!/usr/bin/env bash
#
# Load the ansi-test suite's own `gclload1.lsp` the way the suite does,
# compiling rt and the auxiliary files to fasls and loading the universe,
# and check that it got through.
#
#   tests/run-gclload.sh
#   ZISP=/path/to/zisp tests/run-gclload.sh
#
# `gclload1.lsp` writes a fasl next to each file it compiles and reuses
# one it finds newer than its source. It runs in a copy of the suite
# with no fasls in it, so a fasl left by an earlier zisp is not loaded
# and the checkout is not written to.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SUITE" ]] || die "ansi-test suite not found at $SUITE. Initialize the submodule."
[[ -x "$ZISP"  ]] || die "zisp binary not found at $ZISP. Run 'zig build' first."
ZISP="$(cd "$(dirname "$ZISP")" && pwd)/$(basename "$ZISP")"

COPY="$(mktemp -d)"
trap 'rm -rf "$COPY"' EXIT
rsync -a --exclude '*.zfasl' --exclude '.git' "$SUITE/" "$COPY/"

output="$(cd "$COPY" && "$ZISP" --batch --load gclload1.lsp --eval \
  '(format t "~&GCLLOAD ~A ~A ~A~%" (not (null (find-package :cl-test)))
            (fboundp (quote cl-test::signals-error))
            (boundp (quote cl-test::*universe*)))' 2>&1)" || true

if grep -q '^GCLLOAD T T T$' <<<"$output"; then
  echo "gclload1.lsp loaded: cl-test, signals-error and the universe are defined"
else
  echo "$output" | tail -n 20
  die "gclload1.lsp did not load"
fi
