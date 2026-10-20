#!/bin/bash
# Run inside an X11 session; exercises both INCR directions against xclip.
# x11-clipboard.sh <out-dir> <BackendCheck executable>
set -euo pipefail
OUT=$(realpath -m "$1")
PROG=$(realpath "$2")
mkdir -p "$OUT"
export FMXWAYLAND_BACKEND=x11
python3 - "$OUT/source.txt" <<'PY'
import sys
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    f.write('Native X11: Привет ✓\n' * 80000)
PY
"$PROG" write "$OUT/source.txt" >"$OUT/writer.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
for ((i=0; i<100; i++)); do
  grep -q '^ready' "$OUT/writer.log" && break
  kill -0 "$PID"
  sleep .05
done
timeout 8 xclip -selection clipboard -out -target UTF8_STRING >"$OUT/from-fmx.txt"
cmp "$OUT/source.txt" "$OUT/from-fmx.txt"
kill "$PID"
wait "$PID" 2>/dev/null || true
xclip -selection clipboard -in "$OUT/source.txt" 2>"$OUT/xclip.log"
timeout 8 "$PROG" read "$OUT/from-xclip.txt" >"$OUT/reader.log" 2>&1
# Delphi's UTF8 encoding may emit a BOM; compare decoded text.
python3 - "$OUT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
assert (p / 'source.txt').read_text(encoding='utf-8') == (p / 'from-xclip.txt').read_text(encoding='utf-8-sig')
PY
echo 'Cross-process UTF-8 / INCR clipboard: PASS'
