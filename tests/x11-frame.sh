#!/bin/bash
# Run on an existing X server/WM. Exercises the frame service with real pointer grabs (including legacy WMs).
set -euo pipefail
OUT=$(realpath -m "$1")
SOURCE=$(realpath "$2")
mkdir -p "$OUT"
RUN=$(mktemp -d)
cp "$SOURCE" "$RUN/Hello"
if [ -f "$(dirname "$SOURCE")/libsk4d.so" ]; then cp "$(dirname "$SOURCE")/libsk4d.so" "$RUN/"; fi
WM_PID=
if [ "${X11_START_WM:-0}" = 1 ]; then
  openbox >"$OUT/openbox.log" 2>&1 &
  WM_PID=$!
  sleep .3
fi
if [ "${X11_LEGACY_WM:-0}" = 1 ]; then xprop -root -remove _NET_SUPPORTED; fi
timeout 30 env FMXWAYLAND_BACKEND=x11 FMXWAYLAND_LOG="${FMXWAYLAND_LOG:-2}" "$RUN/Hello" \
  --own-titlebar --verbose --quit-after=25 >"$OUT/program.log" 2>&1 &
PID=$!
trap 'kill "$PID" ${WM_PID:+"$WM_PID"} 2>/dev/null || true; rm -rf "$RUN"' EXIT
WIN=$(timeout 8 xdotool search --sync --onlyvisible --name '^FMXWayland own title bar$' | head -1)
xdotool windowfocus --sync "$WIN"
sleep .3
geometry() { eval "$(xdotool getwindowgeometry --shell "$WIN")"; }
geometry
START_WIDTH=$WIDTH START_HEIGHT=$HEIGHT
grep -q 'decorated False' "$OUT/program.log"
xprop -id "$WIN" _MOTIF_WM_HINTS >"$OUT/frame-hints.txt"
import -window "$WIN" "$OUT/titlebar.png"
START_X=$X START_Y=$Y
xdotool mousemove --window "$WIN" 250 18 mousedown 1
sleep .08
xdotool mousemove $((START_X+256)) $((START_Y+24))
sleep .1
xdotool mousemove $((START_X+340)) $((START_Y+88))
sleep .15
xdotool mouseup 1
sleep .2
geometry
if ((X < START_X+88 || X > START_X+92 || Y < START_Y+68 || Y > START_Y+72)); then
  echo "Custom caption drag failed: $START_X,$START_Y -> $X,$Y" >&2
  exit 1
fi
START_X=$X START_Y=$Y
xdotool mousemove --window "$WIN" $((WIDTH-2)) $((HEIGHT-2)) mousedown 1
sleep .08
xdotool mousemove $((X+WIDTH+4)) $((Y+HEIGHT+4))
sleep .1
xdotool mousemove $((X+WIDTH+78)) $((Y+HEIGHT+58))
sleep .15
xdotool mouseup 1
sleep .2
geometry
if ((WIDTH < START_WIDTH+78 || WIDTH > START_WIDTH+82 || HEIGHT < START_HEIGHT+58 || HEIGHT > START_HEIGHT+62)); then
  echo "Custom resize grip failed: ${WIDTH}x${HEIGHT}" >&2
  exit 1
fi
RESTORE_WIDTH=$WIDTH RESTORE_HEIGHT=$HEIGHT
xdotool mousemove --window "$WIN" 250 18
sleep .15
xdotool click --repeat 2 --delay 150 1
sleep .5
geometry
read -r SCREEN_WIDTH SCREEN_HEIGHT < <(xdotool getdisplaygeometry)
if ((WIDTH < SCREEN_WIDTH-100 || HEIGHT < SCREEN_HEIGHT-100)); then
  echo "Custom caption maximize failed: ${WIDTH}x${HEIGHT}" >&2
  exit 1
fi
import -window "$WIN" "$OUT/maximized.png"
xdotool mousemove --window "$WIN" $((WIDTH-69)) 18 click 1
sleep .3
geometry
test "$WIDTH" = "$RESTORE_WIDTH"
test "$HEIGHT" = "$RESTORE_HEIGHT"
xdpyinfo >"$OUT/display.txt"
NATIVE_HANDLE=
if grep -q 'vendor string:.*Colin Harrison' "$OUT/display.txt"; then
  HELPER=$(wslpath -w "$(cd "$(dirname "$0")" && pwd)/xming-window.ps1")
  NATIVE_HANDLE=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HELPER" -Find | tr -d '\r')
fi
xdotool mousemove --window "$WIN" $((WIDTH-115)) 18 click 1
sleep .3
xprop -id "$WIN" WM_STATE >"$OUT/minimized.txt"
xwininfo -id "$WIN" >"$OUT/minimized-geometry.txt"
xprop -id "$WIN" >"$OUT/window-properties.txt"
if grep -qi 'Iconic' "$OUT/minimized.txt" || grep -q 'Map State: IsUnMapped' "$OUT/minimized-geometry.txt"; then
  xdotool windowmap "$WIN"
elif grep -q 'vendor string:.*Colin Harrison' "$OUT/display.txt"; then
  # Xming 6.9 minimizes the Win32 window but publishes no ICCCM WM_STATE. Check the native state instead.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HELPER" -Handle "$NATIVE_HANDLE" >"$OUT/minimized-native.txt"
  grep -q True "$OUT/minimized-native.txt"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HELPER" -Handle "$NATIVE_HANDLE" -Restore >"$OUT/restored-native.txt"
else
  echo 'Window did not become iconic' >&2
  exit 1
fi
sleep .3
xdotool windowfocus --sync "$WIN"
geometry
xdotool mousemove --window "$WIN" $((WIDTH-23)) 18 click 1
wait "$PID"
if grep -Ei 'access violation|exception|X11 error' "$OUT/program.log"; then exit 1; fi
echo 'Custom X11 frame: undecorated, move, resize, maximize/restore, minimize and close: PASS'
