#!/bin/sh
# Runs tests/DialogCheck on a private headless Weston with a private session bus that listens on an abstract socket
# and on a path (tests\dialog-check.ps1). The program gets an address list whose first entry does not exist, the
# path in DC_BUS_PATH and $XDG_RUNTIME_DIR/bus (for unix:runtime=yes), and in DC_PORTAL_BUS, DC_OLD_PORTAL_BUS two
# buses with a settings portal (tests/settings-portal.py).
#
#   dialog-check.sh <out-dir> <program>
set -u
OUT="$1"; PROG="$2"
mkdir -p "$OUT"
RT=$(mktemp -d /tmp/fmxw-rt.XXXXXX)
chmod 700 "$RT"
export XDG_RUNTIME_DIR="$RT"
unset DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
ABSTRACT="fmxw-dialogcheck-$$"
cat > "$RT/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:abstract=$ABSTRACT</listen>
  <listen>unix:path=$RT/dc-bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
timeout 120 dbus-daemon --config-file="$RT/bus.conf" --nofork > "$OUT/bus.log" 2>&1 &
BPID=$!
# Two more buses with a settings portal each (tests/settings-portal.py): a current one (ReadOne) and an old one (only
# Read). The program switches DBUS_SESSION_BUS_ADDRESS to them for its font checks.
HERE="$(cd "$(dirname "$0")" && pwd)"
for P in portal-bus old-portal-bus; do
  sed -e "s|<listen>.*</listen>||" -e "s|<auth>|<listen>unix:path=$RT/$P</listen><auth>|" "$RT/bus.conf" > "$RT/$P.conf"
  timeout 120 dbus-daemon --config-file="$RT/$P.conf" --nofork > "$OUT/$P.log" 2>&1 &
  BPID="$BPID $!"
done
i=0
while { [ ! -S "$RT/portal-bus" ] || [ ! -S "$RT/old-portal-bus" ]; } && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/portal-bus" timeout 120 python3 "$HERE/settings-portal.py" \
  'DejaVu Serif Bold 10.5' "$OUT/portal-calls.log" > "$OUT/portal.log" 2>&1 &
BPID="$BPID $!"
DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/old-portal-bus" timeout 120 python3 "$HERE/settings-portal.py" \
  'DejaVu Serif Bold 10.5' "$OUT/old-portal-calls.log" --old > "$OUT/old-portal.log" 2>&1 &
BPID="$BPID $!"
i=0
while [ "$(cat "$OUT/portal-calls.log" "$OUT/old-portal-calls.log" 2>/dev/null | grep -c ready)" -lt 2 ] &&
  [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
weston --backend=headless --renderer=pixman --width=1280 --height=800 --socket=fmxw-test --idle-time=0 \
  --log="$OUT/weston.log" 2> "$OUT/weston.stderr" &
WPID=$!
i=0
while { [ ! -S "$RT/fmxw-test" ] || [ ! -S "$RT/dc-bus" ]; } && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
ln -s "$RT/dc-bus" "$RT/bus"
export WAYLAND_DISPLAY=fmxw-test
cd "$(dirname "$PROG")"
DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/missing-bus;unix:abstract=$ABSTRACT,guid=00112233445566778899aabbccddeeff" \
  DC_BUS_PATH="$RT/dc-bus" DC_PORTAL_BUS="unix:path=$RT/portal-bus" DC_OLD_PORTAL_BUS="unix:path=$RT/old-portal-bus" \
  FMXWAYLAND_LOG=2 timeout 60 "$PROG" > "$OUT/program.log" 2>&1
echo "exit=$?" >> "$OUT/program.log"
kill $WPID $BPID 2>/dev/null
wait 2>/dev/null
rm -rf "$RT"
