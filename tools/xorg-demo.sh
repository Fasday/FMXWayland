#!/bin/bash
# Visible, real Xorg (dummy DDX) demo. Run in a private mount namespace on WSLg; see docs/X11.md.
# xorg-demo.sh <output-directory> <Hello executable> [display-number=91] [VNC-port=5991]
set -euo pipefail
OUT=$(realpath -m "$1")
SOURCE=$(realpath "$2")
NUMBER=${3:-91}
PORT=${4:-5991}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"
RUN=$(mktemp -d)
cp "$SOURCE" "$RUN/Hello"
if [ -f "$(dirname "$SOURCE")/libsk4d.so" ]; then cp "$(dirname "$SOURCE")/libsk4d.so" "$RUN/"; fi
XPID= WPID= CPID= VPID= APP=
cleanup() {
  for pid in "$APP" "$VPID" "$CPID" "$WPID" "$XPID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  rm -rf "$RUN"
}
trap cleanup EXIT
Xorg ":$NUMBER" -config "$ROOT/tests/xorg-dummy.conf" -logfile "$OUT/Xorg.log" \
  -nolisten tcp -noreset -ac -novtswitch -sharevts >"$OUT/server.log" 2>&1 &
XPID=$!
export DISPLAY=:$NUMBER
unset WAYLAND_DISPLAY WAYLAND_SOCKET XDG_RUNTIME_DIR
export FMXWAYLAND_BACKEND=auto FMXWAYLAND_LOG=2 FMXWAYLAND_PORTAL=0
export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN/no-bus"
READY=0
for ((i=0; i<100; i++)); do
  kill -0 "$XPID" 2>/dev/null || { cat "$OUT/server.log" >&2; exit 1; }
  if [ -r "/tmp/.X$NUMBER-lock" ] && [ "$(tr -d '[:space:]' <"/tmp/.X$NUMBER-lock")" = "$XPID" ] &&
     xdotool getdisplaygeometry >/dev/null 2>&1; then READY=1; break; fi
  sleep .05
done
[ "$READY" = 1 ] || { cat "$OUT/server.log" >&2; exit 1; }
readlink "/proc/$XPID/exe" >"$OUT/server-executable.txt"
xdpyinfo >"$OUT/display.txt"
openbox >"$OUT/openbox.log" 2>&1 &
WPID=$!
xcompmgr -n >"$OUT/compositor.log" 2>&1 &
CPID=$!
sleep .5
"$RUN/Hello" --verbose >"$OUT/program.log" 2>&1 &
APP=$!
x11vnc -display "$DISPLAY" -rfbport "$PORT" -localhost -nopw -forever -shared -repeat -noxdamage \
  -desktop 'FMXWayland - Xorg (dummy) + Openbox' >"$OUT/vnc.log" 2>&1 &
VPID=$!
echo "Xorg $DISPLAY; connect a local VNC viewer to 127.0.0.1::$PORT"
wait "$APP"
