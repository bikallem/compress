// bench_1gb_test.go — compress/decompress 1GB with Go's compress/flate.
// Validates output and measures latency + RSS.
//
// Usage: go test -run TestBench1GB -v -timeout 600s
package tools

import (
	"compress/flate"
	"fmt"
	"io"
	"os"
	"runtime"
	"testing"
	"time"
)

func getRSS() uint64 {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m.Sys
}

func TestBench1GB(t *testing.T) {
	const inputPath = "/tmp/bench_1gb.bin"
	const compressedPath = "/tmp/bench_1gb.deflate"
	const decompressedPath = "/tmp/bench_1gb.roundtrip"

	// Check input exists
	info, err := os.Stat(inputPath)
	if err != nil {
		t.Fatalf("input file missing: %v (run: go run gen_corpus.go %s)", err, inputPath)
	}
	inputSize := info.Size()
	fmt.Printf("Input: %s (%d MB)\n", inputPath, inputSize>>20)

	// --- COMPRESS ---
	runtime.GC()
	rssBeforeCompress := getRSS()
	t0 := time.Now()

	fin, err := os.Open(inputPath)
	if err != nil {
		t.Fatal(err)
	}
	fout, err := os.Create(compressedPath)
	if err != nil {
		fin.Close()
		t.Fatal(err)
	}
	w, err := flate.NewWriter(fout, flate.DefaultCompression)
	if err != nil {
		fin.Close()
		fout.Close()
		t.Fatal(err)
	}
	n, err := io.Copy(w, fin)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	fout.Close()
	fin.Close()

	compressDur := time.Since(t0)
	runtime.GC()
	rssAfterCompress := getRSS()
	cinfo, _ := os.Stat(compressedPath)
	compressedSize := cinfo.Size()
	ratio := float64(compressedSize) / float64(inputSize) * 100

	fmt.Printf("\n=== COMPRESS (Go flate, level 6) ===\n")
	fmt.Printf("Input:      %d bytes (%d MB)\n", n, n>>20)
	fmt.Printf("Output:     %d bytes (%d MB, %.1f%%)\n", compressedSize, compressedSize>>20, ratio)
	fmt.Printf("Time:       %v\n", compressDur.Round(time.Millisecond))
	fmt.Printf("Throughput: %.1f MB/s\n", float64(inputSize)/compressDur.Seconds()/1048576)
	fmt.Printf("RSS before: %d MB\n", rssBeforeCompress>>20)
	fmt.Printf("RSS after:  %d MB\n", rssAfterCompress>>20)

	// --- DECOMPRESS ---
	runtime.GC()
	rssBeforeDecompress := getRSS()
	t1 := time.Now()

	fin2, err := os.Open(compressedPath)
	if err != nil {
		t.Fatal(err)
	}
	fout2, err := os.Create(decompressedPath)
	if err != nil {
		fin2.Close()
		t.Fatal(err)
	}
	r := flate.NewReader(fin2)
	written, err := io.Copy(fout2, r)
	if err != nil {
		t.Fatal(err)
	}
	r.Close()
	fout2.Close()
	fin2.Close()

	decompressDur := time.Since(t1)
	runtime.GC()
	rssAfterDecompress := getRSS()

	fmt.Printf("\n=== DECOMPRESS (Go flate) ===\n")
	fmt.Printf("Output:     %d bytes (%d MB)\n", written, written>>20)
	fmt.Printf("Time:       %v\n", decompressDur.Round(time.Millisecond))
	fmt.Printf("Throughput: %.1f MB/s\n", float64(written)/decompressDur.Seconds()/1048576)
	fmt.Printf("RSS before: %d MB\n", rssBeforeDecompress>>20)
	fmt.Printf("RSS after:  %d MB\n", rssAfterDecompress>>20)

	// --- VALIDATE ---
	if written != inputSize {
		t.Fatalf("size mismatch: got %d, want %d", written, inputSize)
	}

	// Byte-compare via diff
	fmt.Printf("\n=== VALIDATE ===\n")
	fmt.Printf("Comparing %s vs %s...\n", inputPath, decompressedPath)
	orig, _ := os.ReadFile(inputPath)
	rt, _ := os.ReadFile(decompressedPath)
	if len(orig) != len(rt) {
		t.Fatalf("length mismatch: %d vs %d", len(orig), len(rt))
	}
	for i := range orig {
		if orig[i] != rt[i] {
			t.Fatalf("mismatch at byte %d: got %x, want %x", i, rt[i], orig[i])
		}
	}
	fmt.Println("PASS: round-trip matches")

	// Cleanup
	os.Remove(compressedPath)
	os.Remove(decompressedPath)
}
