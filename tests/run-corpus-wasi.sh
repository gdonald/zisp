#!/usr/bin/env bash
#
# Run self-checking corpora in zisp's wasm32-wasi build under Node's WASI.
#
#   ZISP_WASM=zig-out/wasi/zisp.wasm tests/run-corpus-wasi.sh tests/lisp/file-streams.lisp
#   ZISP_WASM=zig-out/wasi/zisp.wasm tests/run-corpus-wasi.sh    # every corpus in tests/wasi-corpora.txt
#
# Every top-level form of each corpus has to evaluate to T. Node preopens
# the repository root, so corpus paths are taken relative to it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${NODE:-node}"

die() { echo "error: $*" >&2; exit 1; }

command -v "$NODE" >/dev/null || die "node not found. Set NODE=/path/to/node."
[[ -n "${ZISP_WASM:-}" && -f "$ZISP_WASM" ]] || die "set ZISP_WASM to the wasm32-wasi zisp"
cd "$ROOT"
if (( $# == 0 )); then
  set -- $(grep -v '^#' tests/wasi-corpora.txt)
fi
status=0
for corpus in "$@"; do
  relative="${corpus#"$ROOT"/}"
  [[ -f "$relative" ]] || die "no corpus at $corpus"
  output="$("$NODE" --no-warnings scripts/run-wasi.mjs "$ZISP_WASM" --batch --quiet \
    --eval "(defvar cl-user::*corpus* \"$relative\")" \
    --load tests/lisp/corpus-check.lisp 2>&1)" || true

  grep -E '^FORM [0-9]+: ' <<<"$output" || true
  tally="$(grep -E '^CORPUS [0-9]+ [0-9]+$' <<<"$output" | tail -n1 || true)"
  if [[ -z "$tally" ]]; then
    tail -n 20 <<<"$output"
    echo "error: $relative did not run to the end" >&2
    status=1
    continue
  fi
  read -r _ forms failures <<<"$tally"
  printf "%s: forms=%d failures=%d\n" "$(basename "$relative")" "$forms" "$failures"
  (( failures == 0 )) || status=1
done

exit "$status"
