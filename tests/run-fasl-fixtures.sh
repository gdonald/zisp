#!/usr/bin/env bash
#
# Write the cross-architecture fasl fixtures: `tests/fasl/cross.lisp`
# compiled by an aarch64 zisp and by an x86_64 one, which on an Apple
# silicon Mac runs under Rosetta. The two have to come out the same
# bytes. Run this whenever the instruction set or the fasl format
# changes, since the fixtures are refused with `fasl-version-error`
# after either.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/tests/fasl/cross.lisp"
cd "$ROOT"

# `arch` names the two the way Apple does.
for arch in aarch64 x86_64; do
  prefix="$ROOT/.zig-cache/fasl-$arch"
  zig build -Dtarget="$arch-macos" -Doptimize=ReleaseSafe -p "$prefix"
  apple_name="$arch"
  [[ "$arch" == aarch64 ]] && apple_name=arm64
  arch -"$apple_name" "$prefix/bin/zisp" --batch --quiet \
    --eval "(compile-file \"$SOURCE\" :output-file \"$ROOT/tests/fasl/cross-$arch.zfasl\")" >/dev/null
done

cmp "$ROOT/tests/fasl/cross-aarch64.zfasl" "$ROOT/tests/fasl/cross-x86_64.zfasl"
echo "cross-aarch64.zfasl and cross-x86_64.zfasl are the same bytes"
