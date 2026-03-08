// generate_golden.go generates compressed golden files using Go's stdlib.
// Run: go run generate_golden.go
package main

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/lzw"
	"compress/zlib"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

func main() {
	dir := filepath.Join("..", "testdata", "golden")
	os.MkdirAll(dir, 0o755)

	// Test inputs
	inputs := map[string][]byte{
		"empty":      {},
		"hello":      []byte("Hello, World!"),
		"repeated":   bytes.Repeat([]byte("abcdefghijklmnop"), 256),  // 4KB repeated
		"zeros_10k":  make([]byte, 10240),                            // 10KB zeros
		"mixed_1k":   generateMixed(1024),                            // 1KB mixed content
	}

	// Write input files
	for name, data := range inputs {
		os.WriteFile(filepath.Join(dir, name+".bin"), data, 0o644)
	}

	var entries []GoldenEntry

	// Generate DEFLATE compressed files
	for name, data := range inputs {
		for _, level := range []int{1, 6, 9} {
			outName := fmt.Sprintf("deflate_%s_level%d.bin", name, level)
			compressed := deflateCompress(data, level)
			os.WriteFile(filepath.Join(dir, outName), compressed, 0o644)
			entries = append(entries, GoldenEntry{
				Name:       fmt.Sprintf("deflate/%s/level%d", name, level),
				Algorithm:  "deflate",
				Level:      level,
				InputFile:  name + ".bin",
				OutputFile: outName,
				InputSize:  len(data),
				OutputSize: len(compressed),
			})
		}
	}

	// Generate gzip compressed files
	for name, data := range inputs {
		for _, level := range []int{1, 6, 9} {
			outName := fmt.Sprintf("gzip_%s_level%d.bin", name, level)
			compressed := gzipCompress(data, level)
			os.WriteFile(filepath.Join(dir, outName), compressed, 0o644)
			entries = append(entries, GoldenEntry{
				Name:       fmt.Sprintf("gzip/%s/level%d", name, level),
				Algorithm:  "gzip",
				Level:      level,
				InputFile:  name + ".bin",
				OutputFile: outName,
				InputSize:  len(data),
				OutputSize: len(compressed),
			})
		}
	}

	// Generate zlib compressed files
	for name, data := range inputs {
		for _, level := range []int{1, 6, 9} {
			outName := fmt.Sprintf("zlib_%s_level%d.bin", name, level)
			compressed := zlibCompress(data, level)
			os.WriteFile(filepath.Join(dir, outName), compressed, 0o644)
			entries = append(entries, GoldenEntry{
				Name:       fmt.Sprintf("zlib/%s/level%d", name, level),
				Algorithm:  "zlib",
				Level:      level,
				InputFile:  name + ".bin",
				OutputFile: outName,
				InputSize:  len(data),
				OutputSize: len(compressed),
			})
		}
	}

	// Generate LZW compressed files (LSB order, litWidth=8, like GIF)
	for name, data := range inputs {
		if len(data) == 0 {
			continue // LZW needs at least clear+eof codes
		}
		outName := fmt.Sprintf("lzw_%s.bin", name)
		compressed := lzwCompress(data)
		os.WriteFile(filepath.Join(dir, outName), compressed, 0o644)
		entries = append(entries, GoldenEntry{
			Name:       fmt.Sprintf("lzw/%s", name),
			Algorithm:  "lzw",
			InputFile:  name + ".bin",
			OutputFile: outName,
			InputSize:  len(data),
			OutputSize: len(compressed),
		})
	}

	// Generate DEFLATE with dictionary compressed files
	dict := []byte("the quick brown fox jumps over the lazy dog abcdefghijklmnop")
	os.WriteFile(filepath.Join(dir, "dict.bin"), dict, 0o644)
	// Use inputs that benefit from the dictionary
	dictInputs := map[string][]byte{
		"repeated": inputs["repeated"],
		"mixed_1k": inputs["mixed_1k"],
	}
	for name, data := range dictInputs {
		for _, level := range []int{1, 6, 9} {
			outName := fmt.Sprintf("deflate_dict_%s_level%d.bin", name, level)
			compressed := deflateDictCompress(data, dict, level)
			os.WriteFile(filepath.Join(dir, outName), compressed, 0o644)
			entries = append(entries, GoldenEntry{
				Name:       fmt.Sprintf("deflate_dict/%s/level%d", name, level),
				Algorithm:  "deflate_dict",
				Level:      level,
				InputFile:  name + ".bin",
				OutputFile: outName,
				InputSize:  len(data),
				OutputSize: len(compressed),
				DictFile:   "dict.bin",
			})
		}
	}

	// Generate zlib with dictionary compressed files
	for name, data := range dictInputs {
		for _, level := range []int{1, 6, 9} {
			outName := fmt.Sprintf("zlib_dict_%s_level%d.bin", name, level)
			compressed := zlibDictCompress(data, dict, level)
			os.WriteFile(filepath.Join(dir, outName), compressed, 0o644)
			entries = append(entries, GoldenEntry{
				Name:       fmt.Sprintf("zlib_dict/%s/level%d", name, level),
				Algorithm:  "zlib_dict",
				Level:      level,
				InputFile:  name + ".bin",
				OutputFile: outName,
				InputSize:  len(data),
				OutputSize: len(compressed),
				DictFile:   "dict.bin",
			})
		}
	}

	// Write manifest
	manifest, _ := json.MarshalIndent(entries, "", "  ")
	os.WriteFile(filepath.Join(dir, "manifest.json"), manifest, 0o644)
	fmt.Printf("Generated %d golden files in %s\n", len(entries), dir)
}

func generateMixed(size int) []byte {
	data := make([]byte, size)
	// Mix of text, repeated, and random
	copy(data, []byte("The quick brown fox jumps over the lazy dog. "))
	for i := 45; i < size/2; i++ {
		data[i] = byte(i % 256)
	}
	rand.Read(data[size/2:])
	return data
}

func deflateCompress(data []byte, level int) []byte {
	var buf bytes.Buffer
	w, _ := flate.NewWriter(&buf, level)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func gzipCompress(data []byte, level int) []byte {
	var buf bytes.Buffer
	w, _ := gzip.NewWriterLevel(&buf, level)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func zlibCompress(data []byte, level int) []byte {
	var buf bytes.Buffer
	w, _ := zlib.NewWriterLevel(&buf, level)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func deflateDictCompress(data, dict []byte, level int) []byte {
	var buf bytes.Buffer
	w, _ := flate.NewWriterDict(&buf, level, dict)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func zlibDictCompress(data, dict []byte, level int) []byte {
	var buf bytes.Buffer
	w, _ := zlib.NewWriterLevelDict(&buf, level, dict)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}

func lzwCompress(data []byte) []byte {
	var buf bytes.Buffer
	w := lzw.NewWriter(&buf, lzw.LSB, 8)
	w.Write(data)
	w.Close()
	return buf.Bytes()
}
