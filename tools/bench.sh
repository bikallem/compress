#!/usr/bin/env bash
# Run MoonBit benchmarks with optional comparison against previous commit and Go.
#
# Usage:
#   ./tools/bench.sh                    # current only
#   ./tools/bench.sh --prev             # current vs previous commit
#   ./tools/bench.sh --go               # current vs Go
#   ./tools/bench.sh --prev --go        # current vs previous commit vs Go
#   ./tools/bench.sh --filter crc32     # filter benchmarks by name
#   ./tools/bench.sh --json             # save raw results to bench_results.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure go is on PATH
if ! command -v go &>/dev/null && [ -x /usr/local/go/bin/go ]; then
  export PATH="$PATH:/usr/local/go/bin"
fi

RUN_PREV=false
RUN_GO=false
FILTER=""
SAVE_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prev)   RUN_PREV=true; shift ;;
    --go)     RUN_GO=true; shift ;;
    --filter) FILTER="$2"; shift 2 ;;
    --json)   SAVE_JSON=true; shift ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Helpers ---

parse_moon_bench() {
  # Parse "name  123.45 µs ± ..." lines into "name<TAB>time_us" pairs
  grep -E '^[a-z_].*[0-9]' | grep -v 'time' | while IFS= read -r line; do
    local name time_val time_unit
    name=$(echo "$line" | awk '{print $1}')
    time_val=$(echo "$line" | awk '{print $2}')
    time_unit=$(echo "$line" | awk '{print $3}')
    local time_us
    case "$time_unit" in
      ns)      time_us=$(awk "BEGIN {printf \"%.4f\", $time_val / 1000}") ;;
      µs|"µs") time_us=$time_val ;;
      ms)      time_us=$(awk "BEGIN {printf \"%.4f\", $time_val * 1000}") ;;
      s)       time_us=$(awk "BEGIN {printf \"%.4f\", $time_val * 1000000}") ;;
      *)       continue ;;
    esac
    echo "${name}	${time_us}"
  done
}

parse_go_bench() {
  # Parse "BenchmarkName-16  12345  123.45 ns/op" lines
  grep '^Benchmark' | while IFS= read -r line; do
    local raw_name time_val time_unit
    raw_name=$(echo "$line" | awk '{print $1}' | sed 's/-[0-9]*$//')
    time_val=$(echo "$line" | awk '{print $3}')
    time_unit=$(echo "$line" | awk '{print $4}')
    local time_us
    case "$time_unit" in
      ns/op)   time_us=$(awk "BEGIN {printf \"%.4f\", $time_val / 1000}") ;;
      µs/op)   time_us=$time_val ;;
      ms/op)   time_us=$(awk "BEGIN {printf \"%.4f\", $time_val * 1000}") ;;
      *)       continue ;;
    esac
    # Normalize: BenchmarkCRC32_1kb → crc32_1kb
    local normalized
    normalized=$(echo "$raw_name" | sed 's/^Benchmark//' \
      | sed 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' | tr '[:upper:]' '[:lower:]')
    echo "${normalized}	${time_us}"
  done
}

fmt_change() {
  # Format a percentage change with direction indicator
  local old=$1 new=$2
  if [[ -z "$old" || -z "$new" ]]; then
    echo "-"
    return
  fi
  awk "BEGIN {
    pct = ($new - $old) / $old * 100
    if (pct > 5) printf \"+%.1f%% ▲\", pct
    else if (pct < -5) printf \"%.1f%% ▼\", pct
    else printf \"~%.1f%%\", pct
  }"
}

# --- Run benchmarks ---

cd "$REPO_ROOT"

echo "=== Running MoonBit benchmarks (current) ==="
MOON_RAW=$(mktemp)
moon bench -p benchmarks --target native --release 2>&1 | tee "$MOON_RAW"
echo ""

# Parse current results
declare -A CURRENT
while IFS=$'\t' read -r name val; do
  CURRENT["$name"]=$val
done < <(parse_moon_bench < "$MOON_RAW")
rm -f "$MOON_RAW"

# --- Previous commit ---

declare -A PREV
if $RUN_PREV; then
  echo "=== Running MoonBit benchmarks (previous commit) ==="
  PREV_RAW=$(mktemp)
  STASHED=false
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
    git stash --include-untracked -q || true
    STASHED=true
  fi
  git checkout HEAD~1 -q
  moon install -q 2>/dev/null || true
  moon bench -p benchmarks --target native --release 2>&1 | tee "$PREV_RAW"
  git checkout - -q
  if $STASHED; then
    git stash pop -q || true
  fi
  while IFS=$'\t' read -r name val; do
    PREV["$name"]=$val
  done < <(parse_moon_bench < "$PREV_RAW")
  rm -f "$PREV_RAW"
  echo ""
fi

# --- Go benchmarks ---

declare -A GO
if $RUN_GO; then
  echo "=== Running Go benchmarks ==="
  GO_RAW=$(mktemp)
  (cd "$REPO_ROOT/tools" && go test -bench=. -benchtime=1s -count=1 2>&1) | tee "$GO_RAW"
  while IFS=$'\t' read -r name val; do
    GO["$name"]=$val
  done < <(parse_go_bench < "$GO_RAW")
  rm -f "$GO_RAW"
  echo ""
fi

# --- Collect all benchmark names ---

declare -A ALL_KEYS
for key in "${!CURRENT[@]}"; do ALL_KEYS["$key"]=1; done
for key in "${!GO[@]}"; do ALL_KEYS["$key"]=1; done
SORTED_KEYS=$(printf '%s\n' "${!ALL_KEYS[@]}" | sort)

# --- Report ---

echo ""
echo "================================================================================"
echo "  BENCHMARK REPORT"
echo "================================================================================"
echo ""

# Build header
HDR="%-44s %12s"
DIV="%-44s %12s"
hdr_args=("Benchmark" "Current(µs)")
div_args=("$(printf -- '-%.0s' {1..44})" "$(printf -- '-%.0s' {1..12})")

if $RUN_PREV; then
  HDR="$HDR %12s %12s"
  DIV="$DIV %12s %12s"
  hdr_args+=("Prev(µs)" "Δ prev")
  div_args+=("$(printf -- '-%.0s' {1..12})" "$(printf -- '-%.0s' {1..12})")
fi
if $RUN_GO; then
  HDR="$HDR %12s %12s"
  DIV="$DIV %12s %12s"
  hdr_args+=("Go(µs)" "vs Go")
  div_args+=("$(printf -- '-%.0s' {1..12})" "$(printf -- '-%.0s' {1..12})")
fi

printf "$HDR\n" "${hdr_args[@]}"
printf "$DIV\n" "${div_args[@]}"

# Print rows
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  if [[ -n "$FILTER" ]] && ! echo "$key" | grep -qi "$FILTER"; then
    continue
  fi

  cur=${CURRENT[$key]:-""}
  row_fmt="%-44s"
  row_args=("$key")

  # Current
  if [[ -n "$cur" ]]; then
    row_fmt="$row_fmt %12.2f"
    row_args+=("$cur")
  else
    row_fmt="$row_fmt %12s"
    row_args+=("-")
  fi

  # Previous
  if $RUN_PREV; then
    prev_val=${PREV[$key]:-""}
    if [[ -n "$prev_val" ]]; then
      row_fmt="$row_fmt %12.2f"
      row_args+=("$prev_val")
    else
      row_fmt="$row_fmt %12s"
      row_args+=("-")
    fi
    change=$(fmt_change "$prev_val" "$cur")
    row_fmt="$row_fmt %12s"
    row_args+=("$change")
  fi

  # Go
  if $RUN_GO; then
    go_val=${GO[$key]:-""}
    if [[ -n "$go_val" ]]; then
      row_fmt="$row_fmt %12.2f"
      row_args+=("$go_val")
    else
      row_fmt="$row_fmt %12s"
      row_args+=("-")
    fi
    if [[ -n "$cur" && -n "$go_val" ]]; then
      ratio=$(awk "BEGIN {printf \"%.2f\", $cur / $go_val}")
      row_fmt="$row_fmt %11sx"
      row_args+=("$ratio")
    else
      row_fmt="$row_fmt %12s"
      row_args+=("-")
    fi
  fi

  printf "$row_fmt\n" "${row_args[@]}"
done <<< "$SORTED_KEYS"

echo ""
if $RUN_PREV; then
  echo "Δ prev: change from previous commit (▼ = faster, ▲ = slower, ~ = within 5%)"
fi
if $RUN_GO; then
  echo "vs Go:  ratio = MoonBit/Go (lower is better for MoonBit)"
fi

# --- JSON output ---

if $SAVE_JSON; then
  JSON_FILE="$REPO_ROOT/bench_results.json"
  {
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"commit\": \"$(git rev-parse --short HEAD)\","
    echo "  \"results\": {"
    first=true
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      if [[ -n "$FILTER" ]] && ! echo "$key" | grep -qi "$FILTER"; then
        continue
      fi
      cur=${CURRENT[$key]:-null}
      if $first; then first=false; else echo ","; fi
      printf "    \"%s\": {\"current_us\": %s" "$key" "$cur"
      if $RUN_PREV; then
        prev_val=${PREV[$key]:-null}
        printf ", \"prev_us\": %s" "$prev_val"
      fi
      if $RUN_GO; then
        go_val=${GO[$key]:-null}
        printf ", \"go_us\": %s" "$go_val"
      fi
      printf "}"
    done <<< "$SORTED_KEYS"
    echo ""
    echo "  }"
    echo "}"
  } > "$JSON_FILE"
  echo ""
  echo "Results saved to $JSON_FILE"
fi
