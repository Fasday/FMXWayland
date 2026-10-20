#!/bin/bash
# Run last on a private Xvfb: verifies a live screen/work-area update, not Xlib's initial Screen dimensions.
set -euo pipefail
OUT=$(realpath -m "$1")
PROG=$(realpath "$2")
mkdir -p "$OUT"
env FMXWAYLAND_BACKEND=x11 "$PROG" screen-watch >"$OUT/screen.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
for ((i=0; i<100; i++)); do
  grep -q '^ready' "$OUT/screen.log" && break
  kill -0 "$PID"
  sleep .02
done
xrandr --query >"$OUT/before.txt"
OUTPUT=$(awk '$2 == "connected" { print $1; exit }' "$OUT/before.txt")
[ -n "$OUTPUT" ] || { echo 'No connected test output' >&2; exit 1; }
xrandr --output "$OUTPUT" --off --fb 1024x768 >"$OUT/xrandr.log" 2>&1
wait "$PID"
grep -q 'screen changed 1024x768' "$OUT/screen.log"
echo 'Live screen and work-area resize: PASS'
