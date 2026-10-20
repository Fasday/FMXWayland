#!/bin/bash
# Exercise the visible drop-down itself, not just ComboBox's keyboard shortcuts while the list is closed.
# x11-popup.sh <out-dir> <Hello window-id>
set -euo pipefail
OUT=$1
WIN=$2
mkdir -p "$OUT"
popup() {
  xdotool search --onlyvisible --class '^Hello$' 2>/dev/null | grep -v "^$WIN$" | head -1 || true
}
wait_popup() {
  for ((i=0; i<50; i++)); do
    POPUP=$(popup)
    [ -n "$POPUP" ] && return 0
    sleep .04
  done
  xwininfo -root -tree >"$OUT/missing-popup.txt"
  echo 'ComboBox drop-down did not stay visible after a mouse click' >&2
  return 1
}
wait_closed() {
  for ((i=0; i<50; i++)); do
    [ -z "$(popup)" ] && return 0
    sleep .04
  done
  echo 'ComboBox drop-down did not close' >&2
  return 1
}
check_position() {
  read -r MAIN_X MAIN_Y < <(xwininfo -id "$WIN" | awk '/Absolute upper-left X:/{x=$4} /Absolute upper-left Y:/{print x, $4}')
  read -r POPUP_X POPUP_Y < <(xwininfo -id "$POPUP" | awk '/Absolute upper-left X:/{x=$4} /Absolute upper-left Y:/{print x, $4}')
  # Hello's combo: (20,290), 200x26; the FMX popup includes an 8-pixel shadow on each side.
  DX=$((POPUP_X - MAIN_X))
  DY=$((POPUP_Y - MAIN_Y))
  if ((DX < 10 || DX > 14 || DY < 306 || DY > 310)); then
    echo "Popup misplaced: client $MAIN_X,$MAIN_Y, popup $POPUP_X,$POPUP_Y (offset $DX,$DY)" >&2
    exit 1
  fi
}
xdotool mousemove --window "$WIN" 198 303 click 1
wait_popup
# Reproduce WSLg's focus policy even with Openbox: focusing the override-redirect list must not deactivate
# its FMX owner and immediately close it.
xdotool windowfocus --sync "$POPUP"
sleep .2
[ "$(popup)" = "$POPUP" ] || { echo 'Popup closed when it received keyboard focus' >&2; exit 1; }
check_position
python3 "$(dirname "$0")/x11-alpha.py" "$POPUP"
import -window "$POPUP" "$OUT/popup.png"
xdotool mousemove --window "$POPUP" 40 38 click 1
wait_closed
xdotool windowmove --sync "$WIN" 250 150
sleep .2
xdotool mousemove --window "$WIN" 198 303 click 1
wait_popup
check_position
xdotool mousemove --window "$WIN" 500 180 click 1
wait_closed
xdotool mousemove --window "$WIN" 198 303 click 1
wait_popup
xdotool windowfocus --sync "$POPUP"
xdotool key Down Return
wait_closed
echo 'Visible ComboBox: position before/after move, mouse selection, outside dismissal, keyboard selection: PASS'
