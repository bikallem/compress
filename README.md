# bikallem/compress

A pure MoonBit compression library ported from Go's `compress/*` stdlib.

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

Feed data with `encode(Some(chunk))`, finalize with `encode(None)`:

```moonbit
let d = @flate.Deflater::new(level=BestSpeed)
match d.encode(Some(data)) {
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

Feed compressed data with `src(chunk)`, pull output with `decode()`:

```moonbit
let d = @flate.Inflater::new()
d.src(compressed_chunk)
loop d.decode() {
  Await => { d.src(next_chunk); continue d.decode() }
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

Benchmarked on the native backend against Go's `compress/flate` (the reference implementation this library is ported from). Ratio < 1 means MoonBit is faster.

### Decompression

Zero-copy direct output mode eliminates intermediate allocations — the decode loop runs start-to-finish without yielding, writing directly into a single output buffer.

| Size | MoonBit | Go | Ratio |
|------|---------|------|-------|
| 1 KB | 0.72 us | 4.82 us | 0.15x |
| 10 KB | 4.97 us | 11.8 us | 0.42x |
| 100 KB | 26.8 us | 55.2 us | 0.49x |
| 1 MB | 249 us | 1,092 us | 0.23x |
| 10 MB | 4.06 ms | 10.8 ms | 0.38x |

Throughput scales linearly — 1,750-2,400 MB/s from 100 MB to 10 GB with constant 4 MB RSS (streaming file-based benchmark).

### Compression

| Size | MoonBit | Go | Ratio |
|------|---------|------|-------|
| 1 KB | 18.1 us | 93.4 us | 0.19x |
| 10 KB | 72.2 us | 115 us | 0.63x |
| 100 KB | 645 us | 322 us | 2.00x |
| 1 MB | 6,840 us | 2,219 us | 3.08x |

Compression at small sizes is faster than Go; at larger sizes Go's more mature hash chain implementation is faster.

## Features

- Pure MoonBit — no FFI required (optional native blit acceleration)
- Multi-target: native, js, and wasm-gc backends
- Dynamic Huffman coding with optimal fixed/dynamic block selection
- Level-differentiated compression: fast greedy (1-3), lazy matching (4-9)
- Slicing-by-8 CRC-32, SIMD-style unrolled Adler-32
- Two-level Huffman table decompression with zero-copy direct output
- Signal protocol streaming — no callbacks, no trait objects, explicit control flow
- Cross-validated against Go's `compress/*` stdlib

## License

Apache-2.0
