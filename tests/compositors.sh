#!/bin/bash
# Runs samples/Hello on one compositor started headless (tests\compositors.ps1 calls it for each compositor and scale):
#   1. the self-test (Hello --selftest), with a screenshot while its combo box drop-down is open;
#   2. where the compositor lets a test drive it (sway, KWin, GNOME Shell), a scenario with input as a user gives it
#      (tests/wltool.py): pointer, clicks, keyboard text and shortcuts, wheel, clipboard both ways with another
#      application, the combo box popup, second and modal forms, xdg-activation, maximize/restore from the program and
#      from the compositor, close from the compositor and from client-side title bar buttons; screenshots.
# Results: <out-dir>/results.txt ("PASS  <name>" / "FAIL  <name>"), logs and PNG files in <out-dir>.
#
#   compositors.sh <weston|sway|sway-csd|kwin|kwin-virtual|gnome> <scale> <out-dir> <program>
#
# Needs (Ubuntu 26.04): weston, sway, grim, kwin-wayland, kwin-common, kwin-style-breeze, gnome-shell, python3-dbus,
# dbus-daemon. Runs in a private runtime directory, home and D-Bus session; shows nothing on any screen.
set -u
COMP="$1"; SCALE="$2"; OUT="$3"; PROG="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${FMXW_INNER:-}" ]; then
  RT=$(mktemp -d /tmp/fmxw-rt.XXXXXX); chmod 700 "$RT"
  H=$(mktemp -d /tmp/fmxw-home.XXXXXX)
  export XDG_RUNTIME_DIR="$RT" HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" \
    XDG_CACHE_HOME="$H/.cache" FMXW_INNER=1
  unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS SWAYSOCK
  rm -rf "$OUT"; mkdir -p "$OUT"
  timeout 600 dbus-run-session -- bash "$0" "$@" > "$OUT/run.log" 2>&1
  CODE=$?
  rm -rf "$RT" "$H"
  exit $CODE
fi
RT="$XDG_RUNTIME_DIR"
RESULTS="$OUT/results.txt"
LABEL="$COMP scale $SCALE"
PIDS=""
: > "$RESULTS"

calc() { awk "BEGIN { v = $1; printf \"%d\", (v < 0 ? v - 0.5 : v + 0.5) }"; }
note() { echo "$(date +%T.%3N) [$(cut -d" " -f1 /proc/uptime)] $*" >> "$OUT/steps.log"; }
# PASS, FAIL, or SKIP (the compositor does not have what the check needs).
result() { # PASS|FAIL name [detail]
  echo "$1  $LABEL: $2${3:+ ($3)}" >> "$RESULTS"
  note "$1 $2 ${3:-}"
}
check() { # name command...: PASS when the command succeeds
  local name="$1"; shift
  if "$@"; then result PASS "$name"; else result FAIL "$name"; fi
}
# Waits until the program's log has at least N lines matching the pattern (extended regex).
wait_log() { # pattern [count] [seconds]
  local i=0 n=$(( ${3:-6} * 10 ))
  while [ $i -lt $n ]; do
    [ "$(grep -c -E -- "$1" "$PLOG" 2>/dev/null)" -ge "${2:-1}" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
count_log() { grep -c -E -- "$1" "$PLOG" 2>/dev/null; }
wait_socket() { local i=0; while [ ! -S "$RT/$1" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done; [ -S "$RT/$1" ]; }
first_wayland() { ls "$RT" | grep -E '^wayland-[0-9]+$' | head -1; }

# The sway the tests use: headless, pixman, its output at the scale (logical 1280x800).
start_sway() { # extra config lines
  local pw ph
  pw=$(calc "1280 * $SCALE"); ph=$(calc "800 * $SCALE")
  cat > "$RT/sway.cfg" <<EOF
output HEADLESS-1 resolution ${pw}x${ph} scale $SCALE
xwayland disable
seat seat0 fallback true
# xdg-activation focuses (sway's default only marks the window urgent).
focus_on_window_activation focus
$1
EOF
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman timeout 400 \
    sway -c "$RT/sway.cfg" > "$OUT/sway.log" 2>&1 &
  PIDS="$PIDS $!"
  local i=0
  while [ -z "$(first_wayland)" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  export HOST_WAYLAND_DISPLAY="$(first_wayland)" SWAYSOCK="$(ls "$RT"/sway-ipc.*.sock 2>/dev/null | head -1)"
  [ -n "$HOST_WAYLAND_DISPLAY" ]
}

# Client-side decorations of FMXWayland (the client area lies inside the window geometry): left, top. The client
# area of the main form (sway keeps the outer size of a window it switches to client-side decorations).
INSET_L=0; INSET_T=0
CW=700; CH=540
CAN_DRIVE=0
SHOOT=1
KIND=""
case "$COMP" in
  weston)
    # --debug exposes weston_screenshooter. No way to inject input: the self-test only.
    weston --backend=headless --renderer=pixman --width=1280 --height=800 --scale="$SCALE" --socket=fmxw-weston \
      --idle-time=0 --debug --log="$OUT/weston.log" 2> "$OUT/weston.stderr" &
    PIDS="$PIDS $!"
    wait_socket fmxw-weston || { result FAIL "weston starts"; exit 1; }
    export WAYLAND_DISPLAY=fmxw-weston
    INSET_L=4; INSET_T=30
    ;;
  sway|sway-csd)
    if [ "$COMP" = sway-csd ]; then
      # The title bar drawn by the program: sway tells it through xdg-decoration (mode client-side).
      start_sway 'for_window [app_id="Hello"] floating enable, border csd' || { result FAIL "sway starts"; exit 1; }
      INSET_L=4; INSET_T=30; CW=692; CH=506
    else
      start_sway 'for_window [app_id="Hello"] floating enable' || { result FAIL "sway starts"; exit 1; }
    fi
    export WAYLAND_DISPLAY="$HOST_WAYLAND_DISPLAY"
    CAN_DRIVE=1; KIND=sway
    ;;
  kwin)
    # KWin's virtual backend renders with QPainter, and ScreenShot2 needs OpenGL (no DRM render node in WSL): KWin
    # runs nested in a headless sway (its Wayland backend) whose output grim captures; KWin's window there is
    # fullscreen and takes the host output's scale.
    start_sway $'default_border none\nfor_window [title=".*"] fullscreen enable' || { result FAIL "host sway starts"; exit 1; }
    export WAYLAND_DISPLAY="$HOST_WAYLAND_DISPLAY"
    export KWIN_LOG="$OUT/kwin.log" KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 QT_LOGGING_RULES="kwin_scripting=true"
    timeout 400 kwin_wayland --socket fmxw-kwin --width 1280 --height 800 --no-lockscreen --no-global-shortcuts \
      --no-kactivities > "$KWIN_LOG" 2>&1 &
    PIDS="$PIDS $!"
    wait_socket fmxw-kwin || { result FAIL "kwin starts"; exit 1; }
    sleep 1
    export WAYLAND_DISPLAY=fmxw-kwin
    CAN_DRIVE=1; KIND=kwin
    ;;
  kwin-virtual)
    # KWin's own headless backend: no screenshots (see kwin), the self-test and the program's frame dumps.
    export KWIN_LOG="$OUT/kwin.log"
    timeout 400 kwin_wayland --virtual --socket fmxw-kwin --width 1280 --height 800 --scale "$SCALE" --no-lockscreen \
      --no-global-shortcuts --no-kactivities > "$KWIN_LOG" 2>&1 &
    PIDS="$PIDS $!"
    wait_socket fmxw-kwin || { result FAIL "kwin starts"; exit 1; }
    sleep 1
    export WAYLAND_DISPLAY=fmxw-kwin
    SHOOT=0
    ;;
  gnome)
    # GNOME Shell 50 (Mutter) headless with a virtual monitor; a test extension turns on the unsafe mode, which lets
    # tests call org.gnome.Shell.Eval and org.gnome.Shell.Screenshot. Fractional scales need Mutter's
    # scale-monitor-framebuffer; gdctl sets the scale.
    mkdir -p "$XDG_DATA_HOME/gnome-shell/extensions/fmxw-test@fmxwayland"
    cp "$HERE/gnome-test-extension/"* "$XDG_DATA_HOME/gnome-shell/extensions/fmxw-test@fmxwayland/"
    gsettings set org.gnome.shell enabled-extensions "['fmxw-test@fmxwayland']"
    gsettings set org.gnome.shell welcome-dialog-last-shown-version '999'
    gsettings set org.gnome.desktop.notifications show-banners false
    gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
    timeout 400 gnome-shell --headless --virtual-monitor "$(calc "1280 * $SCALE")x$(calc "800 * $SCALE")" \
      --wayland-display fmxw-gnome --no-x11 > "$OUT/gnome-shell.log" 2>&1 &
    PIDS="$PIDS $!"
    wait_socket fmxw-gnome || { result FAIL "gnome-shell starts"; exit 1; }
    i=0
    until gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
      'Main.overview.hide(); global.context.unsafe_mode' 2>/dev/null | grep -q true; do
      sleep 0.2; i=$((i + 1)); [ $i -gt 100 ] && { result FAIL "gnome-shell unsafe mode"; exit 1; }
    done
    if [ "$SCALE" != 1 ]; then
      gdctl set --logical-monitor --primary --monitor Meta-0 --scale "$SCALE" >> "$OUT/steps.log" 2>&1
    fi
    export WAYLAND_DISPLAY=fmxw-gnome
    INSET_L=4; INSET_T=30
    CAN_DRIVE=1; KIND=gnome
    ;;
  *)
    echo "unknown compositor $COMP"; exit 2 ;;
esac
wayland-info > "$OUT/wayland-info.txt" 2>&1

# The helper (input, clipboard, windows, screenshots) for the compositors it knows.
if [ -n "$KIND" ]; then
  mkfifo "$RT/cmd" "$RT/ans"
  LAYOUT="1280 800" timeout 400 python3 "$HERE/wltool.py" serve "$KIND" "$RT/cmd" "$RT/ans" > "$OUT/wltool.log" 2>&1 &
fi
ANS=""
t() { # a command to wltool; its answer (without "ok ") in ANS; false on an error
  echo "$*" > "$RT/cmd"
  if ! read -r -t 20 ANS < "$RT/ans"; then ANS="error: no answer"; fi
  note "$* -> $ANS"
  case "$ANS" in ok*) ANS="${ANS#ok}"; ANS="${ANS# }"; return 0 ;; *) return 1 ;; esac
}
shot() {
  [ "$SHOOT" = 1 ] || return 0
  if [ "$COMP" = weston ]; then
    (cd "$RT" && timeout 10 weston-screenshooter > /dev/null 2>&1 && mv "$RT"/wayland-screenshot*.png "$OUT/$1.png")
  else
    t shot "$OUT/$1.png"
  fi
}
[ -n "$KIND" ] && t caps

PDIR="$(dirname "$PROG")"

# 1. The self-test.
PLOG="$OUT/selftest.log"
mkdir -p "$OUT/selftest-frames"
(cd "$PDIR" && FMXWAYLAND_LOG=2 FMXWAYLAND_DUMP_DIR="$OUT/selftest-frames" timeout 90 "$PROG" --selftest \
  --quit-after=40 > "$PLOG" 2>&1; echo "exit=$?" >> "$PLOG") &
SELF=$!
if wait_log 'selftest: drop-down open' 1 30; then
  sleep 0.4
  shot selftest-dropdown
fi
wait $SELF

# 2. The scenario.
if [ "$CAN_DRIVE" != 1 ]; then
  note "no input injection on $COMP: self-test only"
  [ -n "$KIND" ] && t quit
  kill $PIDS 2>/dev/null; wait 2>/dev/null
  exit 0
fi
PLOG="$OUT/program.log"
(cd "$PDIR" && FMXWAYLAND_LOG=${FMXW_LOG:-2} timeout 150 "$PROG" --verbose --quit-after=120 > "$PLOG" 2>&1; \
  echo "exit=$?" >> "$PLOG") &
APP=$!
MAIN="FMXWayland Hello"
check "window shown" wait_log 'FMXWayland: debug: configure "FMXWayland Hello": [1-9]' 1 30
sleep 1
t settle
# The client area of a window: its geometry (the compositor's) plus the program's decorations.
CX=0; CY=0
origin() { # title [max]
  t geometry "$1" || return 1
  local l=$INSET_L
  [ "${2:-}" = max ] && l=0
  set -- $ANS
  CX=$(calc "$1 + $l"); CY=$(calc "$2 + $INSET_T")
  note "client area of the window at $CX,$CY"
}
at() { t move "$(calc "$CX + $1")" "$(calc "$CY + $2")"; }
click_at() { at "$1" "$2"; sleep 0.15; t click; sleep 0.45; }
origin "$MAIN"
case "$COMP" in
  kwin|sway) check "server-side decorations (xdg-decoration mode 2)" wait_log 'decoration mode 2' 1 1 ;;
  sway-csd) check "client-side decorations asked by the compositor (xdg-decoration mode 1)" \
    wait_log 'decoration mode 1' 1 1 ;;
  *) check "client-side decorations (no xdg-decoration)" bash -c "! grep -q 'decoration mode' '$PLOG'" ;;
esac
check "buffer of the scale" wait_log "native: .* buffer=$(calc "$CW * $SCALE")x$(calc "$CH * $SCALE") scale=$SCALE" 1 5
at 300 150; sleep 0.2; at 310 155; sleep 0.5
shot 01-start

# Pointer: three clicks (apart: no double click).
for n in 1 2 3; do click_at 75 211; done
check "pointer clicks on a button" wait_log '\[hello\] click 3' 1 3

# Keyboard: text, editing keys.
click_at 170 258
t type "2026 123"
check "keyboard text into TEdit" wait_log 'edit "2026 123"' 1 3
t key backspace
check "Backspace" wait_log 'edit "2026 12"' 1 3
t key home; t type 9
check "Home and typing" wait_log 'edit "92026 12"' 1 3
t key end; t type 3
check "End and typing" wait_log 'edit "92026 123"' 1 3

# Clipboard: the program to another application and back.
click_at 85 351
wait_log 'copied "92026 123"' 1 3
sleep 0.3
t paste
check "clipboard: another application pastes what the program copied" [ "$ANS" = "92026 123" ]
t copy "From $COMP 42"
sleep 0.3
click_at 225 351
check "clipboard: the program pastes what another application copied" wait_log "pasted \"From $COMP 42\"" 1 4
shot 02-clipboard

# Shortcuts: Ctrl+A, Ctrl+X in the edit; Shift for capitals.
click_at 170 258
t key ctrl+a; t key ctrl+x
check "Ctrl+A, Ctrl+X in TEdit" wait_log 'edit ""' 1 3
sleep 0.3
t paste
check "Ctrl+X puts the text into the clipboard" [ "$ANS" = "92026 123" ]
t type "Abc"
check "Shift and letters" wait_log 'edit "Abc"' 1 3

# Wheel over the form: up (positive in FMX), then down.
at 600 300; sleep 0.2
t wheel -2
check "mouse wheel up" wait_log 'wheel [1-9][0-9]*' 1 3
t wheel 1
check "mouse wheel down" wait_log 'wheel -[1-9][0-9]*' 1 3

# The combo box: its list is an xdg_popup; it must be where the program asked, and an item must be at its place.
click_at 120 303
check "combo box popup opens" wait_log 'popup configure' 1 3
sleep 0.4
shot 03-combo-open
P=$(grep 'popup configure' "$PLOG" | tail -1)
note "$P"
check "popup placed where asked" bash -c "echo '$P' | grep -q -E 'configure (-?[0-9]+),(-?[0-9]+) [0-9]+x[0-9]+ \\(asked \\1,\\2 '"
click_at 60 364
check "popup item chosen by a click (Blue)" wait_log 'combo Blue' 1 3

# Check box.
click_at 250 303
check "check box" wait_log 'check False' 1 3

# Second form; the main form activated again from it with xdg-activation (a click's serial).
click_at 85 401
check "second form shown" wait_log 'second form shown' 1 3
sleep 1
MX=$CX; MY=$CY
if origin "Second form 1"; then
  shot 04-second-form
  t focus
  check "second form has the focus" [ "$ANS" = "Second form 1" ]
  N=$(count_log 'form activated')
  click_at 250 95
  check "xdg-activation: token asked for the main form" wait_log 'activation token for "FMXWayland Hello"' 1 3
  check "xdg-activation: main form activated" wait_log 'form activated' $((N + 1)) 4
  sleep 0.5
  t focus
  check "xdg-activation: the compositor focuses the main form" [ "$ANS" = "$MAIN" ]
  t close "Second form 1"
  check "close from the compositor" wait_log 'second form closed' 1 3
else
  result FAIL "second form found by the compositor"
fi
CX=$MX; CY=$MY

# Client-side title bar buttons: close of another second form.
if [ "$INSET_T" -gt 0 ]; then
  click_at 85 401
  sleep 1
  if t geometry "Second form 2"; then
    set -- $ANS
    t move "$(calc "$1 + $3 - 4 - 20")" "$(calc "$2 + 4 + 13")"; sleep 0.3; t click
    check "close button of the client-side title bar" wait_log 'second form closed' 2 3
  else
    result FAIL "second form 2 found by the compositor"
  fi
  CX=$MX; CY=$MY
fi

# Modal form: the main form must not react meanwhile.
N=$(count_log '\[hello\] click ')
click_at 225 401
check "modal form shown" wait_log 'modal shown' 1 3
sleep 1
if origin "Modal form"; then
  shot 05-modal
  MOX=$CX; MOY=$CY
  CX=$MX; CY=$MY
  click_at 75 211
  check "main form blocked while modal" [ "$(count_log '\[hello\] click ')" = "$N" ]
  CX=$MOX; CY=$MOY
  click_at 80 105
  check "modal result OK" wait_log 'modal result 1' 1 3
else
  result FAIL "modal form found by the compositor"
fi
CX=$MX; CY=$MY
sleep 0.5

# Maximize and restore: from the program, from the compositor, from the client-side title bar (where the window
# manager has maximize: xdg_toplevel.wm_capabilities).
CAPS=$(grep -m1 'wm capabilities of "FMXWayland Hello"' "$PLOG")
note "$CAPS"
if [ -n "$CAPS" ] && ! echo "$CAPS" | grep -q maximize; then
  result SKIP "maximize and restore" "no maximize in the window manager's capabilities:${CAPS##*\":}"
else
N=$(count_log 'resize [0-9]+x[0-9]+ state 2')
click_at 365 401
check "maximize from the program" wait_log 'resize [0-9]+x[0-9]+ state 2' $((N + 1)) 4
sleep 1
origin "$MAIN" max
shot 06-maximized
N=$(count_log 'resize 700x540 state 0')
click_at 365 401
check "restore from the program (700x540)" wait_log 'resize 700x540 state 0' $((N + 1)) 4
sleep 1
origin "$MAIN"
if true; then
  N=$(count_log 'resize [0-9]+x[0-9]+ state 2')
  t maximize "$MAIN"
  check "maximize from the compositor" wait_log 'resize [0-9]+x[0-9]+ state 2' $((N + 1)) 4
  sleep 0.5
  N=$(count_log 'resize 700x540 state 0')
  t restore "$MAIN"
  check "restore from the compositor" wait_log 'resize 700x540 state 0' $((N + 1)) 4
  sleep 1
fi
if [ "$INSET_T" -gt 0 ]; then
  t geometry "$MAIN"; set -- $ANS
  N=$(count_log 'resize [0-9]+x[0-9]+ state 2')
  t move "$(calc "$1 + $3 - 4 - 60")" "$(calc "$2 + 4 + 13")"; sleep 0.3; t click
  check "maximize button of the client-side title bar" wait_log 'resize [0-9]+x[0-9]+ state 2' $((N + 1)) 4
  sleep 1
  origin "$MAIN" max
  N=$(count_log 'resize 700x540 state 0')
  click_at 365 401
  check "restore after the title bar maximize" wait_log 'resize 700x540 state 0' $((N + 1)) 4
  sleep 1
  origin "$MAIN"
fi
fi

# Resize from code.
click_at 505 401
check "resize from code" wait_log 'resized by code to 760x560' 1 3
sleep 0.8
t geometry "$MAIN"; set -- $ANS
check "the compositor sees the new size" [ "$(calc "$3 - 2 * $INSET_L")" = 760 ]
shot 07-end

# Close from the compositor: clean exit.
t close "$MAIN"
check "main form closed by the compositor" wait_log '\[hello\] destroyed' 1 5
wait $APP
check "clean exit" grep -q 'exit=0' "$PLOG"
check "no errors in the program's logs" bash -c "! grep -q -E 'protocol error|FMXWayland: error' '$PLOG' '$OUT/selftest.log'"
t quit
kill $PIDS 2>/dev/null
wait 2>/dev/null
exit 0
