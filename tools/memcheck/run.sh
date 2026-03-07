#!/usr/bin/env bash
set -euo pipefail

THRESHOLD=${1:-1048576}  # default 1MB
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="$PROJECT_DIR/_build/native/debug/build/tools/memcheck/memcheck.exe"

echo "=== Building native target ==="
moon -C "$PROJECT_DIR" build --target native

echo ""
echo "=== Running memcheck (direct) ==="
"$BIN"

echo ""
echo "=== Valgrind massif ==="
MASSIF_OUT=$(mktemp)
valgrind --tool=massif --massif-out-file="$MASSIF_OUT" "$BIN"
PEAK=$(grep "mem_heap_B" "$MASSIF_OUT" | sort -t= -k2 -n | tail -1 | cut -d= -f2)
echo "Peak heap: ${PEAK} bytes (threshold: ${THRESHOLD})"
if [ "$PEAK" -gt "$THRESHOLD" ]; then
  echo "FAIL: peak heap ${PEAK} exceeds ${THRESHOLD} byte threshold"
  rm -f "$MASSIF_OUT"
  exit 1
fi
echo "PASS"
rm -f "$MASSIF_OUT"

echo ""
echo "=== Valgrind dhat ==="
DHAT_OUT=$(mktemp)
valgrind --tool=dhat --dhat-out-file="$DHAT_OUT" "$BIN" 2>&1 | grep -E "Total:|At t-gmax:|At t-end:"
rm -f "$DHAT_OUT"

echo ""
echo "=== All checks passed ==="
