# bikallem/compress

A pure MoonBit compression library supporting DEFLATE, gzip, zlib, LZW, and bzip2. Targets native (Linux, Windows, macOS), JavaScript, and WebAssembly.

## Features

- Pure MoonBit — no FFI required (optional native acceleration for blit/checksum)
- Multi-target: native, js, and wasm-gc backends
- Dynamic Huffman coding with optimal fixed/dynamic block selection
- Level-differentiated compression: fast greedy (1-3), lazy matching (4-9)
- SA-IS suffix array construction for O(n) bzip2 BWT
- Hardware-accelerated CRC-32 (PCLMULQDQ) and Adler-32 (SSSE3) on native, software fallback elsewhere
- Two-level Huffman table decompression with zero-copy direct output
- BytesView-based streaming API — zero-copy input slicing
- Signal protocol streaming — no callbacks, no trait objects, explicit control flow
- Cross-validated against Go's `compress/*` stdlib

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

## Checksums

Stateful hashers implement the `Hasher` trait for incremental updates:

```moonbit
let h = @checksum.CRC32::new()
h.update(chunk1[:])
h.update(chunk2[:])
let result = h.checksum()
```

## Performance

Benchmarked on the native backend against Go's standard library. Ratio < 1 means MoonBit is faster.

Run benchmarks: `./tools/bench.sh --go`

### DEFLATE

| Benchmark | MoonBit | Go | Ratio |
|-----------|---------|-----|-------|
| compress 1 KB | 13 µs | 73 µs | **0.18x** |
| compress 10 KB | 22 µs | 86 µs | **0.26x** |
| compress 100 KB | 159 µs | 298 µs | **0.53x** |
| compress 1 MB | 1.72 ms | 1.94 ms | **0.89x** |
| compress 10 MB | 25.2 ms | 16.7 ms | 1.51x |
| decompress 1 KB | 0.76 µs | 4.2 µs | **0.18x** |
| decompress 10 KB | 4.4 µs | 10.9 µs | **0.40x** |
| decompress 100 KB | 22 µs | 57 µs | **0.39x** |
| decompress 1 MB | 213 µs | 856 µs | **0.25x** |
| decompress 10 MB | 3.5 ms | 9.8 ms | **0.36x** |

Decompression is **2.5-5.5x faster** than Go at all sizes. Compression is **faster up to 1 MB**; at 10 MB+ Go's more aggressive inlining gives it an edge.

### bzip2

| Benchmark | MoonBit | Go | Ratio |
|-----------|---------|-----|-------|
| compress 1 KB | 53 µs | 754 µs | **0.07x** |
| compress 10 KB | 482 µs | 2,047 µs | **0.24x** |
| compress 100 KB | 5.2 ms | 10.2 ms | **0.51x** |
| compress 1 MB | 83 ms | 112 ms | **0.74x** |
| decompress 1 KB | 115 µs | 420 µs | **0.27x** |
| decompress 10 KB | 168 µs | 541 µs | **0.31x** |
| decompress 100 KB | 660 µs | 1,225 µs | **0.54x** |
| decompress 1 MB | 5.6 ms | 7.2 ms | **0.78x** |

bzip2 uses SA-IS (O(n) suffix array construction) for the Burrows-Wheeler Transform. Go's benchmark uses the system `bzip2` binary (C) for compression and Go's `compress/bzip2` for decompression.

### LZW

| Benchmark | MoonBit | Go | Ratio |
|-----------|---------|-----|-------|
| compress 1 KB | 7.1 µs | 8.1 µs | **0.87x** |
| compress 10 KB | 40 µs | 41 µs | **0.96x** |
| compress 100 KB | 417 µs | 401 µs | 1.04x |
| compress 1 MB | 4.5 ms | 4.2 ms | 1.06x |
| decompress 1 KB | 3.6 µs | 4.7 µs | **0.77x** |
| decompress 10 KB | 16 µs | 26 µs | **0.62x** |
| decompress 100 KB | 137 µs | 245 µs | **0.56x** |
| decompress 1 MB | 1.6 ms | 2.7 ms | **0.58x** |

LZW compression is at parity with Go. Decompression is **1.7-2x faster**.

## License

Apache-2.0
