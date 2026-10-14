#!/bin/sh
# Inside a container (tests\glibc-compat.ps1): writes the distribution, its glibc and Weston versions, then runs the
# program on a private headless Weston at scale 1 (weston-headless.sh).
#
#   glibc-compat.sh <out-dir> <program> [args...]
set -u
OUT="$1"; shift
mkdir -p "$OUT"
. /etc/os-release
echo "$PRETTY_NAME, glibc $(getconf GNU_LIBC_VERSION | awk '{print $2}'), $(weston --version 2>&1 | head -1)" > "$OUT/system.txt"
sh "$(dirname "$0")/weston-headless.sh" "$OUT" 1 "$@"
