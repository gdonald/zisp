#!/usr/bin/env bash
#
# Run the whole ansi-test suite against zisp the way the suite's own
# doit.lsp runs it: init.lsp, gclload1.lsp, gclload2.lsp, then every test.
#
#   tests/run-ansi-suite.sh
#   ZISP=/path/to/zisp tests/run-ansi-suite.sh
#   MODE=compile tests/run-ansi-suite.sh     # every test runs as bytecode
#   VERBOSE=1 tests/run-ansi-suite.sh        # show the suite's output
#   LOG=/path/to/run.log tests/run-ansi-suite.sh   # keep the suite's output
#
# The suite writes a fasl next to each file it compiles, so it runs in a
# copy with no fasls in it, and the checkout is not written to. The run
# fails when a test fails that tests/ansi-failures.txt does not name, and
# when a test it names passes. MODE=compile reads
# tests/ansi-failures-compile.txt instead.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
SUITE="$ROOT/vendor/ansi-test"
DRIVER="$ROOT/tests/lisp/ansi-suite.lisp"
MODE="${MODE:-interpret}"
if [[ "$MODE" == "compile" ]]; then
  FAILURES="$ROOT/tests/ansi-failures-compile.txt"
else
  FAILURES="$ROOT/tests/ansi-failures.txt"
fi
VERBOSE="${VERBOSE:-0}"
LOG="${LOG:-}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SUITE" ]] || die "ansi-test suite not found at $SUITE. Initialize the submodule."
[[ -x "$ZISP"  ]] || die "zisp binary not found at $ZISP. Run 'zig build' first."
ZISP="$(cd "$(dirname "$ZISP")" && pwd)/$(basename "$ZISP")"

COPY="$(mktemp -d)"
trap 'rm -rf "$COPY"' EXIT
rsync -a --exclude '*.zfasl' --exclude '.git' "$SUITE/" "$COPY/"
LOG="${LOG:-$COPY/run.log}"

expected=()
if [[ -f "$FAILURES" ]]; then
  expected=(--eval "(setf cl-user::*ansi-expected-failures* \"$FAILURES\")")
fi

status=0
(cd "$COPY" && "$ZISP" --batch --eval "(setf ext:*evaluator-mode* :$MODE)" \
  "${expected[@]}" --load "$DRIVER") >"$LOG" 2>&1 || status=$?
output="$(tr -d '\000' <"$LOG")"
[[ "$VERBOSE" == "1" ]] && echo "$output"

if grep -q '^ANSI-LOAD-ERROR' <<<"$output"; then
  grep '^ANSI-LOAD-ERROR' <<<"$output"
  die "the suite did not load"
fi

tally="$(grep -E '^ANSI-SUITE [0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+$' <<<"$output" | tail -n1 || true)"
if [[ -z "$tally" ]]; then
  echo "$output" | tail -n 20
  die "the suite stopped before it reported (exit $status)"
fi
read -r _ registered passed failed unexpected_failures unexpected_successes <<<"$tally"
ran=$((passed + failed))
# rt's summary, leaving out its list of every failure: the unexpected
# failures and successes are what decide the run.
awk '/failures? with .* unexpected/ { show = 1 }
     /^Failures:/ { skip = 1; next }
     skip && /^  / { next }
     { skip = 0 }
     show && !/^ANSI-SUITE/ { print }' <<<"$output"
pct=$(awk -v p="$passed" -v t="$ran" 'BEGIN{ if (t > 0) printf "%.1f", 100*p/t; else print "0.0" }')
echo "ansi-test ($MODE): $passed / $ran ($pct%) tests passed, $((registered - ran)) of $registered switched off by a note"
echo "unexpected failures: $unexpected_failures, unexpected successes: $unexpected_successes"
exit "$status"
