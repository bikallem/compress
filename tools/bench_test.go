package tools

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/lzw"
	"compress/zlib"
	"hash/adler32"
	"hash/crc32"
	"io"
	"strings"
	"testing"
)

// genText generates repeated text data of the given size.
func genText(size int) []byte {
	phrase := "The quick brown fox jumps over the lazy dog. "
	buf := make([]byte, size)
	for i := 0; i < size; i++ {
		buf[i] = phrase[i%len(phrase)]
	}
	return buf
}

// genZeros generates all-zero data.
func genZeros(size int) []byte {
	return make([]byte, size)
}

// genRandom generates pseudo-random data (same LCG as MoonBit).
func genRandom(size int) []byte {
	buf := make([]byte, size)
	state := uint32(0x12345678)
	for i := 0; i < size; i++ {
		state = state*1103515245 + 12345
		buf[i] = byte((state >> 16) & 0xFF)
	}
	return buf
}

// --- CRC-32 ---

func BenchmarkCRC32_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		crc32.ChecksumIEEE(data)
	}
}

func BenchmarkCRC32_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		crc32.ChecksumIEEE(data)
	}
}

func BenchmarkCRC32_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		crc32.ChecksumIEEE(data)
	}
}

// --- Adler-32 ---

func BenchmarkAdler32_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		adler32.Checksum(data)
	}
}

func BenchmarkAdler32_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		adler32.Checksum(data)
	}
}

func BenchmarkAdler32_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		adler32.Checksum(data)
	}
}

// --- DEFLATE compress ---

func BenchmarkFlateCompressDefault_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressDefault_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressSpeed_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.BestSpeed)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressBest_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.BestCompression)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressRandom_10kb(b *testing.B) {
	data := genRandom(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.BestSpeed)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressZeros_10kb(b *testing.B) {
	data := genZeros(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
	}
}

// --- DEFLATE decompress ---

func BenchmarkFlateDecompress_1kb(b *testing.B) {
	data := genText(1024)
	var cbuf bytes.Buffer
	w, _ := flate.NewWriter(&cbuf, flate.DefaultCompression)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := flate.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
		r.Close()
	}
}

func BenchmarkFlateDecompress_10kb(b *testing.B) {
	data := genText(10240)
	var cbuf bytes.Buffer
	w, _ := flate.NewWriter(&cbuf, flate.DefaultCompression)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := flate.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
		r.Close()
	}
}

func BenchmarkFlateDecompressZeros_10kb(b *testing.B) {
	data := genZeros(10240)
	var cbuf bytes.Buffer
	w, _ := flate.NewWriter(&cbuf, flate.DefaultCompression)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := flate.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
		r.Close()
	}
}

// --- gzip ---

func BenchmarkGzipCompressDefault_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkGzipCompressDefault_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkGzipDecompress_1kb(b *testing.B) {
	data := genText(1024)
	var cbuf bytes.Buffer
	w := gzip.NewWriter(&cbuf)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r, _ := gzip.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
		r.Close()
	}
}

func BenchmarkGzipDecompress_10kb(b *testing.B) {
	data := genText(10240)
	var cbuf bytes.Buffer
	w := gzip.NewWriter(&cbuf)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r, _ := gzip.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
		r.Close()
	}
}

// --- zlib ---

func BenchmarkZlibCompressDefault_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkZlibDecompress_10kb(b *testing.B) {
	data := genText(10240)
	var cbuf bytes.Buffer
	w := zlib.NewWriter(&cbuf)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r, _ := zlib.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
		r.Close()
	}
}

// --- LZW ---

func BenchmarkLzwCompressLSB_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := lzw.NewWriter(&buf, lzw.LSB, 8)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkLzwCompressLSB_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := lzw.NewWriter(&buf, lzw.LSB, 8)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkLzwDecompressLSB_1kb(b *testing.B) {
	data := genText(1024)
	var cbuf bytes.Buffer
	w := lzw.NewWriter(&cbuf, lzw.LSB, 8)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := lzw.NewReader(bytes.NewReader(compressed), lzw.LSB, 8)
		io.ReadAll(r)
		r.Close()
	}
}

func BenchmarkLzwDecompressLSB_10kb(b *testing.B) {
	data := genText(10240)
	var cbuf bytes.Buffer
	w := lzw.NewWriter(&cbuf, lzw.LSB, 8)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := lzw.NewReader(bytes.NewReader(compressed), lzw.LSB, 8)
		io.ReadAll(r)
		r.Close()
	}
}

// Ensure genRandom and genText use same strings package for compiler
var _ = strings.NewReader("")
