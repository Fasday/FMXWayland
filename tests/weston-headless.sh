#!/bin/sh
# Runs a program on a private headless Weston (no screen, no input devices; WSL or any Linux) with a given output
# scale, takes a screenshot with weston-screenshooter and lets the program dump its own frames
# (FMXWAYLAND_DUMP_DIR). Used by tests\weston-headless.ps1.
#
#   weston-headless.sh <out-dir> <scale> <program> [args...]
set -u
OUT="$1"; SCALE="$2"; shift 2
PROG="$1"; shift
mkdir -p "$OUT"
RT=$(mktemp -d /tmp/fmxw-rt.XXXXXX)
chmod 700 "$RT"
export XDG_RUNTIME_DIR="$RT"
unset DISPLAY WAYLAND_DISPLAY
# --debug exposes weston_screenshooter to clients.
weston --backend=headless --renderer=pixman --width=1280 --height=800 --scale="$SCALE" --socket=fmxw-test \
  --idle-time=0 --debug --log="$OUT/weston.log" 2> "$OUT/weston.stderr" &
WPID=$!
i=0
while [ ! -S "$RT/fmxw-test" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
export WAYLAND_DISPLAY=fmxw-test
wayland-info > "$OUT/wayland-info.txt" 2>&1
cd "$(dirname "$PROG")"
FMXWAYLAND_LOG=2 FMXWAYLAND_DUMP_DIR="$OUT" timeout 60 "$PROG" "$@" > "$OUT/program.log" 2>&1 &
PPID2=$!
sleep "${SHOT_AFTER:-4}"
(cd "$OUT" && timeout 10 weston-screenshooter > "$OUT/screenshooter.log" 2>&1)
wait $PPID2
echo "exit=$?" >> "$OUT/program.log"
kill $WPID 2>/dev/null
wait $WPID 2>/dev/null
rm -rf "$RT"
