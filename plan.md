# Implementation Plan: Zstandard, Snappy, LZ4, and Brotli Codecs

## Overview

Add four new compression codecs to `bikallem/compress`, following the established architecture:
- **Zstandard (zstd)** — RFC 8878, modern general-purpose codec
- **Snappy** — Google's speed-optimized codec
- **LZ4** — Extremely fast codec with frame format (LZ4F)
- **Brotli** — RFC 7932, HTTP-optimized codec with static dictionary

Each codec follows the project's signal-based streaming pattern with `Encode`/`Decode` enums,
one-shot `compress()`/`decompress()` convenience functions, and streaming `Deflater`/`Inflater` types.

### New Checksum: XXH64

Zstd and LZ4 frames use XXH64 checksums. Add `xxhash` to the `checksum/` module implementing the `Hasher` trait.

### SHA-256

Use `moonbitlang/x/crypto` package (as per user request) — no custom implementation needed. Add as a dependency where required (e.g., Brotli integrity checks if needed, or expose as a checksum option).

---

## Phase 1: Infrastructure & Checksums

### Step 1.1 — XXH64 Checksum
**Files to create:**
- `checksum/xxh64.mbt` — XXH64 hash implementing `Hasher` trait
  - Constants: `XXH_PRIME64_1..5`
  - `Xxh64` struct with 4 accumulators + buffer for streaming
  - `Xxh64::new(seed~ : UInt64 = 0)`, `update()`, `checksum()`, `reset()`
  - Convenience: `pub fn xxh64(data : BytesView, seed~ : UInt64 = 0) -> UInt64`
- `checksum/xxh64_test.mbt` — Test against known vectors from the xxHash specification

**Files to modify:**
- `checksum/moon.pkg` — No new imports needed (pure MoonBit)

### Step 1.2 — Add `moonbitlang/x/crypto` dependency
**Files to modify:**
- `moon.mod.json` — Add `"moonbitlang/x/crypto": "<version>"` to deps

---

## Phase 2: Snappy (simplest codec — no framing, no checksums)

Snappy is the simplest to implement: pure LZ77 with a fixed encoding scheme, no Huffman, no checksums in the raw format.

### Step 2.1 — Core Types
**File:** `snappy/types.mbt`
- `pub(all) suberror SnappyError { CorruptInput(String); UnexpectedEOF } derive(Show)`
- `pub(all) enum Encode { Ok; Data(Bytes); End; Error(SnappyError) } derive(Show)`
- `pub(all) enum Decode { Await; Data(Bytes); End; Error(SnappyError) } derive(Show)`
- Constants: max block size (65536), tag types (literal=0, copy1=1, copy2=2, copy4=3)

### Step 2.2 — Compression
**File:** `snappy/compress.mbt`
- `pub fn compress(data : Bytes) -> Bytes raise SnappyError`
- Varint-encoded uncompressed length header
- Hash table for match finding (4-byte minimum match)
- Emit literal / copy tags per Snappy encoding spec

### Step 2.3 — Decompression
**File:** `snappy/decompress.mbt`
- `pub fn decompress(data : Bytes) -> Bytes raise SnappyError`
- Parse varint length, allocate output
- Decode literal/copy tags, validate bounds

### Step 2.4 — Streaming Deflater/Inflater
**Files:** `snappy/deflater.mbt`, `snappy/inflater.mbt`
- `Deflater::new()`, `Deflater::encode(BytesView?) -> Encode`
- `Inflater::new()`, `Inflater::src(BytesView)`, `Inflater::decode() -> Decode`
- Follow bzip2 pattern with private `Encoder`/`Decoder` structs

### Step 2.5 — Package Config
**File:** `snappy/moon.pkg`
```
import {
  "bikallem/compress/internal/blit",
  "bikallem/compress/internal/output_sink",
}
```

### Step 2.6 — Tests
**File:** `snappy/snappy_test.mbt`
- Decompress known vectors (hex-encoded Snappy compressed data)
- Invalid input / truncated data error tests
- Invalid varint, bad copy offset, etc.

**File:** `snappy/round_trip_test.mbt`
- Small data (1 byte, "Hello", "quick brown fox")
- 1KB, 10KB, 100KB round-trips
- All zeros, all 0xFF, all byte values
- Large repetitive data
- Signal protocol: chunked input streaming test

---

## Phase 3: LZ4 (LZ4 block + LZ4 frame format)

### Step 3.1 — Core Types
**File:** `lz4/types.mbt`
- `pub(all) suberror Lz4Error { InvalidHeader(String); CorruptData(String); ChecksumMismatch(expected~ : UInt, got~ : UInt); ContentSizeMismatch; UnexpectedEOF } derive(Show)`
- `pub(all) enum Encode { Ok; Data(Bytes); End; Error(Lz4Error) } derive(Show)`
- `pub(all) enum Decode { Await; Data(Bytes); End; Error(Lz4Error) } derive(Show)`
- Constants: LZ4 frame magic `0x184D2204`, block max sizes, min match length (4)

### Step 3.2 — LZ4 Block Compression
**File:** `lz4/block.mbt`
- `fn block_compress(src : BytesView, dst : FixedArray[Byte]) -> Int`
- Hash table (4-byte entries), greedy match finder
- LZ4 sequence encoding: token byte (literal_len:4 | match_len:4), optional length extensions, literals, offset (2 LE bytes)

### Step 3.3 — LZ4 Block Decompression
**File:** `lz4/block_decompress.mbt`
- `fn block_decompress(src : BytesView, dst : FixedArray[Byte], dst_capacity : Int) -> Int raise Lz4Error`
- Decode token, literals, match offset + length, copy with overlap handling

### Step 3.4 — LZ4 Frame Format (LZ4F)
**File:** `lz4/frame.mbt`
- Frame header: magic, FLG byte (version, block independence, content checksum, content size), BD byte (max block size), optional content size, header checksum (XXH32 of header >> 8 & 0xFF)
- Frame footer: end mark (0x00000000), optional content checksum (XXH32)

Note: LZ4 frames use XXH32 (not XXH64). We'll add XXH32 to the checksum module as well.

### Step 3.5 — One-Shot API
**Files:** `lz4/compress.mbt`, `lz4/decompress.mbt`
- `pub fn compress(data : Bytes) -> Bytes raise Lz4Error` — wraps in LZ4 frame
- `pub fn decompress(data : Bytes) -> Bytes raise Lz4Error` — expects LZ4 frame

### Step 3.6 — Streaming
**Files:** `lz4/deflater.mbt`, `lz4/inflater.mbt`
- Block-at-a-time streaming within frames
- Deflater buffers up to block_max_size, compresses block, emits frame header on first encode

### Step 3.7 — XXH32 Checksum (needed for LZ4 frames)
**File:** `checksum/xxh32.mbt`
- `Xxh32` struct implementing `Hasher` trait
- Convenience: `pub fn xxh32(data : BytesView, seed~ : UInt = 0) -> UInt`

**File:** `checksum/xxh32_test.mbt`

### Step 3.8 — Package Config
**File:** `lz4/moon.pkg`
```
import {
  "bikallem/compress/checksum",
  "bikallem/compress/internal/blit",
  "bikallem/compress/internal/output_sink",
}
```

### Step 3.9 — Tests
**File:** `lz4/lz4_test.mbt`
- Known vector decompression tests
- Invalid frame header, bad block size, checksum mismatch tests
- Truncated data tests

**File:** `lz4/round_trip_test.mbt`
- Same pattern as bzip2: small data, 1KB/10KB/100KB, all zeros, repetitive, binary, streaming chunked

---

## Phase 4: Zstandard (most complex)

### Step 4.1 — Core Types
**File:** `zstd/types.mbt`
- `pub(all) suberror ZstdError { InvalidHeader(String); CorruptData(String); ChecksumMismatch(expected~ : UInt, got~ : UInt); WindowTooLarge(UInt64); DictionaryMismatch; UnexpectedEOF } derive(Show)`
- `pub(all) enum Encode { Ok; Data(Bytes); End; Error(ZstdError) } derive(Show)`
- `pub(all) enum Decode { Await; Data(Bytes); End; Error(ZstdError) } derive(Show)`
- `pub(all) enum CompressionLevel { Fast; Level(Int); Default; Best } derive(Eq, Show)`
- Frame magic: `0xFD2FB528`

### Step 4.2 — Zstd Frame Format
**File:** `zstd/frame.mbt`
- Frame header: magic, frame header descriptor (FHD), window descriptor, optional dict ID, optional frame content size
- Block header: 3 bytes (last_block:1, block_type:2, block_size:21)
- Block types: Raw, RLE, Compressed, Reserved
- Frame checksum: lower 32 bits of XXH64 of original content

### Step 4.3 — FSE (Finite State Entropy) Tables
**File:** `zstd/fse.mbt`
- Predefined and custom FSE tables for literal lengths, match lengths, and offsets
- `FseTable` struct: symbol, num_bits, new_state arrays
- Table decoding from normalized distribution
- Predefined default tables per RFC 8878 section 3.1.1

### Step 4.4 — Huffman Coding (for literals)
**File:** `zstd/huffman.mbt`
- Huffman table for literal decompression
- Weight-based tree reconstruction
- 1-stream and 4-stream decompression modes

### Step 4.5 — Sequences Decoding
**File:** `zstd/sequences.mbt`
- Sequence: (literal_length, match_length, offset)
- Three interleaved FSE streams
- Offset codes with repeated offset handling (offsets 1, 2, 3)

### Step 4.6 — Decompression (priority — most useful direction)
**File:** `zstd/decompress.mbt`
- `pub fn decompress(data : Bytes) -> Bytes raise ZstdError`
- Frame parsing → block parsing → literal/sequence decoding → output

**File:** `zstd/inflater.mbt`
- Full streaming decompressor with phase-based state machine
- Phases: FrameHeader, BlockHeader, RawBlock, RleBlock, CompressedBlock, LiteralsHeader, HuffmanTree, LiteralsStream, SequencesHeader, SequenceExecution, ChecksumValidation, Done

### Step 4.7 — Compression
**File:** `zstd/compress.mbt`
- `pub fn compress(data : Bytes, level? : CompressionLevel = Default) -> Bytes raise ZstdError`
- Level-based strategy selection:
  - Fast: greedy matching, smaller hash table
  - Default (level 3): lazy matching similar to DEFLATE
  - Best: optimal parsing with price evaluation

**File:** `zstd/deflater.mbt`
- Streaming encoder: buffer blocks, emit frame header, compress blocks, emit checksum

### Step 4.8 — Match Finder
**File:** `zstd/match_finder.mbt`
- Hash table + hash chain for match finding
- Configurable depth based on compression level

### Step 4.9 — Encoder Tables
**File:** `zstd/encode_tables.mbt`
- Predefined FSE encoding tables
- Sequence encoding helpers
- Bit packing utilities

### Step 4.10 — Bit I/O
**File:** `zstd/bitbuf.mbt`
- Bit-level reader (LSB-first for FSE, MSB-first for Huffman — zstd uses both)
- Backward bit stream reader (zstd sequences use backward bit streams)

### Step 4.11 — Package Config
**File:** `zstd/moon.pkg`
```
import {
  "bikallem/compress/checksum",
  "bikallem/compress/internal/blit",
  "bikallem/compress/internal/output_sink",
}
```

### Step 4.12 — Tests
**File:** `zstd/zstd_test.mbt`
- Known vector decompression (zstd CLI-generated test vectors)
- Invalid magic, bad frame header, corrupt block tests
- Window size validation tests

**File:** `zstd/round_trip_test.mbt`
- Small data, 1KB/10KB/100KB round-trips
- All compression levels
- All zeros, repetitive, binary data
- Streaming chunked input

---

## Phase 5: Brotli (RFC 7932)

### Step 5.1 — Core Types
**File:** `brotli/types.mbt`
- `pub(all) suberror BrotliError { InvalidHeader(String); CorruptData(String); InvalidDistance(String); WindowTooLarge; UnexpectedEOF } derive(Show)`
- `pub(all) enum Encode { Ok; Data(Bytes); End; Error(BrotliError) } derive(Show)`
- `pub(all) enum Decode { Await; Data(Bytes); End; Error(BrotliError) } derive(Show)`
- `pub(all) enum CompressionLevel { Level(Int); Default; Best } derive(Eq, Show)` — levels 0-11
- Window size: configurable WBITS (10-24)

### Step 5.2 — Static Dictionary
**File:** `brotli/dictionary.mbt`
- Built-in 122KB static dictionary (RFC 7932 Appendix A)
- Stored as a const byte array
- Dictionary word lookup by length and index
- Transform functions (identity, uppercase first, uppercase all, omit first N, etc.)

### Step 5.3 — Huffman / Prefix Codes
**File:** `brotli/prefix_codes.mbt`
- Simple prefix codes (fixed trees for small alphabets)
- Complex prefix codes (Huffman with code lengths)
- Context-dependent literal coding (context modes: LSB6, MSB6, UTF8, Signed)

### Step 5.4 — Block Types and Context
**File:** `brotli/context.mbt`
- Block type switching for literals, insert&copy lengths, and distances
- Context maps: map (block_type, context) → Huffman tree index
- Block count decoding

### Step 5.5 — Distance Codes
**File:** `brotli/distance.mbt`
- Direct distances and distance short codes
- Configurable NPOSTFIX and NDIRECT parameters
- Ring buffer of recent distances (4 entries)

### Step 5.6 — Decompression
**File:** `brotli/decompress.mbt`
- `pub fn decompress(data : Bytes) -> Bytes raise BrotliError`
- Meta-block parsing → command decoding → literal/distance insertion

**File:** `brotli/inflater.mbt`
- Streaming decompressor with phases:
  StreamHeader, MetaBlockHeader, UncompressedBlock, HuffmanTrees, ContextMaps, CommandDecode, LiteralInsert, DistanceDecode, DictionaryLookup, Done

### Step 5.7 — Compression
**File:** `brotli/compress.mbt`
- `pub fn compress(data : Bytes, level? : CompressionLevel = Default) -> Bytes raise BrotliError`
- Levels 0-1: no Huffman, fast LZ77
- Levels 2-4: greedy matching + static Huffman
- Levels 5-9: lazy matching + dynamic Huffman + static dictionary references
- Levels 10-11: optimal parsing + full dictionary utilization

**File:** `brotli/deflater.mbt`
- Streaming encoder

### Step 5.8 — Encoder Internals
**File:** `brotli/match_finder.mbt`
- Hash table for LZ77 matching
- Optional hash chains for higher levels
- Static dictionary matching at higher levels

**File:** `brotli/encode_tables.mbt`
- Insert&copy length code tables
- Distance code encoding
- Context mode selection heuristics

### Step 5.9 — Bit I/O
**File:** `brotli/bitbuf.mbt`
- LSB-first bit reader/writer (Brotli is consistently LSB)

### Step 5.10 — Package Config
**File:** `brotli/moon.pkg`
```
import {
  "bikallem/compress/internal/blit",
  "bikallem/compress/internal/output_sink",
}
```

### Step 5.11 — Tests
**File:** `brotli/brotli_test.mbt`
- Known vector decompression (brotli CLI-generated test vectors)
- Static dictionary word tests
- Transform function tests
- Error handling tests

**File:** `brotli/round_trip_test.mbt`
- Small data, 1KB/10KB/100KB round-trips
- All compression levels (0-11)
- Text data (exercises static dictionary)
- Binary/random data
- Streaming chunked input

---

## Phase 6: Benchmarks

### Step 6.1 — Update `tools/gen_benchmarks.py`
Add four new codec entries to the `CODECS` dict:

**`snappy_benches()`** — compress/decompress at all 6 size tiers (1KB–100MB)
**`lz4_benches()`** — compress/decompress at all 6 size tiers
**`zstd_benches()`** — compress/decompress at all 6 size tiers, plus extras:
  - 10KB: best_speed, best_compression, zeros, random
**`brotli_benches()`** — compress/decompress at all 6 size tiers, plus extras:
  - 10KB: level 1 (fast), level 11 (best), text data (exercises dictionary)

### Step 6.2 — Run `python3 tools/gen_benchmarks.py`
Generates 24 new benchmark packages (4 codecs × 6 sizes) under `benchmarks/`.

### Step 6.3 — Update `tools/bench.sh`
The gen_benchmarks.py script auto-updates the `BENCH_PKGS` array — verify it includes all new packages.

### Step 6.4 — Go Comparison Benchmarks
**File to modify:** `tools/bench_test.go`
Add Go benchmark functions for cross-language comparison:
- **Snappy**: Use `github.com/golang/snappy` package
- **LZ4**: Use `github.com/pierrec/lz4/v4` package
- **Zstd**: Use `github.com/klauspost/compress/zstd` package
- **Brotli**: Use `github.com/andybalholm/brotli` package

Each with compress/decompress at sizes 1KB–100MB, matching MoonBit benchmark names.

**File to modify:** `tools/go.mod` / `tools/go.sum` — Add Go dependencies.

---

## Phase 7: Parity Tests

### Step 7.1 — Go Golden File Generator
**File to modify:** `tools/generate_golden/main.go`
Add golden file generation for:
- **Snappy**: `snappyCompress(data)` using `github.com/golang/snappy`
- **LZ4**: `lz4Compress(data)` using `github.com/pierrec/lz4/v4` (frame format)
- **Zstd**: `zstdCompress(data, level)` using `github.com/klauspost/compress/zstd` — levels 1, 3, 9
- **Brotli**: `brotliCompress(data, level)` using `github.com/andybalholm/brotli` — levels 1, 6, 11

Each generates golden files for all 5 standard inputs (empty, hello, repeated, zeros_10k, mixed_1k).

### Step 7.2 — MoonBit Golden File Generator
**File to modify:** `tools/generate_moonbit_golden/main.mbt`
Add MoonBit-side golden file generation for snappy, lz4, zstd, brotli matching the Go inputs.

**File to modify:** `tools/generate_moonbit_golden/moon.pkg`
Add imports for the four new codec packages.

### Step 7.3 — Parity Test Runner
**File to modify:** `tools/parity_test.go`
Update `TestGoDecompressMoonBit` switch:
```go
case "snappy": // snappy.Decode(nil, compressed)
case "lz4":    // lz4.NewReader + ReadAll
case "zstd":   // zstd.NewReader + ReadAll
case "brotli": // brotli.NewReader + ReadAll
```

Update `goDecompress` and `goDecompressSafe` with same cases.
Update `TestBitIdenticalOutput` — add appropriate skip logic (similar to bzip2 if Go/MoonBit use different internal strategies).

---

## Phase 8: Project Metadata & Integration

### Step 8.1 — Update `moon.mod.json`
```json
{
  "keywords": [..., "zstd", "zstandard", "snappy", "lz4", "brotli"],
  "description": "Compression library for MoonBit: flate, gzip, zlib, lzw, bzip2, zstd, snappy, lz4, brotli",
  "deps": {
    "moonbitlang/async": "0.16.7",
    "moonbitlang/x/crypto": "<version>"
  }
}
```

### Step 8.2 — Examples
Create example programs following the existing pattern:
- `examples/snappy/main.mbt` + `examples/snappy/moon.pkg`
- `examples/lz4/main.mbt` + `examples/lz4/moon.pkg`
- `examples/zstd/main.mbt` + `examples/zstd/moon.pkg`
- `examples/brotli/main.mbt` + `examples/brotli/moon.pkg`

Each demonstrates: one-shot compress/decompress, streaming API, error handling.

### Step 8.3 — Async Wrappers (if applicable)
Following the gzip_async/lzw_async pattern:
- `snappy/async/`, `lz4/async/`, `zstd/async/`, `brotli/async/`
- Only if the existing async pattern is widely used; can be deferred.

### Step 8.4 — Update README.md
- Add new codecs to the feature table
- Add API examples for each new codec
- Add benchmark results (after running benchmarks)

---

## Implementation Order & Dependencies

```
Phase 1: Checksums (XXH32, XXH64)     ← no dependencies, unblocks LZ4 + Zstd
    │
    ├── Phase 2: Snappy                ← simplest, good warm-up
    │
    ├── Phase 3: LZ4                   ← needs XXH32 from Phase 1
    │
    ├── Phase 4: Zstd                  ← needs XXH64 from Phase 1, most complex
    │
    └── Phase 5: Brotli                ← independent, complex (static dictionary)

Phase 6: Benchmarks                    ← after all codecs pass tests
Phase 7: Parity Tests                  ← after all codecs pass tests
Phase 8: Integration                   ← final polish
```

Phases 2-5 can be partially parallelized since they're independent codecs.

---

## File Summary

### New files (~55 files):
| Directory | Files | Description |
|-----------|-------|-------------|
| `checksum/` | 4 | xxh32.mbt, xxh32_test.mbt, xxh64.mbt, xxh64_test.mbt |
| `snappy/` | 7 | types, compress, decompress, deflater, inflater, moon.pkg, tests |
| `lz4/` | 10 | types, block, block_decompress, frame, compress, decompress, deflater, inflater, moon.pkg, tests |
| `zstd/` | 14 | types, frame, fse, huffman, sequences, bitbuf, match_finder, encode_tables, compress, decompress, deflater, inflater, moon.pkg, tests |
| `brotli/` | 14 | types, dictionary, prefix_codes, context, distance, bitbuf, match_finder, encode_tables, compress, decompress, deflater, inflater, moon.pkg, tests |
| `examples/` | 8 | 4 codecs × (main.mbt + moon.pkg) |
| `benchmarks/` | ~24 dirs | Auto-generated by gen_benchmarks.py |

### Modified files (~8 files):
- `moon.mod.json` — deps + keywords
- `tools/gen_benchmarks.py` — 4 new codec benchmark definitions
- `tools/bench_test.go` — Go comparison benchmarks
- `tools/generate_golden/main.go` — Golden file generation
- `tools/generate_moonbit_golden/main.mbt` — MoonBit golden generation
- `tools/generate_moonbit_golden/moon.pkg` — New imports
- `tools/parity_test.go` — Parity test cases
- `README.md` — Documentation
