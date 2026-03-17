# bikallem/compress

A pure MoonBit compression library supporting Brotli, DEFLATE, gzip, zlib, LZW, and bzip2. Targets native (Linux, Windows, macOS), JavaScript, and WebAssembly.

## Features

- Pure MoonBit — no FFI required (optional native acceleration for blit/checksum)
- Brotli compression/decompression (RFC 7932) with one-shot and signal-based streaming APIs
- Multi-target: native, js, and wasm-gc backends
- Dynamic Huffman coding with optimal fixed/dynamic block selection
- Level-differentiated compression: fast greedy (1-3), lazy matching (4-9)
- SA-IS suffix array construction for O(n) bzip2 BWT
- Hardware-accelerated CRC-32 (PCLMULQDQ) and Adler-32 (SSSE3) on native, software fallback elsewhere
- Two-level Huffman table decompression with zero-copy direct output
- BytesView-based streaming API — zero-copy input slicing
- Signal protocol streaming — no callbacks, no trait objects, explicit control flow
- Cross-validated against Go's `compress/*` stdlib plus `github.com/andybalholm/brotli`

## Table of Contents

- [Packages](#packages)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Streaming API](#streaming-api)
  - [Compression](#compression)
  - [Decompression](#decompression)
  - [Format Wrappers](#format-wrappers)
- [Compression Levels](#compression-levels)
- [Checksums](#checksums)
- [Performance](#performance)
- [License](#license)

## Packages

| Package | Description |
|---------|-------------|
| `bikallem/compress/flate` | DEFLATE compression/decompression (RFC 1951) |
| `bikallem/compress/gzip` | gzip format (RFC 1952) |
| `bikallem/compress/zlib` | zlib format (RFC 1950) |
| `bikallem/compress/brotli` | Brotli compression/decompression (RFC 7932) |
| `bikallem/compress/lzw` | Lempel-Ziv-Welch (GIF/TIFF/PDF) |
| `bikallem/compress/bzip2` | bzip2 compression/decompression |
| `bikallem/compress/checksum` | CRC-32 and Adler-32 checksums |

## Installation

```
moon add bikallem/compress
```

## Quick Start

Every package provides one-shot `compress`/`decompress` functions for simple use cases:

```moonbit
// DEFLATE (level defaults to DefaultCompression)
let compressed = @flate.compress(data)
let compressed = @flate.compress(data, level=BestSpeed)
let decompressed = @flate.decompress(compressed)

// gzip
let compressed = @gzip.compress(data)
let compressed = @gzip.compress(data, level=BestCompression, header={ name: "data.txt", ..Header::default() })
let (decompressed, header) = @gzip.decompress(compressed)

// zlib (supports preset dictionaries)
let compressed = @zlib.compress(data)
let compressed = @zlib.compress(data, dict=my_dict, level=BestSpeed)
let decompressed = @zlib.decompress(compressed)

// Brotli (quality 0..11)
let compressed = @brotli.compress(data)
let compressed = @brotli.compress(data, level=BestCompression)
let decompressed = @brotli.decompress(compressed)

// LZW
let compressed = @lzw.compress(data, LSB, 8)
let decompressed = @lzw.decompress(compressed, LSB, 8)

// bzip2 (level 1-9, controls block size)
let compressed = @bzip2.compress(data)
let compressed = @bzip2.compress(data, level=9)
let decompressed = @bzip2.decompress(compressed)

// Checksums
let crc = @checksum.crc32(data[:])
let adler = @checksum.adler32(data[:])
```

Runnable examples live under `examples/brotli`, `examples/brotli_async`, and the corresponding format directories for the other codecs.

## Streaming API

All packages provide `Deflater` (compressor) and `Inflater` (decompressor) types that use a signal protocol for streaming. This gives callers explicit control over data flow without callbacks or trait objects.

### Compression

Feed data with `encode(Some(chunk[:]))`, finalize with `encode(None)`:

```moonbit
let d = @flate.Deflater::new(level=BestSpeed)
match d.encode(Some(data[:])) {
  Ok => ()         // input buffered, no output yet
  Data(out) => ... // compressed output ready
  End => ...       // shouldn't happen mid-stream
  Error(e) => ...  // compression error
}
loop d.encode(None) {
  Data(out) => { write(out); continue d.encode(None) }
  End => break
  Ok | Error(_) => break
}
```

### Decompression

Feed compressed data with `src(chunk[:])`, pull output with `decode()`:

```moonbit
let d = @flate.Inflater::new()
d.src(compressed_chunk[:])
loop d.decode() {
  Await => { d.src(next_chunk[:]); continue d.decode() }
  Data(out) => { write(out); continue d.decode() }
  End => break
  Error(e) => ...
}
```

### Format Wrappers

gzip and zlib deflaters/inflaters handle headers, checksums, and trailers automatically:

```moonbit
// gzip with custom header
let d = @gzip.Deflater::new(header={ name: "data.txt", ..Header::default() })
// Access the header after decompression
let header = inflater.header()

// zlib with preset dictionary
let d = @zlib.Deflater::new(dict=my_dict)
let i = @zlib.Inflater::new(dict=my_dict)

// Brotli
let d = @brotli.Deflater::new(level=BestCompression)
let i = @brotli.Inflater::new()

// LZW with bit order and literal width
let d = @lzw.Deflater::new(MSB, 8)
let i = @lzw.Inflater::new(MSB, 8)

// bzip2
let d = @bzip2.Deflater::new(level=9)
let i = @bzip2.Inflater::new()

// Get remaining unprocessed input after decompression
let leftover = inflater.remaining()
```

## Compression Levels

DEFLATE, gzip, and zlib support compression levels via `@flate.CompressionLevel`:

| Level | Description |
|-------|-------------|
| `NoCompression` | Store blocks only (level 0) |
| `BestSpeed` | Fastest compression (level 1) |
| `Level(2..8)` | Trade-off between speed and ratio |
| `BestCompression` | Smallest output (level 9) |
| `DefaultCompression` | Balanced default (level 6) |
| `HuffmanOnly` | Huffman encoding, no LZ77 matching |

bzip2 uses its own level parameter (1-9), controlling block size (N x 100KB).

Brotli uses `@brotli.CompressionLevel` with qualities `0..11`:

| Level | Description |
|-------|-------------|
| `NoCompression` | Emit uncompressed meta-blocks |
| `BestSpeed` | Fastest compressed output |
| `Level(2..10)` | Intermediate quality settings |
| `BestCompression` | Highest quality setting |
| `DefaultCompression` | Current default, same as `BestCompression` |

The current pure MoonBit Brotli encoder is correctness-first. Higher qualities primarily improve long-run compression; they do not yet aim for ratio parity with the reference Brotli encoder on general text and mixed data.

## Checksums

Stateful hashers implement the `Hasher` trait for incremental updates:

```moonbit
let h = @checksum.CRC32::new()
h.update(chunk1[:])
h.update(chunk2[:])
let result = h.checksum()
```

## Performance

Benchmarked on the native backend against Go's standard library (v0.1.2). Ratio < 1 means MoonBit is faster.

Run benchmarks: `./tools/bench.sh --go`

The benchmark generator and `bench.sh` also include Brotli. To focus on those results only, run `./tools/bench.sh --go --filter brotli`.

### DEFLATE

| Benchmark | MoonBit | Go | Ratio |
|-----------|---------|-----|-------|
| compress 1 KB | 16 µs | 67 µs | **0.24x** |
| compress 10 KB | 63 µs | 124 µs | **0.51x** |
| compress 100 KB | 570 µs | 298 µs | 1.91x |
| compress 1 MB | 6.2 ms | 2.0 ms | 3.06x |
| compress speed 1 KB | 12 µs | 134 µs | **0.09x** |
| compress speed 10 KB | 15 µs | 125 µs | **0.12x** |
| decompress 1 KB | 0.82 µs | 4.0 µs | **0.21x** |
| decompress 10 KB | 5.1 µs | 10.7 µs | **0.47x** |
| decompress 100 KB | 29 µs | 58 µs | **0.50x** |
| decompress 1 MB | 305 µs | 915 µs | **0.33x** |
| decompress 10 MB | 4.8 ms | 10.5 ms | **0.46x** |

Decompression is **2-5x faster** than Go at all sizes. BestSpeed compression is **8-11x faster**. Default compression is faster up to 10 KB; at larger sizes Go's more aggressive match-finding gives it an edge.

### bzip2

| Benchmark | MoonBit | Go | Ratio |
|-----------|---------|-----|-------|
| compress 1 KB | 54 µs | 754 µs | **0.07x** |
| compress 10 KB | 500 µs | 2,047 µs | **0.24x** |
| compress 100 KB | 5.4 ms | 10.2 ms | **0.53x** |
| compress 1 MB | 107 ms | 112 ms | **0.95x** |
| decompress 1 KB | 123 µs | 420 µs | **0.29x** |
| decompress 10 KB | 167 µs | 541 µs | **0.31x** |
| decompress 100 KB | 680 µs | 1,225 µs | **0.55x** |
| decompress 1 MB | 6.0 ms | 7.2 ms | **0.83x** |

bzip2 uses SA-IS (O(n) suffix array construction) for the Burrows-Wheeler Transform. Go's benchmark uses the system `bzip2` binary (C) for compression and Go's `compress/bzip2` for decompression.

### LZW

| Benchmark | MoonBit | Go | Ratio |
|-----------|---------|-----|-------|
| compress 1 KB | 7.4 µs | 8.6 µs | **0.86x** |
| compress 10 KB | 41 µs | 42 µs | **0.98x** |
| compress 100 KB | 424 µs | 427 µs | **0.99x** |
| compress 1 MB | 4.6 ms | 4.3 ms | 1.05x |
| decompress 1 KB | 3.7 µs | 4.7 µs | **0.78x** |
| decompress 10 KB | 16 µs | 26 µs | **0.63x** |
| decompress 100 KB | 140 µs | 244 µs | **0.57x** |
| decompress 1 MB | 1.6 ms | 2.7 ms | **0.57x** |

LZW compression is at parity with Go. Decompression is **1.3-1.8x faster**.

## License

Apache-2.0
