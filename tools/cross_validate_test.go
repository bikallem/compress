package tools

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"compress/lzw"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
)

type GoldenEntry struct {
	Name       string `json:"name"`
	Algorithm  string `json:"algorithm"`
	Level      int    `json:"level,omitempty"`
	InputFile  string `json:"input_file"`
	OutputFile string `json:"output_file"`
	InputSize  int    `json:"input_size"`
	OutputSize int    `json:"output_size"`
	DictFile   string `json:"dict_file,omitempty"`
}

func loadManifest(t *testing.T) []GoldenEntry {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "testdata", "golden", "manifest.json"))
	if err != nil {
		t.Skipf("No golden files found: %v", err)
	}
	var entries []GoldenEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("Failed to parse manifest: %v", err)
	}
	return entries
}

func TestGoDecompressGolden(t *testing.T) {
	entries := loadManifest(t)
	goldenDir := filepath.Join("..", "testdata", "golden")

	for _, e := range entries {
		t.Run(e.Name, func(t *testing.T) {
			input, err := os.ReadFile(filepath.Join(goldenDir, e.InputFile))
			if err != nil {
				t.Fatalf("Failed to read input: %v", err)
			}
			compressed, err := os.ReadFile(filepath.Join(goldenDir, e.OutputFile))
			if err != nil {
				t.Fatalf("Failed to read compressed: %v", err)
			}

			var dict []byte
			if e.DictFile != "" {
				dict, err = os.ReadFile(filepath.Join(goldenDir, e.DictFile))
				if err != nil {
					t.Fatalf("Failed to read dict: %v", err)
				}
			}

			var decompressed []byte
			switch e.Algorithm {
			case "deflate":
				r := flate.NewReader(bytes.NewReader(compressed))
				decompressed, err = io.ReadAll(r)
				r.Close()
			case "deflate_dict":
				r := flate.NewReaderDict(bytes.NewReader(compressed), dict)
				decompressed, err = io.ReadAll(r)
				r.Close()
			case "gzip":
				r, gerr := gzip.NewReader(bytes.NewReader(compressed))
				if gerr != nil {
					t.Fatalf("gzip.NewReader: %v", gerr)
				}
				decompressed, err = io.ReadAll(r)
				r.Close()
			case "zlib":
				r, zerr := zlib.NewReader(bytes.NewReader(compressed))
				if zerr != nil {
					t.Fatalf("zlib.NewReader: %v", zerr)
				}
				decompressed, err = io.ReadAll(r)
				r.Close()
			case "zlib_dict":
				r, zerr := zlib.NewReaderDict(bytes.NewReader(compressed), dict)
				if zerr != nil {
					t.Fatalf("zlib.NewReaderDict: %v", zerr)
				}
				decompressed, err = io.ReadAll(r)
				r.Close()
			case "lzw":
				r := lzw.NewReader(bytes.NewReader(compressed), lzw.LSB, 8)
				decompressed, err = io.ReadAll(r)
				r.Close()
			default:
				t.Skipf("Unknown algorithm: %s", e.Algorithm)
			}

			if err != nil {
				t.Fatalf("Decompression failed: %v", err)
			}
			if !bytes.Equal(decompressed, input) {
				t.Errorf("Decompressed data mismatch: got %d bytes, want %d bytes",
					len(decompressed), len(input))
			}
		})
	}
}
