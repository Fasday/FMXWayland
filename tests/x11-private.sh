#!/bin/bash
# Called inside `unshare --mount`: give the test server writable Unix sockets without touching WSLg's mount.
set -euo pipefail
mount --make-rprivate /
mkdir -p /tmp/.X11-unix
mount -t tmpfs -o mode=1777 tmpfs /tmp/.X11-unix
exec bash "$@"
