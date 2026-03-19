#!/usr/bin/env bash
# Bit-for-bit parity test: MoonBit compress vs Go compress.
#
# Usage:
#   ./tools/parity.sh                          # generate + test all codecs
#   ./tools/parity.sh --codec brotli           # only test brotli
#   ./tools/parity.sh --sort-ratio             # sort by worst compression ratio
#   ./tools/parity.sh test --codec deflate     # test only deflate
#   ./tools/parity.sh generate                 # only generate golden files
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MB_GOLDEN_DIR="$ROOT/testdata/moonbit_golden"
GO_GOLDEN_DIR="$ROOT/testdata/golden"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

step() { printf "${BOLD}==> %s${NC}\n" "$1"; }
ok()   { printf "${GREEN}✓ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$1"; }
fail() { printf "${RED}✗ %s${NC}\n" "$1"; }

generate() {
    step "Ensuring Go golden files exist"
    if [ ! -f "$GO_GOLDEN_DIR/manifest.json" ]; then
        step "Generating Go golden files"
        (cd "$ROOT/tools/generate_golden" && go run main.go)
        ok "Go golden files generated"
    else
        ok "Go golden files already present"
    fi

    step "Building MoonBit golden generator"
    (cd "$ROOT" && moon build tools/generate_moonbit_golden --target native --release 2>&1)
    ok "MoonBit golden generator built"

    step "Generating MoonBit golden files"
    mkdir -p "$MB_GOLDEN_DIR"
    "$ROOT/_build/native/release/build/tools/generate_moonbit_golden/generate_moonbit_golden.exe" \
        "$MB_GOLDEN_DIR" "$GO_GOLDEN_DIR"
    ok "MoonBit golden files generated"
}

run_tests() {
    if [ ! -f "$MB_GOLDEN_DIR/manifest.json" ]; then
        fail "MoonBit golden files not found. Run '$0 generate' first."
        exit 1
    fi

    # Build Go test -run filter based on codec
    local run_filter='TestGoDecompressMoonBit|TestBitIdenticalOutput'
    if [[ -n "$CODEC" ]]; then
        run_filter="TestGoDecompressMoonBit/${CODEC}|TestBitIdenticalOutput/${CODEC}"
    fi

    step "Running Go parity tests${CODEC:+ (codec: $CODEC)}"
    local test_output
    test_output="$(cd "$ROOT/tools" && go test -run "$run_filter" -count=1 -timeout 300s 2>&1)" || true
    if echo "$test_output" | grep -q "^FAIL"; then
        fail "Some parity tests failed:"
        echo "$test_output" | grep -E "FAIL"
    else
        ok "All decompression and bit-identity checks passed"
    fi

    # Run summary test and show its formatted output
    step "Compression ratio report"
    (cd "$ROOT/tools" && go test -run 'TestParitySummary' -v -count=1 -timeout 300s 2>&1) | grep -vE "^(=== RUN|--- PASS|--- FAIL|PASS$|FAIL$|ok )"
}

SORT_RATIO=""
CODEC=""
CMDS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sort-ratio) SORT_RATIO="1"; shift ;;
        --codec) CODEC="$2"; shift 2 ;;
        *) CMDS+=("$1"); shift ;;
    esac
done
CMD="${CMDS[0]:-all}"
export PARITY_SORT_RATIO="${SORT_RATIO}"
export PARITY_CODEC="${CODEC}"

case "$CMD" in
    generate)
        generate
        ;;
    test)
        run_tests
        ;;
    all)
        generate
        echo
        run_tests
        ;;
    *)
        echo "Usage: $0 [generate|test|all] [--codec NAME] [--sort-ratio]"
        exit 1
        ;;
esac
