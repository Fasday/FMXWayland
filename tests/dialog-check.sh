#!/bin/sh
# Runs tests/DialogCheck on a private headless Weston with a private session bus that listens on an abstract socket
# and on a path (tests\dialog-check.ps1). The program gets an address list whose first entry does not exist, the
# path in DC_BUS_PATH and $XDG_RUNTIME_DIR/bus (for unix:runtime=yes).
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
weston --backend=headless --renderer=pixman --width=1280 --height=800 --socket=fmxw-test --idle-time=0 \
  --log="$OUT/weston.log" 2> "$OUT/weston.stderr" &
WPID=$!
i=0
while { [ ! -S "$RT/fmxw-test" ] || [ ! -S "$RT/dc-bus" ]; } && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
ln -s "$RT/dc-bus" "$RT/bus"
export WAYLAND_DISPLAY=fmxw-test
cd "$(dirname "$PROG")"
DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/missing-bus;unix:abstract=$ABSTRACT,guid=00112233445566778899aabbccddeeff" \
  DC_BUS_PATH="$RT/dc-bus" FMXWAYLAND_LOG=2 timeout 60 "$PROG" > "$OUT/program.log" 2>&1
echo "exit=$?" >> "$OUT/program.log"
kill $WPID $BPID 2>/dev/null
wait 2>/dev/null
rm -rf "$RT"
