#!/bin/bash
# Runs samples/Hello on one compositor started headless (tests\compositors.ps1 calls it for each compositor and scale):
#   1. the self-test (Hello --selftest), with a screenshot while its combo box drop-down is open;
#   2. where the compositor lets a test drive it (sway, KWin, GNOME Shell), a scenario with input as a user gives it
#      (tests/wltool.py): pointer, clicks, keyboard text and shortcuts, wheel, clipboard both ways with another
#      application, the combo box popup, second and modal forms, FMX's own file dialogs, xdg-activation,
#      maximize/restore from the program and from the compositor, close from the compositor and from client-side
#      title bar buttons; screenshots;
#   3. Hello --own-titlebar --selftest (IFMXWaylandWindowFrame without input) and, where the compositor can be
#      driven, Hello --own-titlebar with input: no decorations (the compositor's frame is the window geometry), the
#      caption moves the window, the edge resizes it, double click maximizes and restores, right click shows the
#      compositor's window menu, the states follow activation, minimize, the close button;
#   4. Hello --early-popup (=paint, =create): popups opened before the window is mapped (screenshots);
#   5. where xdg-desktop-portal and a backend for the compositor are installed (GNOME Shell: xdg-desktop-portal-gnome,
#      KWin: xdg-desktop-portal-kde, sway: xdg-desktop-portal-gtk), the portal's file dialog: the request, its window
#      (a child of the program's through xdg-foreign where the compositor has it), the program's windows blocked and
#      its loop running meanwhile, a file chosen with the keyboard, Escape, and a request closed over D-Bus.
# The self-test and the scenario use a private session bus without services (no portal: FMX's own file dialogs);
# the other parts use the session bus of the run, where D-Bus activation starts the portal.
# Results: <out-dir>/results.txt ("PASS  <name>" / "FAIL  <name>"), logs and PNG files in <out-dir>.
#
#   compositors.sh <weston|sway|sway-csd|kwin|kwin-virtual|gnome> <scale> <out-dir> <program> [parts]
#
# parts: some of "selftest frame-selftest early scenario frame portal" (default: all).
# Needs (Ubuntu 26.04): weston, sway, grim, kwin-wayland, kwin-common, kwin-style-breeze, gnome-shell, python3-dbus,
# dbus-daemon; for part 3 xdg-desktop-portal and its backends. Runs in a private runtime directory, home and D-Bus
# session; shows nothing on any screen.
set -u
COMP="$1"; SCALE="$2"; OUT="$3"; PROG="$4"; PARTS="${5:-selftest frame-selftest early scenario frame portal}"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${FMXW_INNER:-}" ]; then
  RT=$(mktemp -d /tmp/fmxw-rt.XXXXXX); chmod 700 "$RT"
  H=$(mktemp -d /tmp/fmxw-home.XXXXXX)
  export XDG_RUNTIME_DIR="$RT" HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" \
    XDG_CACHE_HOME="$H/.cache" FMXW_INNER=1
  unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS SWAYSOCK
  rm -rf "$OUT"; mkdir -p "$OUT"
  timeout 1500 dbus-run-session -- bash "$0" "$@" > "$OUT/run.log" 2>&1
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
check() { # name command...: PASS when the command succeeds (and the status of the command)
  local name="$1"; shift
  if "$@"; then result PASS "$name"; else result FAIL "$name"; return 1; fi
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
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman timeout 1400 \
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
# XDG_CURRENT_DESKTOP for xdg-desktop-portal (it picks the backend by it); '' = no portal part. Set before the
# compositor starts: GNOME Shell starts the portal itself.
case "$COMP" in
  sway|sway-csd) PORTAL_DESKTOP=sway ;;
  kwin) PORTAL_DESKTOP=KDE ;;
  gnome) PORTAL_DESKTOP=GNOME ;;
  *) PORTAL_DESKTOP="" ;;
esac
if [ -n "$PORTAL_DESKTOP" ]; then
  export XDG_CURRENT_DESKTOP="$PORTAL_DESKTOP" XDG_SESSION_TYPE=wayland
  dbus-update-activation-environment XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_BACKEND=wayland QT_QPA_PLATFORM=wayland \
    >> "$OUT/steps.log" 2>&1
fi
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
    # KWin starts the portal (and its KDE backend, which needs KWin's display) right away.
    dbus-update-activation-environment WAYLAND_DISPLAY=fmxw-kwin >> "$OUT/steps.log" 2>&1
    timeout 1400 kwin_wayland --socket fmxw-kwin --width 1280 --height 800 --no-lockscreen --no-global-shortcuts \
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
    timeout 1400 kwin_wayland --virtual --socket fmxw-kwin --width 1280 --height 800 --scale "$SCALE" --no-lockscreen \
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
    # GNOME Shell starts the portal (and with it xdg-desktop-portal-gnome, which needs the display) right away.
    dbus-update-activation-environment WAYLAND_DISPLAY=fmxw-gnome >> "$OUT/steps.log" 2>&1
    # xdg-desktop-portal-gnome hands file dialogs to Nautilus, which refuses to run as root (these tests run as
    # root): GTK's file chooser (xdg-desktop-portal-gtk) under GNOME Shell instead.
    mkdir -p "$XDG_CONFIG_HOME/xdg-desktop-portal"
    printf '[preferred]\ndefault=gnome;gtk;\norg.freedesktop.impl.portal.FileChooser=gtk\n' \
      > "$XDG_CONFIG_HOME/xdg-desktop-portal/gnome-portals.conf"
    timeout 1400 gnome-shell --headless --virtual-monitor "$(calc "1280 * $SCALE")x$(calc "800 * $SCALE")" \
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
    # Input goes to the shell itself until its startup animation is over.
    i=0
    until gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
      '!Main.layoutManager._startingUp' 2>/dev/null | grep -q true; do
      sleep 0.2; i=$((i + 1)); [ $i -gt 300 ] && break
    done
    note "gnome-shell started up: $(gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
      --method org.gnome.Shell.Eval '!Main.layoutManager._startingUp' 2>&1) after $((i / 5)) s"
    export WAYLAND_DISPLAY=fmxw-gnome
    INSET_L=4; INSET_T=30
    CAN_DRIVE=1; KIND=gnome
    ;;
  *)
    echo "unknown compositor $COMP"; exit 2 ;;
esac
wayland-info > "$OUT/wayland-info.txt" 2>&1

# A session bus without services (nothing is D-Bus activated there): no portal, so the self-test and the scenario
# get FMX's own file dialogs.
cat > "$RT/nosvc.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$RT/nosvc-bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
timeout 1400 dbus-daemon --config-file="$RT/nosvc.conf" --nofork > "$OUT/nosvc-bus.log" 2>&1 &
PIDS="$PIDS $!"
NOSVC="unix:path=$RT/nosvc-bus"
# The folder the file dialogs start in (a path the test can type: digits and lower case).
DLG="/tmp/fmxwdlg$$"
mkdir -p "$DLG/sub"
for f in alpha.txt beta.txt gamma.log; do echo "$f" > "$DLG/$f"; done

# The helper (input, clipboard, windows, screenshots) for the compositors it knows.
if [ -n "$KIND" ]; then
  mkfifo "$RT/cmd" "$RT/ans"
  LAYOUT="1280 800" timeout 1400 python3 "$HERE/wltool.py" serve "$KIND" "$RT/cmd" "$RT/ans" > "$OUT/wltool.log" 2>&1 &
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

want() { case " $PARTS " in *" $1 "*) return 0 ;; esac; return 1; }

# 1. The self-test.
if want selftest; then
  PLOG="$OUT/selftest.log"
  mkdir -p "$OUT/selftest-frames"
  (cd "$PDIR" && DBUS_SESSION_BUS_ADDRESS="$NOSVC" FMXWAYLAND_LOG=2 FMXWAYLAND_DUMP_DIR="$OUT/selftest-frames" \
    timeout 120 "$PROG" --selftest --quit-after=90 > "$PLOG" 2>&1; echo "exit=$?" >> "$PLOG") &
  SELF=$!
  if wait_log 'selftest: drop-down open' 1 30; then
    sleep 0.4
    shot selftest-dropdown
  fi
  wait $SELF
fi

# 3. The window frame service without input (tests\compositors.ps1 checks the log); a screenshot while the
# undecorated window has its drop-down open.
if want frame-selftest; then
  PLOG="$OUT/frame-selftest.log"
  mkdir -p "$OUT/frame-selftest-frames"
  (cd "$PDIR" && FMXWAYLAND_LOG=2 FMXWAYLAND_DUMP_DIR="$OUT/frame-selftest-frames" timeout 90 "$PROG" \
    --own-titlebar --selftest --quit-after=40 > "$PLOG" 2>&1; echo "exit=$?" >> "$PLOG") &
  SELF=$!
  # (Once the compositor has configured the popup: it stays open about 3 seconds.)
  if wait_log 'selftest: drop-down open' 1 30 && wait_log 'popup configure' 1 3; then
    sleep 1.2
    shot frame-selftest-dropdown
  fi
  wait $SELF
fi

# 4. Popups opened before their window is mapped: before its first configure (a timer), while it paints its first
# frame, in FormCreate before it is shown. They must wait for it (tests\compositors.ps1 checks logs and screenshots).
if want early; then
  for V in early-popup early-popup=paint early-popup=create; do
    N="${V//=/-}"
    PLOG="$OUT/$N.log"
    (cd "$PDIR" && FMXWAYLAND_LOG=2 timeout 60 "$PROG" "--$V" --quit-after=6 > "$PLOG" 2>&1; \
      echo "exit=$?" >> "$PLOG") &
    E=$!
    # (FMX closes the popups of a form when the compositor activates it.)
    if wait_log 'popup configure|form activated' 1 20; then
      sleep 1
      shot "$N"
    fi
    wait $E
  done
fi

finish() {
  [ -n "$KIND" ] && t quit
  rm -rf "$DLG"
  kill $PIDS 2>/dev/null; wait 2>/dev/null
  exit 0
}

MAIN="FMXWayland Hello"
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
# Waits until the shell takes no input itself (GNOME Shell's overview can still be up after a slow start).
settle() { local i; for i in 1 2 3; do t settle; [ "$ANS" = settled ] && return 0; done; return 1; }
# Waits until the compositor has a window of that title with a size (seconds).
wait_window() { # title seconds
  local i=0
  while [ $i -lt $(( ${2:-5} * 5 )) ]; do
    if t geometry "$1"; then
      set -- "$1" "${2:-5}" $ANS
      # (KWin gives fractional coordinates at fractional scales.)
      [ "${5%%.*}" -gt 0 ] 2>/dev/null && [ "${6%%.*}" -gt 0 ] 2>/dev/null && return 0
    fi
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
# Waits until the compositor has no window of that title any more (seconds).
wait_window_gone() { # title seconds
  local i=0
  while [ $i -lt $(( ${2:-5} * 5 )) ]; do
    t geometry "$1" || return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# 2. The scenario.
run_scenario() {
PLOG="$OUT/program.log"
(cd "$PDIR" && DBUS_SESSION_BUS_ADDRESS="$NOSVC" FMXWAYLAND_LOG=${FMXW_LOG:-2} timeout 170 "$PROG" --verbose \
  --dialog-dir="$DLG" --quit-after=150 > "$PLOG" 2>&1; echo "exit=$?" >> "$PLOG") &
APP=$!
check "window shown" wait_log 'FMXWayland: debug: configure "FMXWayland Hello": [1-9]' 1 30
sleep 1
settle
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

# FMX's own file dialogs (the program's bus has no portal), driven by input. Its client area: the list from 88
# (rows of 28: sub/, alpha.txt, beta.txt for *.txt), the name 130 above the bottom, the buttons 28 above it (accept
# 92 from the right edge, cancel 235).
dialog_origin() { # title: CX, CY and the client size DW x DH of a dialog window
  t geometry "$1" || return 1
  set -- $ANS
  CX=$(calc "$1 + $INSET_L"); CY=$(calc "$2 + $INSET_T")
  DW=$(calc "$3 - 2 * $INSET_L"); DH=$(calc "$4 - $INSET_T - $INSET_L")
  note "client area of the dialog at $CX,$CY, ${DW}x$DH"
}
click_at 75 481
check "file dialog without a portal: FMX's own" wait_log 'portal: no file dialog \(.*ServiceUnknown' 1 4
# (The geometry a moment after the window appears: sway may still be adding its title bar or switching it to the
# program's decorations, which takes longer.)
DLG_SETTLE=0.8
[ "$COMP" = sway-csd ] && DLG_SETTLE=2.5
if wait_window "Hello: open a file" 5 && sleep $DLG_SETTLE && dialog_origin "Hello: open a file"; then
  shot 05a-fmx-open-dialog
  at 100 160; sleep 0.2; t click; sleep 0.08; t click
  if ! check "FMX file dialog: a double click opens a file" \
    wait_log "open dialog result True files \"?$DLG/beta.txt\"? filter 1" 1 4; then
    t key escape; sleep 0.5
  fi
else
  result FAIL "FMX file dialog found by the compositor"
fi
CX=$MX; CY=$MY
click_at 195 481
if wait_window "Hello: save a file" 5 && sleep $DLG_SETTLE && dialog_origin "Hello: save a file"; then
  click_at 400 $((DH - 130))
  t key ctrl+a; t type "saved.txt"
  sleep 0.3
  shot 05b-fmx-save-dialog
  click_at $((DW - 92)) $((DH - 28))
  if ! check "FMX file dialog: save under a typed name" \
    wait_log "save dialog result True files \"?$DLG/saved.txt\"?" 1 4; then
    t key escape; sleep 0.5
  fi
else
  result FAIL "FMX save dialog found by the compositor"
fi
CX=$MX; CY=$MY
click_at 320 481
if wait_window "Hello: select a folder" 5 && sleep $DLG_SETTLE && dialog_origin "Hello: select a folder"; then
  t key escape
  if ! check "FMX file dialog: Escape cancels" wait_log 'folder dialog result False' 1 3; then
    click_at $((DW - 235)) $((DH - 28))
  fi
else
  result FAIL "FMX folder dialog found by the compositor"
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
check "no errors in the program's logs" bash -c "! grep -s -q -E 'protocol error|FMXWayland: error' '$PLOG' '$OUT/selftest.log'"
}

# 3. Hello --own-titlebar with input: IFMXWaylandWindowFrame as a program with its own title bar uses it.
FT="FMXWayland own title bar"
GX=0; GY=0; GW=0; GH=0
fgeo() { t geometry "$FT" || return 1; set -- $ANS; GX=$1; GY=$2; GW=$3; GH=$4; }
fat() { t move "$(calc "$GX + $1")" "$(calc "$GY + $2")"; }
# The states and capabilities the listener got last ("activated maximized", "window_menu maximize ...").
last_states() { grep 'frame: states' "$PLOG" | tail -1 | sed -E 's/.*frame: states \$[0-9A-F]+ \(([^)]*)\).*/\1/'; }
has_cap() { grep 'frame: states' "$PLOG" | tail -1 | sed -E 's/.*capabilities //' | grep -q -w -E "$1|unknown"; }
wait_states() { # [!]pattern [seconds]: until the last states match (or, with !, do not)
  local i=0 n=$(( ${2:-4} * 10 )) p="${1#!}"
  while [ $i -lt $n ]; do
    if [ "${1:0:1}" = '!' ]; then last_states | grep -q -w "$p" || return 0
    else last_states | grep -q -w "$p" && return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
checkd() { # name detail command...
  local name="$1" detail="$2"; shift 2
  if "$@"; then result PASS "$name" "$detail"; else result FAIL "$name" "$detail"; fi
}
in_range() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
# Press, wait until the program has asked the compositor (move/resize), drag in steps, release. "kick": a first
# small motion (a move starts when the pointer is dragged past 4 px, as with GTK).
drag() { # x y dx dy [kick] (relative to the window)
  fat "$1" "$2"; sleep 0.2; t down; sleep 0.5
  if [ "${5:-}" = kick ]; then fat "$(calc "$1 + 6")" "$2"; sleep 0.4; fi
  local i
  for i in 1 2 3 4 5 6 7 8; do fat "$(calc "$1 + $3 * $i / 8")" "$(calc "$2 + $4 * $i / 8")"; sleep 0.05; done
  sleep 0.2; t up; sleep 0.8
}
dclick() { # x y
  fat "$1" "$2"; sleep 0.2; t dclick; sleep 1
}

run_frame() {
PLOG="$OUT/frame.log"
(cd "$PDIR" && FMXWAYLAND_LOG=${FMXW_LOG:-2} timeout 200 "$PROG" --own-titlebar --quit-after=180 > "$PLOG" 2>&1; \
  echo "exit=$?" >> "$PLOG") &
APP=$!
check "own title bar: window shown" wait_log "configure \"$FT\": [0-9]" 1 30
sleep 1
settle
[ "$KIND" = gnome ] && t state
check "own title bar: decorations off (SetDecorated False)" wait_log 'frame: decorated False' 1 1
fgeo
check "own title bar: window geometry = the program's size 720x460" [ "$GW $GH" = "720 460" ]
t frame "$FT"; set -- $ANS
checkd "own title bar: no title bar of the compositor (its frame = window geometry)" "frame $3x$4" \
  [ "$3 $4" = "$GW $GH" ]
check "own title bar: activated (listener)" wait_states activated 4
fat 200 120; sleep 0.3
shot frame-01-start

# Move: a press on the caption and a drag.
X0=$GX; Y0=$GY
drag 300 18 120 80 kick
check "own title bar: BeginMove True (press on the caption)" wait_log 'frame: BeginMove True' 1 2
check "own title bar: the move starts with the drag" wait_log 'move of "FMXWayland own title bar" starts \(dragged\)' 1 2
fgeo
checkd "own title bar: drag on the caption moves the window" "by $((GX - X0)),$((GY - Y0))" \
  bash -c "[ $((GX - X0)) -ge 110 ] && [ $((GX - X0)) -le 130 ] && [ $((GY - Y0)) -ge 70 ] && [ $((GY - Y0)) -le 90 ]"

# Resize: the bottom right grip.
W0=$GW; H0=$GH
drag $((GW - 4)) $((GH - 4)) 64 40
check "own title bar: BeginResize 10 True (press on the corner grip)" wait_log 'frame: BeginResize 10 True' 1 2
fgeo
checkd "own title bar: drag on the corner resizes the window" "${W0}x$H0 -> ${GW}x$GH" \
  bash -c "[ $((GW - W0)) -ge 54 ] && [ $((GW - W0)) -le 74 ] && [ $((GH - H0)) -ge 30 ] && [ $((GH - H0)) -le 50 ]"
check "own title bar: the client area follows the window geometry" wait_log "resize ${GW}x${GH} state 0" 1 3
fat 200 120; sleep 0.3
shot frame-02-moved-resized

# Maximize and restore: the maximize button, then a double click on the caption; the window comes back to its size
# and place.
if has_cap maximize; then
  RX=$GX; RY=$GY; RW=$GW; RH=$GH
  fat $((GW - 69)) 18; sleep 0.2; t click; sleep 1
  check "own title bar: maximize button" wait_states maximized 4
  sleep 0.5
  fgeo
  fat $((GW - 69)) 18; sleep 0.2; t click; sleep 1
  check "own title bar: restore button" wait_states '!maximized' 4
  sleep 0.5
  fgeo
  checkd "own title bar: restore button: size and place before" "${GW}x$GH at $GX,$GY (before ${RW}x$RH at $RX,$RY)" \
    [ "$GX $GY $GW $GH" = "$RX $RY $RW $RH" ]
  N=$(count_log 'double click: SetMaximized True')
  dclick 300 18
  check "own title bar: double click: SetMaximized True" wait_log 'double click: SetMaximized True' $((N + 1)) 2
  check "own title bar: maximized (listener)" wait_states maximized 4
  sleep 0.5
  fgeo
  fat 200 120; sleep 0.3
  shot frame-03-maximized
  N=$(count_log 'double click: SetMaximized False')
  dclick 300 18
  check "own title bar: double click again: SetMaximized False" wait_log 'double click: SetMaximized False' $((N + 1)) 2
  check "own title bar: restored (listener)" wait_states '!maximized' 4
  sleep 0.5
  fgeo
  checkd "own title bar: double click: size and place before" "${GW}x$GH at $GX,$GY (before ${RW}x$RH at $RX,$RY)" \
    [ "$GX $GY $GW $GH" = "$RX $RY $RW $RH" ]
else
  result SKIP "own title bar: maximize and restore" "no maximize in the window manager's capabilities"
  dclick 300 18
  check "own title bar: double click without maximize: nothing asked" wait_log 'double click: no maximize capability' 1 2
fi

# The window menu of the compositor.
fgeo
if has_cap window_menu; then
  fat 200 18; sleep 0.2; t click right; sleep 1.2
  check "own title bar: right click: ShowWindowMenu True" wait_log 'frame: ShowWindowMenu at 200,18 True' 1 2
  shot frame-04-window-menu
  t key esc; sleep 0.8
  t settle
else
  result SKIP "own title bar: right click shows the window menu" "no window_menu in the window manager's capabilities"
fi

# Activation: another window takes it and gives it back.
fgeo
fat 306 169; sleep 0.2; t click; sleep 1.2
check "own title bar: other window shown" wait_log 'other window 1 shown' 1 3
check "own title bar: not activated while the other window is (listener)" wait_states '!activated' 4
fat 200 120; sleep 0.3
shot frame-05-inactive
t close "Other window 1"
check "own title bar: activated again (listener)" wait_states activated 4

# The drop-down of the undecorated window: placed where asked, an item clicked at its place.
fgeo
N=$(count_log 'popup configure')
fat 116 169; sleep 0.2; t click; sleep 0.6
check "own title bar: combo box popup opens" wait_log 'popup configure' $((N + 1)) 3
P=$(grep 'popup configure' "$PLOG" | tail -1)
check "own title bar: popup placed where asked" bash -c "echo '$P' | grep -q -E 'configure (-?[0-9]+),(-?[0-9]+) [0-9]+x[0-9]+ \\(asked \\1,\\2 '"
fat 60 230; sleep 0.2; t click; sleep 0.5
check "own title bar: popup item chosen by a click (Blue)" wait_log 'combo Blue' 1 3

# Minimize; the compositor shows the window again.
fgeo
if has_cap minimize; then
  if has_cap maximize; then MX=$((GW - 115)); else MX=$((GW - 69)); fi
  fat $MX 18; sleep 0.2; t click; sleep 1
  check "own title bar: minimize button: Minimize" wait_log 'frame: Minimize' 1 2
  t minimized "$FT"
  check "own title bar: the compositor minimized the window" [ "$ANS" = 1 ]
  shot frame-06-minimized
  t unminimize "$FT"; sleep 1
  t minimized "$FT"
  check "own title bar: shown again by the compositor" [ "$ANS" = 0 ]
  check "own title bar: activated after minimize (listener)" wait_states activated 4
  t settle
else
  result SKIP "own title bar: minimize" "no minimize in the window manager's capabilities"
fi

# The close button.
fgeo
fat $((GW - 23)) 18; sleep 0.2; t click
check "own title bar: close button" wait_log 'frame: close button' 1 3
check "own title bar: closed" wait_log '\[hello\] destroyed' 1 5
wait $APP
check "own title bar: clean exit" grep -q 'exit=0' "$PLOG"
check "own title bar: no errors in the program's log" bash -c "! grep -q -E 'protocol error|FMXWayland: error' '$PLOG'"
}

# 5. The portal's file dialog: xdg-desktop-portal and the backend for XDG_CURRENT_DESKTOP, started by D-Bus
# activation on the session bus of this run.
run_portal() {
if [ ! -x /usr/libexec/xdg-desktop-portal ]; then
  result SKIP "portal file dialog" "xdg-desktop-portal is not installed"
else
  # What the activated portal and its backend get: this compositor, this desktop, Wayland. Portal backends of this
  # session that were started for another display (KWin's host sway) are ended: D-Bus activation starts them again
  # with this environment. (Not the others: GNOME Shell's portal backend must stay the one GNOME Shell started.)
  dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR HOME \
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME GDK_BACKEND=wayland QT_QPA_PLATFORM=wayland >> "$OUT/steps.log" 2>&1
  for p in $(pgrep -f 'xdg-desktop-portal-'); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$RT" &&
      ! tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; then
      note "ending $(tr '\0' ' ' < "/proc/$p/cmdline") ($p): another display"
      kill "$p" 2>/dev/null
    fi
  done
  sleep 1
  # A portal whose backend could not start (KWin starts the portal before its own display is there) offers no
  # FileChooser: it is started again.
  has_file_chooser() {
    timeout 15 gdbus call --session --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Properties.Get \
      org.freedesktop.portal.FileChooser version >> "$OUT/steps.log" 2>&1
  }
  if ! has_file_chooser; then
    for p in $(pgrep -f 'xdg-desktop-portal'); do
      if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$RT"; then
        note "ending $(tr '\0' ' ' < "/proc/$p/cmdline") ($p): no FileChooser"
        kill "$p" 2>/dev/null
      fi
    done
    sleep 1
    has_file_chooser
  fi
  PLOG="$OUT/portal.log"
  # Each line with the time it was written (the portal's own log is in run.log).
  (cd "$PDIR" && FMXWAYLAND_LOG=2 timeout 240 "$PROG" --verbose --dialog-dir="$DLG" --quit-after=220 \
    --quit-in-folder-dialog=10 2>&1 |
    python3 -u -c 'import sys, time
for l in sys.stdin.buffer:
    sys.stdout.buffer.write(time.strftime("%H:%M:%S ").encode() + l); sys.stdout.buffer.flush()' > "$PLOG"
    echo "exit=${PIPESTATUS[0]}" >> "$PLOG") &
  APP=$!
  check "portal: window shown" wait_log 'FMXWayland: debug: configure "FMXWayland Hello": [1-9]' 1 30
  # sway with "border csd" switches the window to the program's decorations after it appears.
  [ "$COMP" = sway-csd ] && wait_log 'decoration mode 1 of "FMXWayland Hello"' 1 5 && sleep 2
  sleep 1
  settle
  origin "$MAIN"
  MX=$CX; MY=$CY
  FOREIGN=0
  grep -q zxdg_exporter_v2 "$OUT/wayland-info.txt" && FOREIGN=1
  # The program's windows take no input while the dialog is open: a click where the dialog does not cover them.
  blocked_check() { # dialog title
    local dx dy dw dh px py
    t geometry "$1" || return 1
    set -- $ANS; dx=$1; dy=$2; dw=$3; dh=$4
    px=$(calc "$MX + 75"); py=$(calc "$MY + 211")
    if [ "$px" -ge "$dx" ] && [ "$px" -lt $((dx + dw)) ] && [ "$py" -ge "$dy" ] && [ "$py" -lt $((dy + dh)) ]; then
      result SKIP "portal: the program's windows blocked meanwhile" "its button lies under the dialog"
      return 0
    fi
    N=$(count_log '\[hello\] click ')
    t move "$px" "$py"; sleep 0.15; t click; sleep 0.8
    check "portal: the program's windows blocked meanwhile" [ "$(count_log '\[hello\] click ')" = "$N" ]
  }
  # Open: the dialog, its parent, the program meanwhile, a file typed with the keyboard.
  click_at 75 481
  if ! check "portal: OpenFile request" wait_log 'portal: OpenFile request' 1 20; then
    # FMX's dialog instead (the reason is in the log): closed.
    wait_window "Hello: open a file" 5 && t key escape
  elif [ $FOREIGN = 1 ]; then
    check "portal: the program's window exported as the parent (xdg-foreign)" wait_log 'parent "wayland:[^"]+"' 1 1
  else
    result SKIP "portal: the program's window exported as the parent (xdg-foreign)" "no zxdg_exporter_v2"
  fi
  if [ "$(count_log 'portal: OpenFile request')" -ge 1 ] &&
    check "portal: its dialog window shown" wait_window "Hello: open a file" 25; then
    sleep 2
    shot 08-portal-open
    if [ $FOREIGN = 1 ] && [ "$KIND" != sway ]; then
      t parent "Hello: open a file"
      check "portal: the dialog is a child of the program's window" [ "$ANS" = "$MAIN" ]
    fi
    check "portal: the program's loop runs meanwhile (timer, painting)" wait_log 'timer during the dialog' 1 4
    blocked_check "Hello: open a file"
    # As under a modal form, the compositor's close of the blocked main window is ignored.
    t close "$MAIN"
    sleep 1.5
    check "portal: the main window ignores a close meanwhile" bash -c "! grep -q 'hello\\] destroyed' '$PLOG'"
    t settle
    # GTK's choosers take a path after Ctrl+L; KDE's has its name field focused.
    [ "$KIND" != kwin ] && { t key ctrl+l; sleep 0.5; }
    t type "$DLG/beta.txt"
    sleep 0.5
    shot 08b-portal-typed
    t key return
    if ! check "portal: a file chosen with the keyboard" \
      wait_log "open dialog result True files \"?$DLG/beta.txt\"? filter 1" 1 8; then
      t key escape; sleep 1
    fi
  fi
  wait_window_gone "Hello: open a file" 5
  # Save: a name typed into the dialog's name field.
  CX=$MX; CY=$MY
  click_at 195 481
  if wait_log 'portal: SaveFile request' 1 10 && wait_window "Hello: save a file" 15; then
    sleep 2
    t key ctrl+a; t type "portal.txt"
    sleep 0.5
    shot 08c-portal-save
    t key return
    if ! check "portal: save under a typed name" wait_log "save dialog result True files \"?$DLG/portal.txt\"?" 1 8
    then
      t key escape; sleep 1
    fi
  else
    result FAIL "portal: save dialog shown"
    wait_window "Hello: save a file" 3 && t key escape
  fi
  wait_window_gone "Hello: save a file" 5
  # Escape: cancelled.
  CX=$MX; CY=$MY
  N=$(count_log 'open dialog result False')
  click_at 75 481
  if wait_log 'portal: OpenFile request' 2 10 && wait_window "Hello: open a file" 15; then
    sleep 1.5
    t key escape
    check "portal: Escape cancels" wait_log 'open dialog result False' $((N + 1)) 6
  else
    result FAIL "portal: second open dialog shown"
    wait_window "Hello: open a file" 3 && t key escape
  fi
  wait_window_gone "Hello: open a file" 5
  # After the dialogs the program takes input again.
  CX=$MX; CY=$MY
  sleep 0.5
  N=$(count_log '\[hello\] click ')
  click_at 75 211
  check "portal: the main form takes input again" wait_log '\[hello\] click ' $((N + 1)) 3
  # Folder selection; the program ends while the dialog is open (--quit-in-folder-dialog): it closes its request and
  # the portal's dialog goes away. Another client may not close the request (the portal checks the caller).
  click_at 320 481
  if wait_log 'portal: OpenFile request' 3 10 && wait_window "Hello: select a folder" 15; then
    sleep 1
    shot 08d-portal-folder
    H=$(grep -o 'portal: OpenFile request [^ ]*' "$PLOG" | tail -1 | cut -d' ' -f4)
    note "Request.Close of $H by another client"
    timeout 10 gdbus call --session --dest org.freedesktop.portal.Desktop --object-path "$H" \
      --method org.freedesktop.portal.Request.Close > "$RT/close.txt" 2>&1
    cat "$RT/close.txt" >> "$OUT/steps.log"
    check "portal: another client cannot close the program's request" grep -q AccessDenied "$RT/close.txt"
    check "portal: the program ends during the dialog" wait_log 'closing during the folder dialog' 1 15
    check "portal: it closes its request (cancelled)" wait_log 'portal: file dialog cancelled' 1 5
    check "portal: the dialog window goes away with it" wait_window_gone "Hello: select a folder" 8
  else
    result FAIL "portal: folder dialog shown"
    wait_window "Hello: select a folder" 3 && t key escape
    sleep 1
    t close "$MAIN"
  fi
  check "portal: the program ended" wait_log '\[hello\] destroyed' 1 8
  wait $APP
  check "portal: clean exit" grep -q 'exit=0' "$PLOG"
  check "portal: no errors in the program's log" bash -c "! grep -q -E 'protocol error|FMXWayland: error' '$PLOG'"
fi
}

if [ "$CAN_DRIVE" = 1 ]; then
  want scenario && run_scenario
  want frame && run_frame
  want portal && [ -n "$PORTAL_DESKTOP" ] && run_portal
else
  note "no input injection on $COMP: no scenario"
fi
finish
