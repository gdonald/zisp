#!/usr/bin/env bash
#
# Compare zisp's `subtypep` with SBCL's on every call the ansi-test
# `subtypep` files make.
#
#   tests/run-subtypep-sbcl-diff.sh
#   ZISP=/path/to/zisp SBCL=/path/to/sbcl tests/run-subtypep-sbcl-diff.sh
#   VERBOSE=1 tests/run-subtypep-sbcl-diff.sh     # list each mismatch
#
# SBCL runs the files with every call recorded, then zisp answers the same
# calls. A call zisp leaves undecided where SBCL decides it is a
# violation, and any violation fails the run. A call both decide
# differently is a disagreement, which comes from what each upgrades array
# element types and complex part types to and how wide a fixnum is, and is
# counted rather than failed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SBCL="${SBCL:-sbcl}"
SUITE="$ROOT/vendor/ansi-test"
VERBOSE="${VERBOSE:-0}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SUITE" ]] || die "ansi-test suite not found at $SUITE. Initialize the submodule."
[[ -x "$ZISP"  ]] || die "zisp binary not found at $ZISP. Run 'zig build' first."
command -v "$SBCL" >/dev/null || die "sbcl not found. Set SBCL=/path/to/sbcl."
ZISP="$(cd "$(dirname "$ZISP")" && pwd)/$(basename "$ZISP")"

calls="$(mktemp)"
trap 'rm -f "$calls"' EXIT

(cd "$SUITE" && SUBTYPEP_SBCL_OUT="$calls" "$SBCL" --noinform --non-interactive \
  --load "$ROOT/tests/lisp/subtypep-sbcl-log.lisp" >/dev/null 2>&1) ||
  die "sbcl did not finish recording the calls"

output="$(cd "$SUITE" && "$ZISP" --batch \
  --load "$ROOT/tests/lisp/ansi-rt.lisp" \
  --eval "(defparameter cl-test::*sbcl-calls-file* \"$calls\")" \
  --load "$ROOT/tests/lisp/subtypep-sbcl-diff.lisp" 2>&1)" || true

if [[ "$VERBOSE" == "1" ]]; then
  grep -E '^(VIOLATION|DISAGREEMENT) ' <<<"$output" || true
else
  grep -E '^VIOLATION ' <<<"$output" || true
fi

tally="$(grep -E '^SUBTYPEP-SBCL [0-9]+ [0-9]+ [0-9]+$' <<<"$output" | tail -n1 || true)"
if [[ -z "$tally" ]]; then
  echo "$output" | tail -n 20
  die "the comparison produced no tally"
fi

read -r _ total violations disagreements <<<"$tally"
printf "subtypep vs SBCL: calls=%d violations=%d disagreements=%d\n" \
  "$total" "$violations" "$disagreements"

(( total > 0 )) || die "no calls were compared"
(( violations == 0 )) || die "zisp left $violations calls undecided that SBCL decides"
