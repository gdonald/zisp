#!/usr/bin/env bash
#
# Save an image of a session that defines one function, then time
# `zisp --image demo.zimg --eval '(my-fn)'` from process start to exit,
# best of several runs, and fail when that is over the limit. Also check
# that saving the same session twice gives the same bytes.
#
#   ZISP=/path/to/zisp tests/run-image-cold-start.sh
#   LIMIT_MS=50 RUNS=10 tests/run-image-cold-start.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZISP="${ZISP:-$ROOT/zig-out/bin/zisp}"
LIMIT_MS="${LIMIT_MS:-50}"
RUNS="${RUNS:-10}"
DIR="$ROOT/.zig-cache/image-cold-start"
mkdir -p "$DIR"

save() {
  "$ZISP" --batch --quiet --eval '(defun my-fn () (list :hello (* 6 7)))' \
    --eval "(ext:save-image \"$DIR/demo.zimg\")" >/dev/null
}

save
cp "$DIR/demo.zimg" "$DIR/first.zimg"
save
cmp "$DIR/first.zimg" "$DIR/demo.zimg"
echo "IMAGE-COLD-START the same session saved twice gives the same bytes"

best=""
for _ in $(seq "$RUNS"); do
  ms="$(perl -MTime::HiRes=time -e 'open my $out, ">&", \*STDOUT; open STDOUT, ">", "/dev/null";
    $s = time; system(@ARGV) == 0 or exit 1; printf $out "%.1f", (time - $s) * 1000' \
    "$ZISP" --image "$DIR/demo.zimg" --batch --quiet --eval '(my-fn)')"
  if [[ -z "$best" ]] || awk -v a="$ms" -v b="$best" 'BEGIN{exit !(a < b)}'; then best="$ms"; fi
done
echo "IMAGE-COLD-START $best ms, best of $RUNS, limit $LIMIT_MS ms"
awk -v a="$best" -v l="$LIMIT_MS" 'BEGIN{exit !(a <= l)}' || {
  echo "error: starting from the image took $best ms, over $LIMIT_MS ms" >&2
  exit 1
}
