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

func BenchmarkFlateCompressDict10KB(b *testing.B) {
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

func BenchmarkFlateCompressDict100KB(b *testing.B) {
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

// Ensure genRandom and genText use same strings package for compiler
var _ = strings.NewReader("")
