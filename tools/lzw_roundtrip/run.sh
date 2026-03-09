#!/usr/bin/env bash
set -euo pipefail

SIZE="50G"
ORDER="LSB"
LIT_WIDTH="8"
RSS_LIMIT_KB=$((256 * 1024))
MONITOR_INTERVAL_SECS="0.20"
RUN_MASSIF=0
KEEP_ARTIFACTS=0
WORKDIR=""

usage() {
  cat <<'USAGE'
Usage: tools/lzw_roundtrip/run.sh [options]

Manual native LZW round-trip harness.
Creates a sparse input file, runs native compress/decompress commands,
records peak RSS for each phase, and verifies the round-trip with a CRC32.

Options:
  --size SIZE               Logical size for the sparse input file (default: 50G)
  --order ORDER             LZW bit order: LSB or MSB (default: LSB)
  --lit-width WIDTH         Literal width passed to the CLI (default: 8)
  --rss-limit-kb KB         Fail if a phase exceeds this RSS limit (default: 262144)
  --monitor-interval SEC    ps sampling interval in seconds (default: 0.20)
  --workdir PATH            Keep artifacts in PATH instead of a temporary dir
  --keep-artifacts          Do not delete the workdir on exit
  --massif                 Also run valgrind massif for each phase
  -h, --help                Show this message

Notes:
  - The input is created with `truncate`, so the source file is sparse.
  - The current `tools/lzw_roundtrip` CLI still uses the in-memory bytes API.
    The 50GB run is expected to fail until the streaming `lzw.compress(src,dst)`
    and `lzw.decompress(src,dst)` entry points replace that implementation.
  - `--massif` is practical for smaller runs. On a real 50GB pass it will be slow.
USAGE
}

fmt_bytes() {
  local bytes=$1
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1099511627776) {
      printf "%.2f TiB", b / 1099511627776
    } else if (b >= 1073741824) {
      printf "%.2f GiB", b / 1073741824
    } else if (b >= 1048576) {
      printf "%.2f MiB", b / 1048576
    } else if (b >= 1024) {
      printf "%.2f KiB", b / 1024
    } else {
      printf "%d B", b
    }
  }'
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

while (($# > 0)); do
  case "$1" in
    --size)
      SIZE="$2"
      shift 2
      ;;
    --order)
      ORDER="$2"
      shift 2
      ;;
    --lit-width)
      LIT_WIDTH="$2"
      shift 2
      ;;
    --rss-limit-kb)
      RSS_LIMIT_KB="$2"
      shift 2
      ;;
    --monitor-interval)
      MONITOR_INTERVAL_SECS="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      shift
      ;;
    --massif)
      RUN_MASSIF=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd moon
require_cmd truncate
require_cmd stat
require_cmd df
require_cmd ps
require_cmd awk
require_cmd grep
if (( RUN_MASSIF == 1 )); then
  require_cmd valgrind
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="$PROJECT_DIR/_build/native/debug/build/tools/lzw_roundtrip/lzw_roundtrip.exe"

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/lzw-roundtrip.XXXXXX")"
else
  mkdir -p "$WORKDIR"
fi

INPUT="$WORKDIR/input.bin"
COMPRESSED="$WORKDIR/input.lzw"
RESTORED="$WORKDIR/restored.bin"

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

check_free_space() {
  local required_bytes=$1
  local available_kb
  available_kb=$(df -Pk "$WORKDIR" | awk 'NR==2 { print $4 }')
  local available_bytes=$(( available_kb * 1024 ))
  if (( available_bytes < required_bytes )); then
    echo "FAIL: workdir filesystem has $(fmt_bytes "$available_bytes") free; need at least $(fmt_bytes "$required_bytes") for the restored file." >&2
    echo "Choose a different --workdir or free more space." >&2
    exit 1
  fi
}

run_and_monitor() {
  local label=$1
  shift
  local log="$WORKDIR/${label}.log"
  local peak_kb=0

  echo
  echo "=== $label ==="
  echo "Command: $*"
  "$@" >"$log" 2>&1 &
  local pid=$!
  echo "PID: $pid"

  while kill -0 "$pid" 2>/dev/null; do
    local rss_kb
    rss_kb=$(ps -o rss= -p "$pid" | awk 'NF { print $1 }')
    if [[ -n "$rss_kb" ]] && (( rss_kb > peak_kb )); then
      peak_kb=$rss_kb
    fi
    sleep "$MONITOR_INTERVAL_SECS"
  done

  set +e
  wait "$pid"
  local status=$?
  set -e

  echo "$peak_kb" >"$WORKDIR/${label}.rss_kb"
  echo "Peak RSS: $(fmt_bytes $(( peak_kb * 1024 )))"

  if (( status != 0 )); then
    echo "FAIL: $label exited with status $status" >&2
    echo "--- $label log ---" >&2
    cat "$log" >&2
    exit "$status"
  fi

  if (( peak_kb > RSS_LIMIT_KB )); then
    echo "FAIL: $label peak RSS $(fmt_bytes $(( peak_kb * 1024 ))) exceeded limit $(fmt_bytes $(( RSS_LIMIT_KB * 1024 )))" >&2
    exit 1
  fi
}

run_massif() {
  local label=$1
  shift
  local out="$WORKDIR/${label}.massif.out"

  echo
  echo "=== $label massif ==="
  valgrind --tool=massif --massif-out-file="$out" "$@" >"$WORKDIR/${label}.massif.log" 2>&1
  local peak
  peak=$(grep 'mem_heap_B=' "$out" | awk -F= 'BEGIN { max = 0 } $2 > max { max = $2 } END { print max }')
  echo "Massif peak heap: $(fmt_bytes "$peak")"
}

echo "=== Building native lzw_roundtrip tool ==="
moon -C "$PROJECT_DIR" build --target native tools/lzw_roundtrip

echo
printf '%s\n' 'NOTE: the current lzw file CLI is still bytes-based. The 50GB acceptance run is expected to fail until the streaming io redesign is implemented.'

echo
printf '%s\n' "Creating sparse input file: $INPUT ($SIZE logical size)"
truncate -s "$SIZE" "$INPUT"

IFS=$'\t' read -r source_size source_crc <<<"$($BIN fingerprint-file "$INPUT")"
check_free_space $(( source_size + 64 * 1024 * 1024 ))

echo "Source logical size: $(fmt_bytes "$source_size")"
echo "Source CRC32: $source_crc"
echo "RSS limit: $(fmt_bytes $(( RSS_LIMIT_KB * 1024 )))"
run_and_monitor compress "$BIN" compress-file "$INPUT" "$COMPRESSED" "$ORDER" "$LIT_WIDTH"

echo "Compressed size: $(fmt_bytes "$(stat -c %s "$COMPRESSED")")"
run_and_monitor decompress "$BIN" decompress-file "$COMPRESSED" "$RESTORED" "$ORDER" "$LIT_WIDTH"

IFS=$'\t' read -r restored_size restored_crc <<<"$($BIN fingerprint-file "$RESTORED")"
echo "Restored logical size: $(fmt_bytes "$restored_size")"
echo "Restored CRC32: $restored_crc"

if [[ "$source_size" != "$restored_size" ]]; then
  echo "FAIL: size mismatch: source=$source_size restored=$restored_size" >&2
  exit 1
fi

if [[ "$source_crc" != "$restored_crc" ]]; then
  echo "FAIL: CRC32 mismatch: source=$source_crc restored=$restored_crc" >&2
  exit 1
fi

if (( RUN_MASSIF == 1 )); then
  run_massif compress "$BIN" compress-file "$INPUT" "$COMPRESSED.massif" "$ORDER" "$LIT_WIDTH"
  run_massif decompress "$BIN" decompress-file "$COMPRESSED.massif" "$RESTORED.massif" "$ORDER" "$LIT_WIDTH"
fi

echo
echo "PASS: round-trip CRC32 and size match within the configured RSS limit"
echo "Artifacts: $WORKDIR"
