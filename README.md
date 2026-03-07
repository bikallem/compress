# blem00/compress

A pure MoonBit compression library implementing standard compression formats.

## Packages

| Package | Description |
|---------|-------------|
| `blem00/compress/flate` | DEFLATE compression/decompression (RFC 1951) |
| `blem00/compress/gzip` | gzip format (RFC 1952) |
| `blem00/compress/zlib` | zlib format (RFC 1950) |
| `blem00/compress/lzw` | Lempel-Ziv-Welch (GIF/TIFF/PDF) |
| `blem00/compress/bzip2` | bzip2 decompression |
| `blem00/compress/checksum` | CRC-32 and Adler-32 checksums |

## Installation

```
moon add blem00/compress
```

## Usage

### DEFLATE

```moonbit
let data : Bytes = b"Hello, World!"
let compressed = @flate.compress(data)
let decompressed = @flate.decompress(compressed)
```

Compression levels: `NoCompression`, `BestSpeed`, `Level(1..9)`, `BestCompression`, `DefaultCompression`, `HuffmanOnly`.

### gzip

```moonbit
let compressed = @gzip.compress(data)
let (decompressed, header) = @gzip.decompress(compressed)
```

### zlib

```moonbit
let compressed = @zlib.compress(data)
let decompressed = @zlib.decompress(compressed)
```

### LZW

```moonbit
let compressed = @lzw.compress(data, LSB, 8)
let decompressed = @lzw.decompress(compressed, LSB, 8)
```

### bzip2 (decompress only)

```moonbit
let decompressed = @bzip2.decompress(compressed)
```

### Checksums

```moonbit
let crc = @checksum.crc32(data[:])
let adler = @checksum.adler32(data[:])
```

## Features

- Pure MoonBit — no FFI or native dependencies
- Dynamic Huffman encoding with fixed/dynamic block selection
- Level-differentiated compression (fast greedy, lazy matching)
- Slicing-by-8 CRC-32, unrolled Adler-32
- Two-level Huffman table decompression
- Async streaming variants for all formats
- Cross-validated against Go's `compress/*` stdlib

## License

Apache-2.0
