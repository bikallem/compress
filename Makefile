.PHONY: test bench parity parity-generate parity-test check

# Run all MoonBit tests
test:
	moon test --target native

# Type-check
check:
	moon check --target native

# Run benchmarks (current vs Go)
bench:
	./tools/bench.sh --go

# Full parity test: generate MoonBit golden files + compare against Go
parity:
	./tools/parity.sh all

# Only generate MoonBit golden files
parity-generate:
	./tools/parity.sh generate

# Only run Go parity tests (assumes golden files exist)
parity-test:
	./tools/parity.sh test
