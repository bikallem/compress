.PHONY: test bench parity parity-generate parity-test check roundtrip

ROUNDTRIP_FILES := \
	bzip2/round_trip_test.mbt \
	flate/round_trip_test.mbt \
	gzip/round_trip_test.mbt \
	lzw/round_trip_test.mbt \
	zlib/round_trip_test.mbt \
	brotli/round_trip_test.mbt

ROUNDTRIP_TARGETS := native wasm-gc js

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
	@set -e; \
	for target in $(ROUNDTRIP_TARGETS); do \
		echo "=== Roundtrip tests: $$target ==="; \
		for file in $(ROUNDTRIP_FILES); do \
			moon test $$file --target $$target; \
		done; \
	done

# Full parity test: generate MoonBit golden files + compare against Go
parity:
	./tools/parity.sh all

# Only generate MoonBit golden files
parity-generate:
	./tools/parity.sh generate

# Only run Go parity tests (assumes golden files exist)
parity-test:
	./tools/parity.sh test
