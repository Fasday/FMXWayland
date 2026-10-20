#!/bin/bash
# Run inside a private X11 session with a WM. Unlike --selftest, open and dismiss dialogs with real clicks.
# x11-modal.sh <out-dir> <Hello executable>
set -euo pipefail
OUT=$(realpath -m "$1")
PROG=$(realpath "$2")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
RUN_DIR=$(mktemp -d)
cp "$PROG" "$RUN_DIR/Hello"
if [ -f "$(dirname "$PROG")/libsk4d.so" ]; then cp "$(dirname "$PROG")/libsk4d.so" "$RUN_DIR/"; fi
PROG="$RUN_DIR/Hello"
WM_PID= COMPOSITOR_PID=
if [ "${X11_START_WM:-0}" = 1 ]; then
  openbox >"$OUT/openbox.log" 2>&1 &
  WM_PID=$!
  sleep .3
fi
if [ "${X11_START_COMPOSITOR:-0}" = 1 ]; then
  xcompmgr -n >"$OUT/compositor.log" 2>&1 &
  COMPOSITOR_PID=$!
  sleep .3
fi
timeout 25 env FMXWAYLAND_BACKEND=x11 FMXWAYLAND_LOG="${FMXWAYLAND_LOG:-2}" FMXWAYLAND_PORTAL=0 \
  "$PROG" --verbose --quit-after=20 >"$OUT/program.log" 2>&1 &
PID=$!
trap 'kill "$PID" ${WM_PID:+"$WM_PID"} ${COMPOSITOR_PID:+"$COMPOSITOR_PID"} 2>/dev/null || true; rm -rf "$RUN_DIR"' EXIT
WIN=$(timeout 8 xdotool search --sync --onlyvisible --name '^FMXWayland Hello$' | head -1)
# XWayland's Weston WM (WSLg) does not implement _NET_ACTIVE_WINDOW; focus directly for this input test.
xdotool windowfocus --sync "$WIN"
sleep .3

wait_log() {
  for ((i=0; i<60; i++)); do
    grep -q "$1" "$OUT/program.log" && return 0
    sleep .05
  done
  echo "Missing interaction: $1" >&2
  cat "$OUT/program.log" >&2
  return 1
}

bash "$SCRIPT_DIR/x11-popup.sh" "$OUT/popup" "$WIN"
wait_log 'combo Green'
wait_log 'combo Blue'
python3 "$SCRIPT_DIR/x11-cursor.py" "$WIN" >"$OUT/cursor.log" 2>&1 || {
  cat "$OUT/cursor.log" >&2
  exit 1
}
xdotool mousemove --window "$WIN" 630 403 click 1
DIALOG=$(timeout 5 xdotool search --sync --onlyvisible --name '^Confirm$' | head -1)
sleep .3
# Native WMs may cascade the dialog directly over the parent's test button. Move it away before testing
# blocked input, otherwise that 'parent' click can actually hit Yes and destroy the dialog under the next command.
eval "$(xdotool getwindowgeometry --shell "$WIN")"
PARENT_CLICK_X=$((X+70)) PARENT_CLICK_Y=$((Y+214))
eval "$(xdotool getwindowgeometry --shell "$DIALOG")"
DX=20 DY=20
if ((PARENT_CLICK_X >= DX-50 && PARENT_CLICK_X <= DX+WIDTH+50 &&
     PARENT_CLICK_Y >= DY-50 && PARENT_CLICK_Y <= DY+HEIGHT+50)); then
  read -r SW SH < <(xdotool getdisplaygeometry)
  DX=$((SW-WIDTH-40)) DY=$((SH-HEIGHT-80))
fi
xdotool windowmove --sync "$DIALOG" "$DX" "$DY"
sleep .15
import -window "$DIALOG" "$OUT/message.png"
# Parent must stay blocked while the dialog is open.
xdotool mousemove --window "$WIN" 70 214 click 1
xdotool mousemove --window "$DIALOG" 85 81 click 1
wait_log 'message result 6'
if grep -q '\[hello\] click ' "$OUT/program.log"; then
  echo 'Parent accepted a click while modal' >&2
  exit 1
fi
xdotool mousemove --window "$WIN" 220 403 click 1
DIALOG=$(timeout 5 xdotool search --sync --onlyvisible --name '^Modal form$' | head -1)
sleep .3
xdotool mousemove --window "$DIALOG" 80 105 click 1
wait_log 'modal result 1'
xdotool mousemove --window "$WIN" 70 214 click 1
wait_log 'click 1'
xdotool windowfocus --sync "$WIN" key alt+F4
wait "$PID"
if grep -Ei 'access violation|exception|X11 error' "$OUT/program.log"; then exit 1; fi
cat "$OUT/cursor.log"
echo 'Mouse-opened message box and modal form, blocked parent, restored input: PASS'
