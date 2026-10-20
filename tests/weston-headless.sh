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
WPID= PPID2=
cleanup() {
  for pid in "$PPID2" "$WPID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  rm -rf "$RT"
}
trap cleanup EXIT
mkdir -p "$RT/bin"
cp "$PROG" "$RT/bin/$(basename "$PROG")" || exit 1
if [ -f "$(dirname "$PROG")/libsk4d.so" ]; then cp "$(dirname "$PROG")/libsk4d.so" "$RT/bin/" || exit 1; fi
PROG="$RT/bin/$(basename "$PROG")"
export XDG_RUNTIME_DIR="$RT"
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
export FMXWAYLAND_BACKEND=wayland
# --debug exposes weston_screenshooter to clients. Weston before 12 (Ubuntu 22.04: 9, Debian 12: 10) knows only the
# module name of the backend and --use-pixman (its headless backend draws nothing otherwise).
if weston --help 2>&1 | grep -q -- '--renderer='; then
  WARGS="--backend=headless --renderer=pixman"
else
  WARGS="--backend=headless-backend.so --use-pixman"
fi
weston $WARGS --width=1280 --height=800 --scale="$SCALE" --socket=fmxw-test \
  --idle-time=0 --debug --log="$OUT/weston.log" 2> "$OUT/weston.stderr" &
WPID=$!
i=0
while [ ! -S "$RT/fmxw-test" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
export WAYLAND_DISPLAY=fmxw-test
wayland-info > "$OUT/wayland-info.txt" 2>&1
cd "$(dirname "$PROG")"
# No session bus (an address that does not exist): the file dialogs fall back to FMX's own at once.
DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/no-session-bus" FMXWAYLAND_LOG=2 FMXWAYLAND_DUMP_DIR="$OUT" \
  timeout 60 "$PROG" "$@" > "$OUT/program.log" 2>&1 &
PPID2=$!
sleep "${SHOT_AFTER:-3}"
(cd "$OUT" && timeout 10 weston-screenshooter > "$OUT/screenshooter.log" 2>&1)
wait $PPID2
RESULT=$?
PPID2=
echo "exit=$RESULT" >> "$OUT/program.log"
exit "$RESULT"
