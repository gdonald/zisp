#!/usr/bin/env bash
#
# Check that a self-checking corpus holds in SBCL too, so its expected
# values are SBCL's and not only zisp's.
#
#   tests/run-corpus-sbcl.sh tests/lisp/unwind-protect-corpus.lisp
#   SBCL=/path/to/sbcl tests/run-corpus-sbcl.sh <corpus>...
#
# Every top-level form of each corpus has to evaluate to T. SBCL runs
# with its debugger on, since a corpus can depend on `*debugger-hook*`,
# and with no input, so a form that enters the debugger ends the run.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SBCL="${SBCL:-sbcl}"

die() { echo "error: $*" >&2; exit 1; }

command -v "$SBCL" >/dev/null || die "sbcl not found. Set SBCL=/path/to/sbcl."
(( $# > 0 )) || die "usage: $(basename "$0") <corpus>..."

errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT

status=0
for corpus in "$@"; do
  [[ -f "$corpus" ]] || die "no corpus at $corpus"
  path="$(cd "$(dirname "$corpus")" && pwd)/$(basename "$corpus")"
  output="$("$SBCL" --noinform \
    --eval "(defvar cl-user::*corpus* \"$path\")" \
    --load "$ROOT/tests/lisp/sbcl-corpus-check.lisp" \
    --eval '(sb-ext:exit)' </dev/null 2>"$errors")" || true

  grep -E '^FORM [0-9]+: ' <<<"$output" || true
  tally="$(grep -E '^SBCL-CORPUS [0-9]+ [0-9]+$' <<<"$output" | tail -n1 || true)"
  if [[ -z "$tally" ]]; then
    grep -v '^;' "$errors" | tail -n 20
    echo "error: $corpus did not run to the end in SBCL" >&2
    status=1
    continue
  fi
  read -r _ forms failures <<<"$tally"
  printf "%s: forms=%d failures=%d\n" "$(basename "$corpus")" "$forms" "$failures"
  (( failures == 0 )) || status=1
done

exit "$status"
