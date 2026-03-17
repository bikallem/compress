package tools

import (
	"bytes"
	"compress/bzip2"
	"compress/flate"
	"compress/gzip"
	"compress/lzw"
	"compress/zlib"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/golang/snappy"
	"github.com/klauspost/compress/zstd"
)

// lz4Decompress shells out to the system lz4 command to decompress data.
// Returns an *exec.Error wrapping exec.ErrNotFound if the lz4 binary is not installed.
func lz4Decompress(data []byte) ([]byte, error) {
	cmd := exec.Command("lz4", "-d", "-c", "-f")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Output()
}

// isLz4NotFound reports whether err indicates the lz4 command is not installed.
func isLz4NotFound(err error) bool {
	var execErr *exec.Error
	return errors.As(err, &execErr)
}

// MoonBit golden manifest entry (same schema as Go golden).
type MBGoldenEntry struct {
	Name       string `json:"name"`
	Algorithm  string `json:"algorithm"`
	Level      int    `json:"level,omitempty"`
	InputFile  string `json:"input_file"`
	OutputFile string `json:"output_file"`
	InputSize  int    `json:"input_size"`
	OutputSize int    `json:"output_size"`
}

func loadMBManifest(t *testing.T) []MBGoldenEntry {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", "moonbit_golden", "manifest.json"))
	if err != nil {
		t.Skipf("No MoonBit golden files found (run 'make parity-generate' first): %v", err)
	}
	var entries []MBGoldenEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("Failed to parse MoonBit manifest: %v", err)
	}
	return entries
}

// TestGoDecompressMoonBit verifies Go can decompress MoonBit-compressed output.
// This tests interoperability: MoonBit compress → Go decompress → original.
func TestGoDecompressMoonBit(t *testing.T) {
	entries := loadMBManifest(t)
	mbDir := filepath.Join("..", "testdata", "moonbit_golden")
	goDir := filepath.Join("..", "testdata", "golden")

	for _, e := range entries {
		t.Run(e.Name, func(t *testing.T) {
			input, err := os.ReadFile(filepath.Join(goDir, e.InputFile))
			if err != nil {
				t.Fatalf("Failed to read input %s: %v", e.InputFile, err)
			}
			compressed, err := os.ReadFile(filepath.Join(mbDir, e.OutputFile))
			if err != nil {
				t.Fatalf("Failed to read MoonBit compressed %s: %v", e.OutputFile, err)
			}

			decompressed := goDecompress(t, e.Algorithm, compressed)
			if !bytes.Equal(decompressed, input) {
				t.Errorf("Round-trip mismatch: MoonBit compressed → Go decompressed\n"+
					"  input: %d bytes, got: %d bytes", len(input), len(decompressed))
				// Show first differing byte
				for i := 0; i < len(input) && i < len(decompressed); i++ {
					if input[i] != decompressed[i] {
						t.Errorf("  first diff at byte %d: want 0x%02x, got 0x%02x", i, input[i], decompressed[i])
						break
					}
				}
			}
		})
	}
}

// TestBitIdenticalOutput compares MoonBit compressed output byte-by-byte
// against Go compressed output for the same inputs and algorithms.
// Non-identical but semantically correct output is logged, not failed.
// Only fails if MoonBit output cannot be decompressed by Go.
func TestBitIdenticalOutput(t *testing.T) {
	entries := loadMBManifest(t)
	mbDir := filepath.Join("..", "testdata", "moonbit_golden")
	goDir := filepath.Join("..", "testdata", "golden")

	identical := 0
	compatible := 0
	total := 0

	for _, e := range entries {
		// Skip algorithms where Go golden files don't exist (bzip2)
		// Go stdlib has bzip2 decompressor only, no compressor in generate_golden
		if e.Algorithm == "bzip2" {
			continue
		}
		// Skip dictionary-based algorithms
		if e.Algorithm == "deflate_dict" || e.Algorithm == "zlib_dict" {
			continue
		}

		t.Run(e.Name, func(t *testing.T) {
			total++
			mbCompressed, err := os.ReadFile(filepath.Join(mbDir, e.OutputFile))
			if err != nil {
				t.Fatalf("Failed to read MoonBit output %s: %v", e.OutputFile, err)
			}

			goCompressed, err := os.ReadFile(filepath.Join(goDir, e.OutputFile))
			if err != nil {
				t.Skipf("No Go golden file for %s: %v", e.OutputFile, err)
				return
			}

			if bytes.Equal(mbCompressed, goCompressed) {
				identical++
				return // Bit-identical
			}

			// Verify MoonBit output is at least semantically correct
			input, err := os.ReadFile(filepath.Join(goDir, e.InputFile))
			if err != nil {
				t.Fatalf("Failed to read input: %v", err)
			}

			mbDecomp := goDecompress(t, e.Algorithm, mbCompressed)
			if !bytes.Equal(mbDecomp, input) {
				t.Errorf("MoonBit output does NOT decompress to original input!\n"+
					"  MoonBit compressed: %d bytes\n"+
					"  Decompressed: %d bytes, want: %d bytes",
					len(mbCompressed), len(mbDecomp), len(input))
				return
			}

			compatible++
			// Log diff details for informational purposes
			t.Logf("Not bit-identical (but semantically correct): MoonBit %d bytes vs Go %d bytes",
				len(mbCompressed), len(goCompressed))
		})
	}

	t.Cleanup(func() {
		t.Logf("\nBit-identical: %d/%d, Compatible: %d/%d, Total: %d",
			identical, total, compatible, total, total)
	})
}

func goDecompress(t *testing.T, algorithm string, data []byte) []byte {
	t.Helper()
	var result []byte
	var err error
	switch algorithm {
	case "deflate":
		r := flate.NewReader(bytes.NewReader(data))
		result, err = io.ReadAll(r)
		r.Close()
	case "gzip":
		r, gerr := gzip.NewReader(bytes.NewReader(data))
		if gerr != nil {
			t.Fatalf("gzip.NewReader: %v", gerr)
		}
		result, err = io.ReadAll(r)
		r.Close()
	case "zlib":
		r, zerr := zlib.NewReader(bytes.NewReader(data))
		if zerr != nil {
			t.Fatalf("zlib.NewReader: %v", zerr)
		}
		result, err = io.ReadAll(r)
		r.Close()
	case "lzw":
		r := lzw.NewReader(bytes.NewReader(data), lzw.LSB, 8)
		result, err = io.ReadAll(r)
		r.Close()
	case "bzip2":
		r := bzip2.NewReader(bytes.NewReader(data))
		result, err = io.ReadAll(r)
	case "snappy":
		result, err = snappy.Decode(nil, data)
	case "lz4":
		result, err = lz4Decompress(data)
		if isLz4NotFound(err) {
			t.Skip("lz4 command not available")
		}
	case "zstd":
		dec, derr := zstd.NewReader(bytes.NewReader(data))
		if derr != nil {
			t.Fatalf("zstd.NewReader: %v", derr)
		}
		result, err = io.ReadAll(dec)
		dec.Close()
	default:
		t.Fatalf("Unknown algorithm: %s", algorithm)
	}
	if err != nil {
		t.Fatalf("Decompression failed for %s: %v", algorithm, err)
	}
	return result
}

// TestParitySummary prints an overview of all parity results.
func TestParitySummary(t *testing.T) {
	entries := loadMBManifest(t)
	mbDir := filepath.Join("..", "testdata", "moonbit_golden")
	goDir := filepath.Join("..", "testdata", "golden")

	type Result struct {
		identical  int
		compatible int
		failed     int
		noGoGolden int
	}
	results := make(map[string]*Result)

	for _, e := range entries {
		r, ok := results[e.Algorithm]
		if !ok {
			r = &Result{}
			results[e.Algorithm] = r
		}

		mbCompressed, err := os.ReadFile(filepath.Join(mbDir, e.OutputFile))
		if err != nil {
			r.failed++
			continue
		}

		goCompressed, err := os.ReadFile(filepath.Join(goDir, e.OutputFile))
		if err != nil {
			// No Go golden (e.g., bzip2 -- Go has no compressor)
			// Check if Go can decompress MoonBit output
			input, ierr := os.ReadFile(filepath.Join(goDir, e.InputFile))
			if ierr == nil {
				decomp := goDecompressSafe(e.Algorithm, mbCompressed)
				if decomp != nil && bytes.Equal(decomp, input) {
					r.compatible++
				} else {
					r.failed++
				}
			}
			r.noGoGolden++
			continue
		}

		if bytes.Equal(mbCompressed, goCompressed) {
			r.identical++
		} else {
			// Check semantic compatibility
			input, ierr := os.ReadFile(filepath.Join(goDir, e.InputFile))
			if ierr != nil {
				r.failed++
				continue
			}
			mbDecomp := goDecompressSafe(e.Algorithm, mbCompressed)
			if mbDecomp != nil && bytes.Equal(mbDecomp, input) {
				r.compatible++
			} else {
				r.failed++
			}
		}
	}

	t.Log("\n=== Parity Summary ===")
	for algo, r := range results {
		t.Logf("%-10s  identical: %d  compatible: %d  failed: %d  no-go-golden: %d",
			algo, r.identical, r.compatible, r.failed, r.noGoGolden)
	}
}

func goDecompressSafe(algorithm string, data []byte) []byte {
	var result []byte
	var err error
	switch algorithm {
	case "deflate":
		r := flate.NewReader(bytes.NewReader(data))
		result, err = io.ReadAll(r)
		r.Close()
	case "gzip":
		r, gerr := gzip.NewReader(bytes.NewReader(data))
		if gerr != nil {
			return nil
		}
		result, err = io.ReadAll(r)
		r.Close()
	case "zlib":
		r, zerr := zlib.NewReader(bytes.NewReader(data))
		if zerr != nil {
			return nil
		}
		result, err = io.ReadAll(r)
		r.Close()
	case "lzw":
		r := lzw.NewReader(bytes.NewReader(data), lzw.LSB, 8)
		result, err = io.ReadAll(r)
		r.Close()
	case "bzip2":
		r := bzip2.NewReader(bytes.NewReader(data))
		result, err = io.ReadAll(r)
	case "snappy":
		result, err = snappy.Decode(nil, data)
	case "lz4":
		result, err = lz4Decompress(data)
	case "zstd":
		dec, derr := zstd.NewReader(bytes.NewReader(data))
		if derr != nil {
			return nil
		}
		result, err = io.ReadAll(dec)
		dec.Close()
	default:
		return nil
	}
	if err != nil {
		return nil
	}
	return result
}

// Helpers for verbose diff output
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func hexDump(data []byte, maxBytes int) string {
	n := min(len(data), maxBytes)
	return fmt.Sprintf("%x", data[:n])
}
