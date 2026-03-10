#!/usr/bin/env bash
set -euo pipefail

SIZE="1G"
SOURCE_KIND="zeros"
ORDER="LSB"
LIT_WIDTH="8"
MOON_MODE="release"
MONITOR_INTERVAL_SECS="0.20"
KEEP_ARTIFACTS=0
WORKDIR=""

usage() {
  cat <<'USAGE'
Usage: tools/lzw_bench.sh [options]

Benchmark MoonBit LZW against Go's compress/lzw on the same input.

Options:
  --size SIZE               Input size to generate (default: 1G)
  --source KIND             Input kind: zeros, sparse-zero, random (default: zeros)
  --order ORDER             LZW bit order: LSB or MSB (default: LSB)
  --lit-width WIDTH         Literal width passed to both implementations (default: 8)
  --moon-mode MODE          MoonBit build mode: release or debug (default: release)
  --monitor-interval SEC    ps sampling interval in seconds (default: 0.20)
  --workdir PATH            Keep artifacts in PATH instead of a temporary dir
  --keep-artifacts          Do not delete the workdir on exit
  -h, --help                Show this message

Notes:
  - build time is excluded from the timings
  - the benchmark warms the input cache before timing
  - the MoonBit side uses tools/lzw_roundtrip
  - the Go side uses a small helper built from compress/lzw
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
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

while (($# > 0)); do
  case "$1" in
    --size)
      SIZE="$2"
      shift 2
      ;;
    --source)
      SOURCE_KIND="$2"
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
    --moon-mode)
      MOON_MODE="$2"
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

case "$SOURCE_KIND" in
  zeros|sparse-zero|random) ;;
  *)
    echo "Invalid --source: $SOURCE_KIND" >&2
    exit 1
    ;;
esac

case "$MOON_MODE" in
  debug|release) ;;
  *)
    echo "Invalid --moon-mode: $MOON_MODE" >&2
    exit 1
    ;;
esac

require_cmd moon
require_cmd go
require_cmd dd
require_cmd truncate
require_cmd ps
require_cmd awk
require_cmd cmp
require_cmd stat
require_cmd wc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/lzw-bench.XXXXXX")"
else
  mkdir -p "$WORKDIR"
fi

cleanup() {
  if (( KEEP_ARTIFACTS == 0 )); then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

INPUT="$WORKDIR/input.bin"
MOON_COMPRESSED="$WORKDIR/moon.lzw"
MOON_RESTORED="$WORKDIR/moon.restored.bin"
GO_COMPRESSED="$WORKDIR/go.lzw"
GO_RESTORED="$WORKDIR/go.restored.bin"
GO_SRC="$WORKDIR/go_lzw_cli.go"
GO_BIN="$WORKDIR/go_lzw_cli"

if [[ "$MOON_MODE" == "release" ]]; then
  MOON_BUILD_ARGS=(--target native --release tools/lzw_roundtrip)
  MOON_BIN="$PROJECT_DIR/_build/native/release/build/tools/lzw_roundtrip/lzw_roundtrip.exe"
else
  MOON_BUILD_ARGS=(--target native tools/lzw_roundtrip)
  MOON_BIN="$PROJECT_DIR/_build/native/debug/build/tools/lzw_roundtrip/lzw_roundtrip.exe"
fi

declare -A ELAPSED
declare -A PEAK_RSS_KB

size_to_mib() {
  case "$1" in
    *G) echo $(( ${1%G} * 1024 )) ;;
    *M) echo "${1%M}" ;;
    *)
      echo "Unsupported size for non-sparse input: $1 (use e.g. 256M or 1G)" >&2
      exit 1
      ;;
  esac
}

generate_input() {
  local count_mib
  echo
  echo "=== preparing input ==="
  echo "Source kind: $SOURCE_KIND"
  echo "Source size: $SIZE"
  case "$SOURCE_KIND" in
    zeros)
      count_mib=$(size_to_mib "$SIZE")
      dd if=/dev/zero of="$INPUT" bs=1M count="$count_mib" status=none
      ;;
    sparse-zero)
      truncate -s "$SIZE" "$INPUT"
      ;;
    random)
      count_mib=$(size_to_mib "$SIZE")
      dd if=/dev/urandom of="$INPUT" bs=1M count="$count_mib" status=none
      ;;
  esac
}

run_phase() {
  local label=$1
  shift
  local log="$WORKDIR/${label}.log"
  local peak_kb=0
  local start_ns end_ns elapsed pid rss_kb status

  start_ns=$(date +%s%N)
  "$@" >"$log" 2>&1 &
  pid=$!

  echo
  echo "=== $label ==="
  echo "Command: $*"
  echo "PID: $pid"

  while kill -0 "$pid" 2>/dev/null; do
    rss_kb=$(ps -o rss= -p "$pid" | awk 'NF { print $1 }')
    if [[ -n "$rss_kb" ]] && (( rss_kb > peak_kb )); then
      peak_kb=$rss_kb
    fi
    sleep "$MONITOR_INTERVAL_SECS"
  done

  set +e
  wait "$pid"
  status=$?
  set -e

  end_ns=$(date +%s%N)
  elapsed=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.3f", (e - s) / 1000000000 }')

  ELAPSED["$label"]="$elapsed"
  PEAK_RSS_KB["$label"]="$peak_kb"

  echo "Elapsed: ${elapsed}s"
  echo "Peak RSS: $(fmt_bytes $(( peak_kb * 1024 )))"

  if (( status != 0 )); then
    echo "FAIL: $label exited with status $status" >&2
    echo "--- $label log ---" >&2
    cat "$log" >&2
    exit "$status"
  fi
}

verify_roundtrip() {
  local original=$1
  local restored=$2
  local label=$3
  if cmp -s "$original" "$restored"; then
    echo "VERIFY $label: ok"
  else
    echo "VERIFY $label: FAILED" >&2
    exit 1
  fi
}

cat > "$GO_SRC" <<'EOF'
package main

import (
	"bufio"
	"compress/lzw"
	"fmt"
	"io"
	"os"
)

func parseOrder(s string) (lzw.Order, error) {
	switch s {
	case "LSB", "lsb", "gif", "GIF":
		return lzw.LSB, nil
	case "MSB", "msb", "pdf", "PDF", "tiff", "TIFF":
		return lzw.MSB, nil
	default:
		return 0, fmt.Errorf("invalid order: %s", s)
	}
}

func parseLitWidth(s string) (int, error) {
	var litWidth int
	_, err := fmt.Sscanf(s, "%d", &litWidth)
	return litWidth, err
}

func compressFile(inPath, outPath string, order lzw.Order, litWidth int) error {
	in, err := os.Open(inPath)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer out.Close()
	br := bufio.NewReaderSize(in, 64<<10)
	bw := bufio.NewWriterSize(out, 64<<10)
	zw := lzw.NewWriter(bw, order, litWidth)
	if _, err := io.Copy(zw, br); err != nil {
		_ = zw.Close()
		_ = bw.Flush()
		return err
	}
	if err := zw.Close(); err != nil {
		_ = bw.Flush()
		return err
	}
	return bw.Flush()
}

func decompressFile(inPath, outPath string, order lzw.Order, litWidth int) error {
	in, err := os.Open(inPath)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer out.Close()
	br := bufio.NewReaderSize(in, 64<<10)
	zr := lzw.NewReader(br, order, litWidth)
	defer zr.Close()
	bw := bufio.NewWriterSize(out, 64<<10)
	if _, err := io.Copy(bw, zr); err != nil {
		_ = bw.Flush()
		return err
	}
	return bw.Flush()
}

func main() {
	if len(os.Args) != 6 {
		fmt.Fprintln(os.Stderr, "usage: go_lzw_cli <compress|decompress> <input> <output> <order> <lit_width>")
		os.Exit(2)
	}
	order, parseErr := parseOrder(os.Args[4])
	if parseErr != nil {
		fmt.Fprintln(os.Stderr, parseErr)
		os.Exit(2)
	}
	litWidth, parseErr := parseLitWidth(os.Args[5])
	if parseErr != nil {
		fmt.Fprintln(os.Stderr, parseErr)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "compress":
		err = compressFile(os.Args[2], os.Args[3], order, litWidth)
	case "decompress":
		err = decompressFile(os.Args[2], os.Args[3], order, litWidth)
	default:
		fmt.Fprintln(os.Stderr, "unknown command:", os.Args[1])
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
EOF

echo "=== building MoonBit tool ($MOON_MODE) ==="
moon -C "$PROJECT_DIR" build "${MOON_BUILD_ARGS[@]}"

echo
echo "=== building Go helper ==="
go build -o "$GO_BIN" "$GO_SRC"

generate_input
echo "Input path: $INPUT"
echo "Input size: $(fmt_bytes "$(stat -c %s "$INPUT")")"

echo
echo "=== warming input cache ==="
wc -c < "$INPUT" >/dev/null

echo
echo "=== MoonBit ==="
run_phase moon_compress "$MOON_BIN" compress-file "$INPUT" "$MOON_COMPRESSED" "$ORDER" "$LIT_WIDTH"
run_phase moon_decompress "$MOON_BIN" decompress-file "$MOON_COMPRESSED" "$MOON_RESTORED" "$ORDER" "$LIT_WIDTH"
verify_roundtrip "$INPUT" "$MOON_RESTORED" moon
MOON_COMPRESSED_BYTES=$(stat -c %s "$MOON_COMPRESSED")

echo
echo "=== Go ==="
run_phase go_compress "$GO_BIN" compress "$INPUT" "$GO_COMPRESSED" "$ORDER" "$LIT_WIDTH"
run_phase go_decompress "$GO_BIN" decompress "$GO_COMPRESSED" "$GO_RESTORED" "$ORDER" "$LIT_WIDTH"
verify_roundtrip "$INPUT" "$GO_RESTORED" go
GO_COMPRESSED_BYTES=$(stat -c %s "$GO_COMPRESSED")

echo
echo "=== Summary ==="
printf '%-22s %12s %14s %16s\n' "Phase" "Elapsed(s)" "Peak RSS" "Compressed"
printf '%-22s %12s %14s %16s\n' "----------------------" "------------" "--------------" "----------------"
printf '%-22s %12.3f %14s %16s\n' \
  "moon_compress" "${ELAPSED[moon_compress]}" "$(fmt_bytes $(( PEAK_RSS_KB[moon_compress] * 1024 )))" "$(fmt_bytes "$MOON_COMPRESSED_BYTES")"
printf '%-22s %12.3f %14s %16s\n' \
  "moon_decompress" "${ELAPSED[moon_decompress]}" "$(fmt_bytes $(( PEAK_RSS_KB[moon_decompress] * 1024 )))" "-"
printf '%-22s %12.3f %14s %16s\n' \
  "go_compress" "${ELAPSED[go_compress]}" "$(fmt_bytes $(( PEAK_RSS_KB[go_compress] * 1024 )))" "$(fmt_bytes "$GO_COMPRESSED_BYTES")"
printf '%-22s %12.3f %14s %16s\n' \
  "go_decompress" "${ELAPSED[go_decompress]}" "$(fmt_bytes $(( PEAK_RSS_KB[go_decompress] * 1024 )))" "-"

echo
echo "MoonBit/Go ratios:"
awk \
  -v mc="${ELAPSED[moon_compress]}" \
  -v gc="${ELAPSED[go_compress]}" \
  -v md="${ELAPSED[moon_decompress]}" \
  -v gd="${ELAPSED[go_decompress]}" \
  'BEGIN {
    printf "  compress:   %.2fx\n", mc / gc
    printf "  decompress: %.2fx\n", md / gd
  }'

echo
echo "Artifacts: $WORKDIR"
