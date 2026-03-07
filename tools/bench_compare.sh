#!/bin/bash
# Run MoonBit and Go benchmarks side-by-side and produce a comparison table.
# Usage: ./tools/bench_compare.sh [filter]
# Example: ./tools/bench_compare.sh crc32
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILTER="${1:-}"

export PATH="$PATH:/usr/local/go/bin"

MOON_OUT=$(mktemp)
GO_OUT=$(mktemp)
trap 'rm -f "$MOON_OUT" "$GO_OUT"' EXIT

echo "Running MoonBit benchmarks..."
cd "$REPO_ROOT"
# MoonBit bench output lines look like: "bench_name  123.45 µs ± ..."
# Filter out header lines (contain "time" or parentheses)
moon bench -p benchmarks --target native --release 2>&1 \
  | grep -E '^[a-z_].*[0-9]' \
  | grep -v 'time' > "$MOON_OUT" || true

echo "Running Go benchmarks..."
cd "$REPO_ROOT/tools"
go test -bench=. -benchtime=1s -count=1 2>&1 | grep '^Benchmark' > "$GO_OUT" || true

cd "$REPO_ROOT"

# Parse MoonBit: "name  123.45 µs ± ..."  →  name → time_us
declare -A MOON_TIMES
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  time_val=$(echo "$line" | awk '{print $2}')
  time_unit=$(echo "$line" | awk '{print $3}')
  case "$time_unit" in
    ns) time_us=$(echo "$time_val / 1000" | bc -l) ;;
    µs|"µs") time_us=$time_val ;;
    ms) time_us=$(echo "$time_val * 1000" | bc -l) ;;
    s)  time_us=$(echo "$time_val * 1000000" | bc -l) ;;
    *)  continue ;;
  esac
  MOON_TIMES["$name"]=$time_us
done < "$MOON_OUT"

# Parse Go: "BenchmarkName-16  12345  123.45 ns/op"
declare -A GO_TIMES
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  raw_name=$(echo "$line" | awk '{print $1}' | sed 's/-[0-9]*$//')
  time_val=$(echo "$line" | awk '{print $3}')
  time_unit=$(echo "$line" | awk '{print $4}')
  case "$time_unit" in
    ns/op) time_us=$(echo "$time_val / 1000" | bc -l) ;;
    µs/op) time_us=$time_val ;;
    ms/op) time_us=$(echo "$time_val * 1000" | bc -l) ;;
    *)     continue ;;
  esac
  # Normalize Go name: BenchmarkCRC32_1kb → crc32_1kb
  # Remove "Benchmark" prefix, then lowercase everything
  normalized=$(echo "$raw_name" | sed 's/^Benchmark//')
  # Insert underscore before transitions: lowercase→uppercase or uppercase→(uppercase followed by lowercase)
  # But simpler: just lowercase the whole thing since Go uses underscores for sizes
  normalized=$(echo "$normalized" | sed 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' | tr '[:upper:]' '[:lower:]')
  GO_TIMES["$normalized"]=$time_us
done < "$GO_OUT"

# Print table
printf "\n%-42s %12s %12s %10s\n" "Benchmark" "MoonBit(µs)" "Go(µs)" "Ratio"
printf "%-42s %12s %12s %10s\n" \
  "$(printf -- '-%.0s' {1..42})" \
  "$(printf -- '-%.0s' {1..12})" \
  "$(printf -- '-%.0s' {1..12})" \
  "$(printf -- '-%.0s' {1..10})"

# Collect all unique keys
declare -A ALL_KEYS
for key in "${!MOON_TIMES[@]}"; do ALL_KEYS["$key"]=1; done
for key in "${!GO_TIMES[@]}"; do ALL_KEYS["$key"]=1; done

# Sort and print
while IFS= read -r key; do
  if [[ -n "$FILTER" ]] && ! echo "$key" | grep -qi "$FILTER"; then
    continue
  fi
  moon_t=${MOON_TIMES[$key]:-""}
  go_t=${GO_TIMES[$key]:-""}
  if [[ -n "$moon_t" && -n "$go_t" ]]; then
    ratio=$(echo "scale=2; $moon_t / $go_t" | bc -l)
    printf "%-42s %12.2f %12.2f %9.2fx\n" "$key" "$moon_t" "$go_t" "$ratio"
  elif [[ -n "$moon_t" ]]; then
    printf "%-42s %12.2f %12s %10s\n" "$key" "$moon_t" "-" "-"
  else
    printf "%-42s %12s %12.2f %10s\n" "$key" "-" "$go_t" "-"
  fi
done < <(printf '%s\n' "${!ALL_KEYS[@]}" | sort)

echo ""
echo "Ratio = MoonBit/Go (lower is better for MoonBit)"
