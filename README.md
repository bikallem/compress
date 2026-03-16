# bikallem/compress

A pure MoonBit compression library supporting DEFLATE, gzip, zlib, LZW, and bzip2. Targets native (Linux, Windows, macOS), JavaScript, and WebAssembly.

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
- [Features](#features)
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
  _ => break
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

bzip2 uses its own level parameter (1-9), controlling block size (N × 100KB).

## Checksums

Stateful hashers implement the `Hasher` trait for incremental updates:

```moonbit
let h = @checksum.CRC32::new()
h.update(chunk1[:])
h.update(chunk2[:])
let result = h.checksum()
```

## Performance

Benchmarked on the native backend against Go's `compress/flate`. Ratio < 1 means MoonBit is faster.

Run benchmarks: `./tools/bench.sh --go`

### DEFLATE Decompression

Zero-copy direct output mode — the decode loop writes directly into a single output buffer without intermediate allocations.

| Size | MoonBit | Go | Ratio |
|------|---------|------|-------|
| 1 KB | 0.75 µs | 3.9 µs | 0.19x |
| 10 KB | 4.7 µs | 10.7 µs | 0.44x |
| 100 KB | 23 µs | 58 µs | 0.40x |
| 1 MB | 205 µs | 935 µs | 0.22x |
| 10 MB | 3.7 ms | 10.0 ms | 0.37x |

MoonBit decompression is **2-5x faster** than Go across all sizes.

### DEFLATE Compression

| Size | MoonBit | Go | Ratio |
|------|---------|------|-------|
| 1 KB | 13 µs | 66 µs | 0.20x |
| 10 KB | 22 µs | 95 µs | 0.24x |
| 100 KB | 154 µs | 308 µs | 0.50x |
| 1 MB | 1.7 ms | 2.0 ms | 0.87x |
| 10 MB | 18.4 ms | 17.1 ms | 1.07x |

MoonBit compression is **faster than or on par with Go** at all sizes up to 10 MB.

## Features

- Pure MoonBit — no FFI required (optional native blit acceleration)
- Multi-target: native, js, and wasm-gc backends
- Dynamic Huffman coding with optimal fixed/dynamic block selection
- Level-differentiated compression: fast greedy (1-3), lazy matching (4-9)
- SA-IS suffix array construction for O(n) bzip2 BWT
- Slicing-by-8 CRC-32, SIMD-style unrolled Adler-32
- Two-level Huffman table decompression with zero-copy direct output
- BytesView-based streaming API — zero-copy input slicing
- Signal protocol streaming — no callbacks, no trait objects, explicit control flow
- Cross-validated against Go's `compress/*` stdlib

## License

Apache-2.0
