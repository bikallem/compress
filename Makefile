.PHONY: test bench parity parity-generate parity-test check roundtrip

# Run all MoonBit tests (native)
test:
	moon test --target native

# Type-check
check:
	moon check --target native

# Run benchmarks (current vs Go)
bench:
	./tools/bench.sh --go

# Run roundtrip tests on all targets
roundtrip:
	@echo "=== Roundtrip tests: native ==="
	moon test --target native --filter "*round*trip*"
	@echo "=== Roundtrip tests: wasm-gc ==="
	moon test --target wasm-gc --filter "*round*trip*"
	@echo "=== Roundtrip tests: js ==="
	moon test --target js --filter "*round*trip*"

# Full parity test: generate MoonBit golden files + compare against Go
parity:
	./tools/parity.sh all

# Only generate MoonBit golden files
parity-generate:
	./tools/parity.sh generate

# Only run Go parity tests (assumes golden files exist)
parity-test:
	./tools/parity.sh test
