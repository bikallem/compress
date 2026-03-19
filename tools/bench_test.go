package tools

import (
	"bytes"
	"compress/bzip2"
	"compress/flate"
	"compress/gzip"
	"compress/lzw"
	"compress/zlib"
	"hash/adler32"
	"hash/crc32"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/andybalholm/brotli"
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

func BenchmarkFlateCompressSpeed_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.BestSpeed)
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

func BenchmarkFlateDecompress_100kb(b *testing.B) {
	data := genText(102400)
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

func BenchmarkFlateDecompress_1mb(b *testing.B) {
	data := genText(1048576)
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

func BenchmarkFlateDecompress_10mb(b *testing.B) {
	data := genText(10485760)
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

func BenchmarkFlateDecompress_100mb(b *testing.B) {
	data := genText(104857600)
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

func BenchmarkFlateCompressDefault_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressDefault_1mb(b *testing.B) {
	data := genText(1048576)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressDefault_10mb(b *testing.B) {
	data := genText(10485760)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressDefault_100mb(b *testing.B) {
	data := genText(104857600)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
		w.Write(data)
		w.Close()
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

func BenchmarkGzipCompressSpeed_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := gzip.NewWriterLevel(&buf, gzip.BestSpeed)
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

func BenchmarkGzipDecompress_100kb(b *testing.B) {
	data := genText(102400)
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

func BenchmarkGzipDecompress_1mb(b *testing.B) {
	data := genText(1048576)
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

func BenchmarkGzipDecompress_10mb(b *testing.B) {
	data := genText(10485760)
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

func BenchmarkGzipDecompress_100mb(b *testing.B) {
	data := genText(104857600)
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

func BenchmarkGzipCompressDefault_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkGzipCompressDefault_1mb(b *testing.B) {
	data := genText(1048576)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkGzipCompressDefault_10mb(b *testing.B) {
	data := genText(10485760)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkGzipCompressDefault_100mb(b *testing.B) {
	data := genText(104857600)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

// --- zlib ---

func BenchmarkZlibCompressDefault_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

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

func BenchmarkZlibCompressSpeed_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := zlib.NewWriterLevel(&buf, zlib.BestSpeed)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkZlibDecompress_1kb(b *testing.B) {
	data := genText(1024)
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

func BenchmarkZlibDecompress_100kb(b *testing.B) {
	data := genText(102400)
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

func BenchmarkZlibDecompress_1mb(b *testing.B) {
	data := genText(1048576)
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

func BenchmarkZlibDecompress_10mb(b *testing.B) {
	data := genText(10485760)
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

func BenchmarkZlibDecompress_100mb(b *testing.B) {
	data := genText(104857600)
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

func BenchmarkZlibCompressDefault_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkZlibCompressDefault_1mb(b *testing.B) {
	data := genText(1048576)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkZlibCompressDefault_10mb(b *testing.B) {
	data := genText(10485760)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkZlibCompressDefault_100mb(b *testing.B) {
	data := genText(104857600)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		w.Write(data)
		w.Close()
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

func BenchmarkLzwDecompressLSB_100kb(b *testing.B) {
	data := genText(102400)
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

func BenchmarkLzwDecompressLSB_1mb(b *testing.B) {
	data := genText(1048576)
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

func BenchmarkLzwDecompressLSB_10mb(b *testing.B) {
	data := genText(10485760)
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

func BenchmarkLzwDecompressLSB_100mb(b *testing.B) {
	data := genText(104857600)
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

func BenchmarkLzwCompressLSB_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := lzw.NewWriter(&buf, lzw.LSB, 8)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkLzwCompressLSB_1mb(b *testing.B) {
	data := genText(1048576)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := lzw.NewWriter(&buf, lzw.LSB, 8)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkLzwCompressLSB_10mb(b *testing.B) {
	data := genText(10485760)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := lzw.NewWriter(&buf, lzw.LSB, 8)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkLzwCompressLSB_100mb(b *testing.B) {
	data := genText(104857600)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := lzw.NewWriter(&buf, lzw.LSB, 8)
		w.Write(data)
		w.Close()
	}
}

// --- Dict benchmarks ---

func BenchmarkFlateCompressDict_10kb(b *testing.B) {
	dict := []byte("The quick brown fox jumps over the lazy dog. ")
	data := genText(10240)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriterDict(&buf, flate.DefaultCompression, dict)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkFlateCompressDict_100kb(b *testing.B) {
	dict := []byte("The quick brown fox jumps over the lazy dog. ")
	data := genText(102400)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w, _ := flate.NewWriterDict(&buf, flate.DefaultCompression, dict)
		w.Write(data)
		w.Close()
	}
}

// --- bzip2 ---
// Go's compress/bzip2 only provides a decompressor.
// We use the system bzip2 command to generate compressed test data.

func bzip2Compress(data []byte) ([]byte, error) {
	cmd := exec.Command("bzip2", "-c")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Output()
}

func BenchmarkBzip2CompressDefault_1kb(b *testing.B) {
	data := genText(1024)
	if _, err := bzip2Compress(data); err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bzip2Compress(data)
	}
}

func BenchmarkBzip2CompressDefault_10kb(b *testing.B) {
	data := genText(10240)
	if _, err := bzip2Compress(data); err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bzip2Compress(data)
	}
}

func BenchmarkBzip2CompressDefault_100kb(b *testing.B) {
	data := genText(102400)
	if _, err := bzip2Compress(data); err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bzip2Compress(data)
	}
}

func BenchmarkBzip2CompressDefault_1mb(b *testing.B) {
	data := genText(1048576)
	if _, err := bzip2Compress(data); err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bzip2Compress(data)
	}
}

func BenchmarkBzip2CompressDefault_10mb(b *testing.B) {
	data := genText(10485760)
	if _, err := bzip2Compress(data); err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bzip2Compress(data)
	}
}

func BenchmarkBzip2CompressDefault_100mb(b *testing.B) {
	data := genText(104857600)
	if _, err := bzip2Compress(data); err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bzip2Compress(data)
	}
}

func BenchmarkBzip2Decompress_1kb(b *testing.B) {
	data := genText(1024)
	compressed, err := bzip2Compress(data)
	if err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := bzip2.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBzip2Decompress_10kb(b *testing.B) {
	data := genText(10240)
	compressed, err := bzip2Compress(data)
	if err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := bzip2.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBzip2Decompress_100kb(b *testing.B) {
	data := genText(102400)
	compressed, err := bzip2Compress(data)
	if err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := bzip2.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBzip2Decompress_1mb(b *testing.B) {
	data := genText(1048576)
	compressed, err := bzip2Compress(data)
	if err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := bzip2.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBzip2Decompress_10mb(b *testing.B) {
	data := genText(10485760)
	compressed, err := bzip2Compress(data)
	if err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := bzip2.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBzip2Decompress_100mb(b *testing.B) {
	data := genText(104857600)
	compressed, err := bzip2Compress(data)
	if err != nil {
		b.Skip("bzip2 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := bzip2.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

// --- Streaming benchmarks ---
// File-based: read input file → compress/decompress → write output file.
// Matches the MoonBit streaming benchmarks which also use file I/O.

func writeTempFile(b *testing.B, data []byte, pattern string) string {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		b.Fatal(err)
	}
	f.Write(data)
	f.Close()
	return f.Name()
}

func BenchmarkFlateCompressStreaming_1mb(b *testing.B) {
	data := genText(1048576)
	inPath := writeTempFile(b, data, "bench-stream-in-*.bin")
	outPath := inPath + ".deflate"
	defer os.Remove(inPath)
	defer os.Remove(outPath)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		fin, _ := os.Open(inPath)
		fout, _ := os.Create(outPath)
		w, _ := flate.NewWriter(fout, flate.DefaultCompression)
		io.Copy(w, fin)
		w.Close()
		fout.Close()
		fin.Close()
	}
}

func BenchmarkFlateCompressStreaming_10mb(b *testing.B) {
	data := genText(10485760)
	inPath := writeTempFile(b, data, "bench-stream-in-*.bin")
	outPath := inPath + ".deflate"
	defer os.Remove(inPath)
	defer os.Remove(outPath)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		fin, _ := os.Open(inPath)
		fout, _ := os.Create(outPath)
		w, _ := flate.NewWriter(fout, flate.DefaultCompression)
		io.Copy(w, fin)
		w.Close()
		fout.Close()
		fin.Close()
	}
}

func BenchmarkFlateDecompressStreaming_1mb(b *testing.B) {
	data := genText(1048576)
	var cbuf bytes.Buffer
	w, _ := flate.NewWriter(&cbuf, flate.DefaultCompression)
	w.Write(data)
	w.Close()
	inPath := writeTempFile(b, cbuf.Bytes(), "bench-stream-dec-*.deflate")
	outPath := inPath + ".bin"
	defer os.Remove(inPath)
	defer os.Remove(outPath)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		fin, _ := os.Open(inPath)
		fout, _ := os.Create(outPath)
		r := flate.NewReader(fin)
		io.Copy(fout, r)
		r.Close()
		fout.Close()
		fin.Close()
	}
}

func BenchmarkFlateDecompressStreaming_10mb(b *testing.B) {
	data := genText(10485760)
	var cbuf bytes.Buffer
	w, _ := flate.NewWriter(&cbuf, flate.DefaultCompression)
	w.Write(data)
	w.Close()
	inPath := writeTempFile(b, cbuf.Bytes(), "bench-stream-dec-*.deflate")
	outPath := inPath + ".bin"
	defer os.Remove(inPath)
	defer os.Remove(outPath)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		fin, _ := os.Open(inPath)
		fout, _ := os.Create(outPath)
		r := flate.NewReader(fin)
		io.Copy(fout, r)
		r.Close()
		fout.Close()
		fin.Close()
	}
}

func BenchmarkLzwDecompressStreaming_1mb(b *testing.B) {
	data := genText(1048576)
	var cbuf bytes.Buffer
	w := lzw.NewWriter(&cbuf, lzw.LSB, 8)
	w.Write(data)
	w.Close()
	inPath := writeTempFile(b, cbuf.Bytes(), "bench-stream-dec-*.lzw")
	outPath := inPath + ".bin"
	defer os.Remove(inPath)
	defer os.Remove(outPath)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		fin, _ := os.Open(inPath)
		fout, _ := os.Create(outPath)
		r := lzw.NewReader(fin, lzw.LSB, 8)
		io.Copy(fout, r)
		r.Close()
		fout.Close()
		fin.Close()
	}
}

// Ensure genRandom and genText use same strings package for compiler
var _ = strings.NewReader("")

// --- Snappy (requires github.com/golang/snappy) ---
// Note: Snappy Go benchmarks require adding the dependency.
// Uncomment when github.com/golang/snappy is available in go.mod.

// --- LZ4 ---
// Uses the system lz4 command for both compress and decompress benchmarks.
// NOTE: results include process spawn overhead (~2-5ms per iteration),
// so these are not directly comparable to in-process library benchmarks.
// They are still useful for tracking relative performance across sizes.

func lz4Compress(data []byte) ([]byte, error) {
	cmd := exec.Command("lz4", "-c", "-f", "--no-frame-crc")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Output()
}

func lz4DecompressBench(data []byte) ([]byte, error) {
	cmd := exec.Command("lz4", "-d", "-c", "-f")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Output()
}

func BenchmarkLz4CompressDefault_1kb(b *testing.B) {
	data := genText(1024)
	if _, err := lz4Compress(data); err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4Compress(data)
	}
}

func BenchmarkLz4CompressDefault_10kb(b *testing.B) {
	data := genText(10240)
	if _, err := lz4Compress(data); err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4Compress(data)
	}
}

func BenchmarkLz4CompressDefault_100kb(b *testing.B) {
	data := genText(102400)
	if _, err := lz4Compress(data); err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4Compress(data)
	}
}

func BenchmarkLz4CompressDefault_1mb(b *testing.B) {
	data := genText(1048576)
	if _, err := lz4Compress(data); err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4Compress(data)
	}
}

func BenchmarkLz4Decompress_1kb(b *testing.B) {
	data := genText(1024)
	compressed, err := lz4Compress(data)
	if err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4DecompressBench(compressed)
	}
}

func BenchmarkLz4Decompress_10kb(b *testing.B) {
	data := genText(10240)
	compressed, err := lz4Compress(data)
	if err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4DecompressBench(compressed)
	}
}

func BenchmarkLz4Decompress_100kb(b *testing.B) {
	data := genText(102400)
	compressed, err := lz4Compress(data)
	if err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4DecompressBench(compressed)
	}
}

func BenchmarkLz4Decompress_1mb(b *testing.B) {
	data := genText(1048576)
	compressed, err := lz4Compress(data)
	if err != nil {
		b.Skip("lz4 command not available")
	}
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lz4DecompressBench(compressed)
	}
}

// --- Zstandard (requires github.com/klauspost/compress/zstd) ---
// Note: Zstd Go benchmarks require adding the dependency.
// Uncomment when github.com/klauspost/compress/zstd is available in go.mod.

// --- Brotli (github.com/andybalholm/brotli) ---

func BenchmarkBrotliCompressDefault_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 6)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressDefault_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 6)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressDefault_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 6)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressDefault_1mb(b *testing.B) {
	data := genText(1048576)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 6)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressDefault_10mb(b *testing.B) {
	data := genText(10485760)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 6)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressDefault_100mb(b *testing.B) {
	data := genText(104857600)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 6)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliDecompress_1kb(b *testing.B) {
	data := genText(1024)
	var cbuf bytes.Buffer
	w := brotli.NewWriterLevel(&cbuf, 6)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := brotli.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBrotliDecompress_10kb(b *testing.B) {
	data := genText(10240)
	var cbuf bytes.Buffer
	w := brotli.NewWriterLevel(&cbuf, 6)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := brotli.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBrotliDecompress_100kb(b *testing.B) {
	data := genText(102400)
	var cbuf bytes.Buffer
	w := brotli.NewWriterLevel(&cbuf, 6)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := brotli.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBrotliDecompress_1mb(b *testing.B) {
	data := genText(1048576)
	var cbuf bytes.Buffer
	w := brotli.NewWriterLevel(&cbuf, 6)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := brotli.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBrotliDecompress_10mb(b *testing.B) {
	data := genText(10485760)
	var cbuf bytes.Buffer
	w := brotli.NewWriterLevel(&cbuf, 6)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := brotli.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBrotliDecompress_100mb(b *testing.B) {
	data := genText(104857600)
	var cbuf bytes.Buffer
	w := brotli.NewWriterLevel(&cbuf, 6)
	w.Write(data)
	w.Close()
	compressed := cbuf.Bytes()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r := brotli.NewReader(bytes.NewReader(compressed))
		io.ReadAll(r)
	}
}

func BenchmarkBrotliCompressSpeed_1kb(b *testing.B) {
	data := genText(1024)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 1)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressSpeed_10kb(b *testing.B) {
	data := genText(10240)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 1)
		w.Write(data)
		w.Close()
	}
}

func BenchmarkBrotliCompressSpeed_100kb(b *testing.B) {
	data := genText(102400)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var buf bytes.Buffer
		w := brotli.NewWriterLevel(&buf, 1)
		w.Write(data)
		w.Close()
	}
}
