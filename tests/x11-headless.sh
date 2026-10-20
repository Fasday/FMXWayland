#!/bin/bash
# Native X11 integration test. Requires Xvfb, openbox, xdotool, xclip and ImageMagick.
# x11-headless.sh <out-dir> <Hello executable>
# X11_SERVER=xvfb (default), xorg (dummy driver), or existing (uses DISPLAY/XAUTHORITY).
set -euo pipefail
OUT=$(realpath -m "$1")
PROG=$(realpath "$2")
PROBE=${3:-}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
rm -f "$OUT/PASSED"
RT=$(mktemp -d)
mkdir -p "$RT/bin"
# Execute a fresh Linux inode: rebuilding a Windows-hosted executable in place can leave stale DrvFS mmap pages.
cp "$PROG" "$RT/bin/Hello"
if [ -f "$(dirname "$PROG")/libsk4d.so" ]; then cp "$(dirname "$PROG")/libsk4d.so" "$RT/bin/"; fi
PROG="$RT/bin/Hello"
if [ -n "$PROBE" ]; then
  cp "$PROBE" "$RT/bin/BackendCheck"
  PROBE="$RT/bin/BackendCheck"
fi
XPID= WPID= CPID= APP=
cleanup() {
  for pid in "$APP" "$CPID" "$WPID" "$XPID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  rm -rf "$RT"
}
trap cleanup EXIT
SERVER=${X11_SERVER:-xvfb}
if [ "$SERVER" != existing ]; then
# Do not use -displayfd's automatic :0. Under WSLg a private /tmp mount hides its pathname socket, and an
# Xvfb abstract socket named :0 would then intercept GUI clients outside this test's mount namespace.
READY=0
for ((number=90; number<190; number++)); do
  case "$SERVER" in
    xvfb) Xvfb ":$number" -screen 0 1280x800x24 -nolisten tcp >"$OUT/server.log" 2>&1 & ;;
    xorg) Xorg ":$number" -config "$SCRIPT_DIR/xorg-dummy.conf" -logfile "$OUT/Xorg.log" \
      -nolisten tcp -noreset -ac -novtswitch -sharevts >"$OUT/server.log" 2>&1 & ;;
    *) echo "Unknown X11_SERVER: $SERVER" >&2; exit 1 ;;
  esac
  XPID=$!
  for ((i=0; i<100; i++)); do
    kill -0 "$XPID" 2>/dev/null || break
    if [ -r "/tmp/.X$number-lock" ] &&
       [ "$(tr -d '[:space:]' <"/tmp/.X$number-lock")" = "$XPID" ] &&
       DISPLAY=:$number xdotool getdisplaygeometry >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep .05
  done
  [ "$READY" = 1 ] && break
  kill "$XPID" 2>/dev/null || true
  wait "$XPID" 2>/dev/null || true
done
[ "$READY" = 1 ] || { cat "$OUT/server.log" >&2; exit 1; }
export DISPLAY=:$number
readlink "/proc/$XPID/exe" >"$OUT/server-executable.txt"
else
  : "${DISPLAY:?X11_SERVER=existing requires DISPLAY}"
  if xdotool search --onlyvisible --name '^FMXWayland Hello$' >/dev/null 2>&1; then
    echo 'An existing Hello window would interfere with the input tests; use a dedicated display.' >&2
    exit 1
  fi
fi
xdpyinfo >"$OUT/display.txt"
export XDG_RUNTIME_DIR="$RT"
export WAYLAND_DISPLAY=missing-wayland
unset WAYLAND_SOCKET
export DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/no-bus"
export FMXWAYLAND_PORTAL=0 FMXWAYLAND_LOG=2
if [ "$SERVER" != existing ]; then
  openbox >"$OUT/openbox.log" 2>&1 &
  WPID=$!
  sleep .5
fi
cd "$(dirname "$PROG")"
timeout 45 env FMXWAYLAND_BACKEND=auto "$PROG" --verbose --selftest --quit-after=25 >"$OUT/selftest.log" 2>&1 &
APP=$!
sleep 2
import -window root "$OUT/selftest.png"
wait "$APP"
APP=
grep -q 'backend: X11' "$OUT/selftest.log"
grep -q 'backend: X11; presentation: XPutImage' "$OUT/selftest.log"
grep -q 'selftest: done' "$OUT/selftest.log"
grep -q 'selftest: modal result 4' "$OUT/selftest.log"
grep -q 'selftest: synchronize from a thread, on the main thread True' "$OUT/selftest.log"
grep -q 'selftest: queue from a thread, on the main thread True' "$OUT/selftest.log"
grep -q 'selftest: clipboard "selftest clipboard' "$OUT/selftest.log"
if grep -Ei 'access violation|exception|X Error|X11 error|XIO:' "$OUT/selftest.log"; then exit 1; fi
timeout 25 env FMXWAYLAND_BACKEND=x11 "$PROG" --verbose --quit-after=18 >"$OUT/forced.log" 2>&1 &
APP=$!
WIN=$(timeout 10 xdotool search --sync --onlyvisible --name '^FMXWayland Hello$' | head -1)
xdotool windowfocus --sync "$WIN"
xdotool mousemove --window "$WIN" 70 214 click 1
xdotool mousemove --window "$WIN" 100 258 click 1
xdotool type --clearmodifiers 'Native X11'
xdotool key ctrl+a ctrl+c
sleep .3
import -window root "$OUT/selection.png"
timeout 5 xclip -selection clipboard -o >"$OUT/copied.txt"
test "$(cat "$OUT/copied.txt")" = 'Native X11'
printf 'External UTF-8: Привет ✓' | xclip -selection clipboard -i 2>"$OUT/xclip.log"
xdotool mousemove --window "$WIN" 100 258 click 1
xdotool key ctrl+a ctrl+v
xdotool mousemove --window "$WIN" 85 303 click 1
sleep .2
xdotool key Down Return
xdotool mousemove --window "$WIN" 500 180 click 4
sleep .3
import -window root "$OUT/input.png"
xdotool windowsize "$WIN" 760 560
sleep .2
xdotool windowmove --sync "$WIN" 120 110
sleep .2
xdotool mousemove --window "$WIN" 70 214 click 1
xdotool key alt+F4
wait "$APP"
APP=
grep -q 'backend: X11' "$OUT/forced.log"
grep -q 'click 1' "$OUT/forced.log"
grep -q 'click 2' "$OUT/forced.log"
grep -q 'edit "External UTF-8: Привет ✓"' "$OUT/forced.log"
grep -q 'wheel 120' "$OUT/forced.log"
grep -q 'resize 760x560' "$OUT/forced.log"
if grep -Ei 'access violation|exception|X11 error' "$OUT/forced.log"; then exit 1; fi
bash "$SCRIPT_DIR/x11-modal.sh" "$OUT/modal" "$PROG"
bash "$SCRIPT_DIR/x11-frame.sh" "$OUT/frame" "$PROG"
if [ "$SERVER" != existing ]; then
  X11_LEGACY_WM=1 bash "$SCRIPT_DIR/x11-frame.sh" "$OUT/frame-legacy" "$PROG"
  xcompmgr -n >"$OUT/compositor.log" 2>&1 &
  CPID=$!
  sleep .3
  bash "$SCRIPT_DIR/x11-modal.sh" "$OUT/composited" "$PROG"
fi
if timeout 5 env FMXWAYLAND_BACKEND=wayland "$PROG" >"$OUT/wayland-only.log" 2>&1; then
  echo 'Forced Wayland unexpectedly fell back to X11' >&2
  exit 1
fi
grep -q 'cannot connect to a Wayland compositor' "$OUT/wayland-only.log"
if timeout 5 env DISPLAY= FMXWAYLAND_BACKEND=auto "$PROG" >"$OUT/no-display.log" 2>&1; then
  echo 'Startup unexpectedly succeeded without a display' >&2
  exit 1
fi
grep -q 'cannot connect to X11' "$OUT/no-display.log"
if timeout 5 env FMXWAYLAND_BACKEND=invalid "$PROG" >"$OUT/invalid.log" 2>&1; then
  echo 'Invalid backend unexpectedly accepted' >&2
  exit 1
fi
grep -q 'FMXWAYLAND_BACKEND must be' "$OUT/invalid.log"
if [ -n "$PROBE" ]; then
  FMXWAYLAND_BACKEND=x11 "$PROBE" coordinates >"$OUT/coordinates.log" 2>&1
  FMXWAYLAND_BACKEND=x11 "$PROBE" lifetime >"$OUT/lifetime.log" 2>&1
  FMXWAYLAND_BACKEND=x11 "$PROBE" signal >"$OUT/signal.log" 2>&1
  if grep -Ei 'access violation|exception|X11 error|XIO:' "$OUT/coordinates.log" "$OUT/lifetime.log"; then exit 1; fi
  if [ "${X11_SKIP_LARGE_CLIPBOARD:-0}" != 1 ]; then
    bash "$SCRIPT_DIR/x11-clipboard.sh" "$OUT/clipboard" "$PROBE"
  else
    echo 'Large clipboard check: SKIPPED (explicit X11_SKIP_LARGE_CLIPBOARD=1)'
  fi
  if [ "$SERVER" != existing ]; then bash "$SCRIPT_DIR/x11-screen.sh" "$OUT/screen" "$PROBE"; fi
fi
timeout 5 xdpyinfo >"$OUT/display-after.txt"
echo "X11 suite ($SERVER): PASS"
date -Iseconds >"$OUT/PASSED"
