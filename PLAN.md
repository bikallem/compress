# Go `compress` -> MoonBit: Final Comprehensive Plan

## Executive Summary

Port Go's `compress` package (5 sub-packages, ~5,600 LOC source, ~5,100 LOC tests) to idiomatic MoonBit as a three-layer library. Each compression algorithm is split into three independent packages:

- **Layer 1** — Pure algorithms. `fn(Bytes) -> Bytes`. No dependencies beyond `moonbitlang/core`. WASM-safe.
- **Layer 2** — Async streams. `@io.Reader`/`@io.Writer` over `moonbitlang/async`. Files, sockets, pipes.
- **Layer 3** — Sync streaming. `Compressor::update(Bytes) -> Bytes` / `finish() -> Bytes`. No async runtime. Chunked processing without I/O coupling.

All three layers share the same internal state machines. Users pick the package that fits their use case.

---

## 1. Go Source Inventory

| Package | Source LOC | Test LOC | Files | Compress | Decompress | Internal Deps |
|---------|-----------|----------|-------|----------|------------|---------------|
| `flate` | 3,205 | 2,641 | 7+8 | yes | yes | none |
| `bzip2` | 869 | 250 | 4+1 | no | yes | none |
| `lzw` | 583 | 551 | 2+2 | yes | yes | none |
| `gzip` | 540 | 1,256 | 2+5 | yes | yes | flate, hash/crc32 |
| `zlib` | 374 | 447 | 2+3 | yes | yes | flate, hash/adler32 |
| **Total** | **5,571** | **5,145** | **17+19** | | | |

External Go stdlib deps: `io`, `bufio`, `encoding/binary`, `hash/crc32`, `hash/adler32`, `math`, `math/bits`, `sort`, `sync`, `time`, `errors`, `fmt`.

---

## 2. MoonBit Ecosystem Mapping

### Use from moonbitlang/core
| Need | Package | API |
|------|---------|-----|
| Byte buffer accumulation | `@buffer.Buffer` | `write_byte`, `write_bytes`, `write_uint_le/be`, `to_bytes` |
| Byte slicing | `BytesView` | Zero-copy views into `Bytes` |
| Immutable arrays | `ReadOnlyArray[T]` | Precomputed lookup tables (CRC, Huffman fixed codes) |
| Mutable fixed arrays | `FixedArray[T]` | Sliding windows, hash chains, circular buffers |
| Sorting | `Array::sort` | Huffman frequency sorting |
| Bit patterns in match | `BytesView` patterns | `u1`, `u4`, `u8`, `u16le`, `u32le` extractors |
| Benchmarking | `@bench.Bench` | `bench(name, fn, count?)`, `dump_summaries()`, `keep()` |

### Use from moonbitlang/async (Layer 2 only)
| Need | Package | API |
|------|---------|-----|
| Reader trait | `@io.Reader` | `async read()`, `read_exactly()`, `read_some()`, `read_all()` |
| Writer trait | `@io.Writer` | `async write_once()`, `write()` |
| In-memory pipe | `@io.pipe()` | `(PipeRead, PipeWrite)` |
| File I/O | `@fs` | `open()`, `create()`, `read_file()` |
| Task groups | `@async` | `with_task_group()`, `with_timeout()` |

### Use from moonbitlang/x
| Need | Package | Notes |
|------|---------|-------|
| `CryptoHasher` trait | `@crypto` | Structural alignment for our `Hasher` trait |

### Must implement (not in any moonbitlang package)
| Need | Why | Est. LOC |
|------|-----|----------|
| CRC-32 (IEEE) | gzip checksum | ~80 |
| Adler-32 | zlib checksum | ~40 |
| Bit reader/writer | All packages need bit-level I/O | ~150 |

---

## 3. Three-Layer Package Architecture

### Package Layout

```
compress-claude/
  moon.mod.json                          # module: "blem/compress"
  lib/
    checksum/                            # Pure — no deps
      moon.pkg.json
      hasher.mbt                         # Hasher trait
      crc32.mbt                          # CRC-32 IEEE
      adler32.mbt                        # Adler-32
      *_test.mbt

    internal/                            # Pure — shared internals
      moon.pkg.json
      bit_reader.mbt                     # Read N bits from BytesView
      bit_writer.mbt                     # Write N bits to Buffer

    flate/                               # Layer 1: Pure DEFLATE
      moon.pkg.json                      # deps: [checksum, internal]
      types.mbt                          # CompressionLevel, CompressError, Token (#valtype)
      huffman.mbt                        # Huffman tree build + code tables
      dict_decoder.mbt                   # 32KB sliding window
      inflate_state.mbt                  # Inflate state machine
      deflate_state.mbt                  # Deflate state machine
      deflate_fast.mbt                   # Level 1 fast path
      huffman_bit_writer.mbt             # Bit-level Huffman output
      token.mbt                          # Token value type
      compress.mbt                       # pub fn compress/decompress (Bytes -> Bytes)
      *_test.mbt
      *_bench.mbt

    flate/async/                         # Layer 2: Async streaming DEFLATE
      moon.pkg.json                      # deps: [flate], import: moonbitlang/async/io
      inflate_reader.mbt                 # InflateReader : @io.Reader
      deflate_writer.mbt                 # DeflateWriter : @io.Writer
      *_test.mbt

    flate/sync/                          # Layer 3: Sync streaming DEFLATE
      moon.pkg.json                      # deps: [flate]
      inflater.mbt                       # Inflater::update/finish
      deflater.mbt                       # Deflater::update/finish
      *_test.mbt

    gzip/                                # Layer 1: Pure gzip
      moon.pkg.json                      # deps: [flate, checksum]
      types.mbt                          # Header, errors
      gunzip.mbt                         # fn decompress(Bytes) -> (Bytes, Header)
      gzip.mbt                           # fn compress(Bytes, ...) -> Bytes
      *_test.mbt
      *_bench.mbt

    gzip/async/                          # Layer 2: Async gzip
      moon.pkg.json                      # deps: [gzip, flate/async, checksum]
      gzip_reader.mbt                    # GzipReader : @io.Reader
      gzip_writer.mbt                    # GzipWriter : @io.Writer
      *_test.mbt

    gzip/sync/                           # Layer 3: Sync gzip
      moon.pkg.json                      # deps: [gzip, flate/sync, checksum]
      compressor.mbt                     # GzipCompressor::update/finish
      decompressor.mbt                   # GzipDecompressor::update/finish
      *_test.mbt

    zlib/                                # Layer 1
      moon.pkg.json                      # deps: [flate, checksum]
      types.mbt
      reader.mbt
      writer.mbt
      *_test.mbt
      *_bench.mbt

    zlib/async/                          # Layer 2
      moon.pkg.json
      zlib_reader.mbt
      zlib_writer.mbt
      *_test.mbt

    zlib/sync/                           # Layer 3
      moon.pkg.json
      compressor.mbt
      decompressor.mbt
      *_test.mbt

    lzw/                                 # Layer 1
      moon.pkg.json                      # deps: [internal]
      types.mbt                          # BitOrder enum
      compress.mbt
      decompress.mbt
      *_test.mbt
      *_bench.mbt

    lzw/async/                           # Layer 2
      moon.pkg.json
      lzw_reader.mbt
      lzw_writer.mbt
      *_test.mbt

    lzw/sync/                            # Layer 3
      moon.pkg.json
      compressor.mbt
      decompressor.mbt
      *_test.mbt

    bzip2/                               # Layer 1 (decompress only)
      moon.pkg.json                      # deps: [internal, checksum]
      types.mbt
      huffman.mbt
      move_to_front.mbt
      decompress.mbt
      *_test.mbt
      *_bench.mbt

    bzip2/async/                         # Layer 2
      moon.pkg.json
      bzip2_reader.mbt
      *_test.mbt

    bzip2/sync/                          # Layer 3
      moon.pkg.json
      decompressor.mbt
      *_test.mbt

  bench/                                 # Benchmark suite
    moon.pkg.json                        # deps: all layer 1 packages
    flate_bench.mbt
    gzip_bench.mbt
    zlib_bench.mbt
    lzw_bench.mbt
    bzip2_bench.mbt

  testdata/                              # Shared test fixtures
    e.txt
    gettysburg.txt
    pi.txt
    golden/                              # Go-generated golden files
      manifest.json

  tools/                                 # Go tooling
    generate_golden.go
    generate_bench_data.go               # Generate benchmark corpus
    cross_validate.go
    go_bench_test.go                     # Go benchmarks for comparison
    bench_compare.sh                     # Compare MoonBit vs Go results
```

### Dependency Graph

```
                    moonbitlang/core (always)
                           │
              ┌────────────┼────────────┐
              │            │            │
          checksum      internal     @bench
          (pure)        (pure)       (core)
              │            │
    ┌─────────┼────────────┼──────────────────┐
    │         │            │                  │
  flate      lzw        bzip2              bench/
  (L1)       (L1)       (L1)           (benchmarks)
    │         │            │
    ├─── gzip (L1)         │
    ├─── zlib (L1)         │
    │                      │
    │   moonbitlang/async  │
    │         │            │
    ├─── flate/async (L2)  │
    ├─── gzip/async  (L2)  │
    ├─── zlib/async  (L2)  │
    ├─── lzw/async   (L2)  │
    └─── bzip2/async (L2)  │
                           │
         flate/sync  (L3)  │
         gzip/sync   (L3)  │
         zlib/sync   (L3)  │
         lzw/sync    (L3)  │
         bzip2/sync  (L3)  │
```

### What Each Layer Provides

**Layer 1 — Pure (e.g., `@flate`)**
```moonbit
// Bytes in, Bytes out. No streaming, no side effects.
pub fn compress(data : Bytes, level~ : CompressionLevel = DefaultCompression) -> Bytes!CompressError
pub fn decompress(data : Bytes) -> Bytes!CompressError
pub fn compress_with_dict(data : Bytes, dict : Bytes, level~ : CompressionLevel = DefaultCompression) -> Bytes!CompressError
pub fn decompress_with_dict(data : Bytes, dict : Bytes) -> Bytes!CompressError
```

**Layer 2 — Async Streams (e.g., `@flate/async`)**
```moonbit
// Abstract types — fields hidden, constructed only via factory functions
struct InflateReader { ... }
pub fn InflateReader::new(r : &@io.Reader, dict~ : Bytes? = None) -> InflateReader
pub impl @io.Reader for InflateReader

struct DeflateWriter { ... }
pub async fn DeflateWriter::new(w : &@io.Writer, level~ : CompressionLevel = DefaultCompression) -> DeflateWriter!CompressError
pub async fn DeflateWriter::flush(self : DeflateWriter) -> Unit
pub async fn DeflateWriter::close(self : DeflateWriter) -> Unit
pub impl @io.Writer for DeflateWriter
```

**Layer 3 — Sync Streaming (e.g., `@flate/sync`)**
```moonbit
// Abstract types — fields hidden, constructed only via factory functions
struct Deflater { ... }
pub fn Deflater::new(level~ : CompressionLevel = DefaultCompression) -> Deflater!CompressError
pub fn Deflater::update(self : Deflater, chunk : Bytes) -> Bytes
pub fn Deflater::finish(self : Deflater) -> Bytes

struct Inflater { ... }
pub fn Inflater::new(dict~ : Bytes? = None) -> Inflater
pub fn Inflater::update(self : Inflater, chunk : Bytes) -> Bytes!CompressError
pub fn Inflater::finish(self : Inflater) -> Bytes!CompressError
```

### Relationships Between Layers

Layer 1's `compress()` calls Layer 3's state machine internally:
```moonbit
// flate/compress.mbt — Layer 1 implemented via Layer 3's state machine
pub fn compress(data : Bytes, level~ : CompressionLevel = DefaultCompression) -> Bytes!CompressError {
  let state = DeflateState::new!(level)
  state.write(data[..])
  state.finish()
}
```

Layer 2 drives the same state machine with async I/O:
```moonbit
// flate/async/deflate_writer.mbt — Layer 2 wraps the state machine
pub async fn DeflateWriter::write(self : DeflateWriter, data : &@io.Data) -> Unit {
  let bytes = data.binary()
  self.state.write(bytes[..])
  let compressed = self.state.flush()
  if compressed.length() > 0 {
    self.downstream.write!(compressed)
  }
}
```

Layer 3 exposes the state machine directly:
```moonbit
// flate/sync/deflater.mbt — Layer 3 is the state machine with a clean API
pub fn Deflater::update(self : Deflater, chunk : Bytes) -> Bytes {
  self.state.write(chunk[..])
  self.state.flush()
}
```

The actual `DeflateState`/`InflateState` live in Layer 1's package as internal (non-pub) types. Layer 2 and Layer 3 packages depend on Layer 1 and wrap these state machines.

---

## 4. Internal State Machine Design

### 4a. Inflate State Machine (shared by all layers)

```moonbit
// In flate/ — internal, not pub
enum InflateStep {
  NeedInput              // needs more compressed bytes
  ProducedOutput(Bytes)  // has decompressed bytes ready
  Finished               // stream complete
  Error(CompressError)   // unrecoverable
}

struct InflateState {
  dict : DictDecoder              // 32KB sliding window
  mut bit_buf : UInt64            // bit accumulator
  mut bit_count : Int
  mut input : BytesView           // current input chunk
  mut input_pos : Int
  mut block_state : BlockState
  mut final_block : Bool
}

fn InflateState::new(dict : Bytes?) -> InflateState
fn InflateState::feed(self : InflateState, input : BytesView) -> Unit
fn InflateState::step(self : InflateState) -> InflateStep
```

### 4b. Deflate State Machine (shared by all layers)

```moonbit
// In flate/ — internal, not pub
struct DeflateState {
  level : CompressionLevel
  window : FixedArray[Byte]       // 32KB sliding window
  hash_chains : FixedArray[Int]   // string match hash table
  mut pending : Buffer            // compressed output accumulator
  mut bit_buf : UInt64
  mut bit_count : Int
  // ... match finder state, block boundaries
}

fn DeflateState::new(level : CompressionLevel, dict : Bytes?) -> DeflateState!CompressError
fn DeflateState::write(self : DeflateState, input : BytesView) -> Unit
fn DeflateState::flush(self : DeflateState) -> Bytes
fn DeflateState::finish(self : DeflateState) -> Bytes
```

### 4c. How Each Layer Drives the State Machine

**Layer 1** (pure `Bytes -> Bytes`):
```
1. Create state machine
2. Feed entire input: state.write(data[..])
3. Return: state.finish()
```

**Layer 2** (async streaming):
```
Read path (InflateReader):
  loop {
    match state.step() {
      NeedInput  => chunk = upstream.read_some!(); state.feed(chunk)
      ProducedOutput(bytes) => copy to caller's buffer; return n
      Finished   => return 0
      Error(e)   => raise e
    }
  }

Write path (DeflateWriter):
  1. state.write(chunk)
  2. compressed = state.flush()
  3. downstream.write!(compressed)
```

**Layer 3** (sync streaming):
```
update(chunk):
  1. state.write(chunk)
  2. return state.flush()

finish():
  1. return state.finish()
```

---

## 5. MoonBit Design Patterns

### 5a. Value Types for Tokens (`#valtype`)

Go packs type/length/offset into `uint32`. MoonBit `#valtype` avoids heap allocation:

```moonbit
// Internal value type — not pub, used only within flate package
#valtype
struct Token {
  bits : UInt  // packed: type(2) | length(8) | offset(15) | extra(7)
}

fn Token::literal(b : Byte) -> Token { ... }
fn Token::match_(length : Int, offset : Int) -> Token { ... }
fn Token::kind(self : Token) -> TokenKind { ... }
fn Token::length(self : Token) -> Int { ... }
fn Token::offset(self : Token) -> Int { ... }
```

### 5b. Bit Patterns for Header Parsing

```moonbit
fn parse_gzip_header(data : BytesView) -> Header!CompressError {
  match data {
    [ 0x1Fu8, 0x8Bu8, 0x08u8, flags, .. as rest ] => {
      let has_extra = flags.land(0x04) != 0
      let has_name = flags.land(0x08) != 0
      let has_comment = flags.land(0x10) != 0
      // ...
    }
    _ => raise CompressError::InvalidHeader("not gzip")
  }
}

fn parse_zlib_header(data : BytesView) -> ZlibHeader!CompressError {
  match data {
    [ cmf, flg, .. as rest ] => {
      let method = cmf.land(0x0F)
      let info = cmf.lsr(4)
      guard method == 8 else { raise CompressError::InvalidHeader("not deflate") }
      // ...
    }
    _ => raise CompressError::InvalidHeader("truncated")
  }
}
```

### 5c. Enums Over Constants

```moonbit
pub enum CompressionLevel {
  NoCompression       // 0
  BestSpeed           // 1
  Level(Int)          // 2-8
  BestCompression     // 9
  DefaultCompression  // -> 6
  HuffmanOnly         // -> -2
}

fn CompressionLevel::to_int(self : CompressionLevel) -> Int {
  match self {
    NoCompression => 0
    BestSpeed => 1
    Level(n) => n
    BestCompression => 9
    DefaultCompression => 6
    HuffmanOnly => -2
  }
}
```

### 5d. Error Types

```moonbit
pub type! CompressError {
  CorruptInput(String)
  InternalError(String)
  InvalidLevel(Int)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  InvalidHeader(String)
  UnexpectedEOF
}
```

### 5e. Immutable Trees, Mutable Windows

```moonbit
// Abstract, immutable: built once via factory fn, shared freely — concurrency-safe
struct HuffmanDecoder {
  min_bits : Int
  chunks : ReadOnlyArray[UInt]
  links : ReadOnlyArray[ReadOnlyArray[UInt]]
}

// Abstract, mutable: explicit mut fields, self-contained, no pub access to internals
struct DictDecoder {
  hist : FixedArray[Byte]    // 32KB circular buffer
  mut wr_pos : Int
  mut rd_pos : Int
  mut full : Bool
}
```

All structs are abstract by default (no `pub` on the struct declaration). Callers interact through factory functions and methods only — never by constructing or destructuring directly.

### 5f. Hasher Trait and Checksum Types

```moonbit
// Trait is pub — callers can use it generically
pub(open) trait Hasher {
  size(Self) -> Int
  reset(Self) -> Unit
  update(Self, BytesView) -> Unit
  checksum(Self) -> UInt
}

// Structs are abstract — callers use ::new() and trait methods only
struct CRC32 { mut crc : UInt }
pub fn CRC32::new() -> CRC32
pub impl Hasher for CRC32

struct Adler32 { mut s1 : UInt; mut s2 : UInt }
pub fn Adler32::new() -> Adler32
pub impl Hasher for Adler32
```

### 5g. Container Type Selection

```
ReadOnlyArray[T]  — fixed size, immutable contents (lookup tables, precomputed constants)
FixedArray[T]     — fixed size, mutable contents (sliding windows, hash chains, circular buffers)
Array[T]          — growable, mutable (token accumulation, output collection)
```

### 5h. No Globals — Tables as Module-Level Constants

```moonbit
let crc32_ieee_table : ReadOnlyArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc = i.to_uint()
    for _ in 0..<8 {
      if crc.land(1U) == 1U {
        crc = crc.lsr(1).lxor(0xEDB88320U)
      } else {
        crc = crc.lsr(1)
      }
    }
    t[i] = crc
  }
  t.as_readonly()
}
```

---

## 6. Concurrency Safety

Every public type and function is concurrency-safe by construction:

- **No global mutable state.** Lookup tables are module-level `let` — immutable after init.
- **Single-owner state machines.** Each `Deflater`/`Inflater`/`Reader`/`Writer` owns its state. No shared references.
- **No locks needed.** Concurrency is at the stream level (different tasks, different compressors), not within a single compressor.
- **Layer 2 uses structured concurrency.** `with_task_group` for parallel streams, automatic cancellation.

```moonbit
// SAFE: Each task owns its compressor
@async.with_task_group!(async fn(g) {
  for path in files {
    g.spawn(async fn() {
      let infile = @fs.open!(path, mode=ReadOnly)
      let outfile = @fs.create!(path + ".gz", permission=0o644)
      let gz = @gzip_async.GzipWriter::new!(outfile)
      gz.write_reader!(infile)
      gz.close!()
    })
  }
})
```

---

## 7. Porting Phases

### Phase 1: Foundations (no inter-package deps)

**1a. checksum** (~120 LOC)
- CRC-32 IEEE: table-driven, `fn crc32(BytesView) -> UInt`
- Adler-32: two sums mod 65521, `fn adler32(BytesView) -> UInt`
- `Hasher` trait + `CRC32`/`Adler32` structs
- Port test vectors from Go `hash/crc32` and `hash/adler32`

**1b. internal** (~150 LOC)
- `BitReader`: read N bits from `BytesView`, track position
- `BitWriter`: write N bits to `Buffer`, flush to bytes

**1c. lzw** (~500 LOC)
- Layer 1: `fn compress/decompress(Bytes, BitOrder, lit_width) -> Bytes`
- Internal: `LzwCompressState` / `LzwDecompressState`
- Port `reader_test.go` (313 lines), `writer_test.go` (238 lines)

**1d. lzw/async** (~150 LOC)
- `LzwReader : @io.Reader`, `LzwWriter : @io.Writer`

**1e. lzw/sync** (~100 LOC)
- `LzwCompressor::update/finish`, `LzwDecompressor::update/finish`

**1f. bzip2** (~600 LOC, decompress only)
- Layer 1: `fn decompress(Bytes) -> Bytes`
- Internal: Huffman, MTF, inverse BWT, `Bzip2DecompressState`
- Port `bzip2_test.go` (250 lines)

**1g. bzip2/async + bzip2/sync** (~150 LOC)
- `Bzip2Reader : @io.Reader`
- `Bzip2Decompressor::update/finish`

### Phase 2: Core Engine — flate

**2a. Types + constants** (~100 LOC)
- `CompressionLevel` enum, `CompressError` type, `Token` valtype
- Constants: max match (258), min match (3), max distance (32768)

**2b. Huffman coding** (~300 LOC)
- Tree construction from frequencies
- Fixed Huffman tables (RFC 1951)
- `HuffmanEncoder` / `HuffmanDecoder`
- Port `testdata/huffman-*.in` golden tests

**2c. Dict decoder** (~180 LOC)
- 32KB circular buffer (`FixedArray[Byte]`)
- `write_byte`, `write_slice`, `write_copy`, `read_flush`
- Port `dict_decoder_test.go` (139 lines)

**2d. Inflate state machine** (~600 LOC)
- `InflateState`: block parsing, Huffman decoding, dict writes
- Layer 1: `fn decompress(Bytes) -> Bytes`
- Port `inflate_test.go`

**2e. Huffman bit writer** (~500 LOC)
- Stored, fixed, dynamic block emission
- Port `huffman_bit_writer_test.go` golden comparisons

**2f. Deflate state machine** (~800 LOC)
- Hash chains (levels 2-9), fast path (level 1), lazy matching (levels 4-9)
- `DeflateState`: `write()`, `flush()`, `finish()`
- Layer 1: `fn compress(Bytes, level~) -> Bytes`
- Port `deflate_test.go` (1,070 lines)

**2g. flate/async** (~200 LOC)
- `InflateReader : @io.Reader`, `DeflateWriter : @io.Writer`
- Streaming round-trip tests

**2h. flate/sync** (~150 LOC)
- `Inflater::update/finish`, `Deflater::update/finish`
- Chunked round-trip tests

### Phase 3: Format Wrappers

**3a. zlib** (~300 LOC Layer 1 + ~200 LOC async + ~150 LOC sync)
- Header: 2-byte CMF+FLG, optional 4-byte dict checksum
- Footer: 4-byte Adler-32
- Bit pattern header parsing
- Port `reader_test.go` (186 lines), `writer_test.go` (224 lines)

**3b. gzip** (~400 LOC Layer 1 + ~250 LOC async + ~200 LOC sync)
- Header: 10-byte fixed + optional extra/name/comment
- Footer: 4-byte CRC-32 + 4-byte size (mod 2^32)
- `Header` struct with name, comment, extra, mod_time, os
- Bit pattern header parsing
- Port `gunzip_test.go` (587 lines), `gzip_test.go` (280 lines)

### Phase 4: Benchmarks
- See Section 9 below

---

## 8. Parity Comparison Mechanism

### 8a. Golden File Generation

`tools/generate_golden.go` — Go program that:
1. Reads each `testdata/*.txt` input
2. Compresses with every algorithm at every supported level
3. Writes `testdata/golden/<algo>_<level>_<input>.compressed`
4. Writes `testdata/golden/manifest.json`:

```json
{
  "generated_at": "2026-03-07T...",
  "go_version": "go1.24",
  "entries": [
    {
      "algorithm": "flate",
      "level": 6,
      "input": "gettysburg.txt",
      "input_size": 1514,
      "input_crc32": "0xA1B2C3D4",
      "compressed_file": "flate_6_gettysburg.compressed",
      "compressed_size": 987,
      "compressed_crc32": "0xE5F6A7B8"
    }
  ]
}
```

### 8b. Test Matrix

| ID | Test | Direction | Validates | Runner |
|----|------|-----------|-----------|--------|
| T1 | Go->MoonBit decompress | Golden files -> MoonBit decompress -> compare to original | Decompressor correctness | `moon test` |
| T2 | MoonBit round-trip | MoonBit compress -> decompress = identity | Internal consistency | `moon test` |
| T3 | MoonBit->Go decompress | MoonBit compress -> Go decompress -> compare to original | Standards compliance | `go test ./tools/` |
| T4 | Error cases | Truncated/corrupt data -> proper CompressError | Error handling | `moon test` |
| T5 | Edge cases | Empty, 1-byte, 32KB boundary, all-zeros, all-0xFF, random | Boundary conditions | `moon test` |
| T6 | Stream cancel | Cancel async task mid-stream, verify no hang/leak | Async robustness | `moon test` |
| T7 | Streaming chunked | Compress in 256-byte chunks, decompress, assert identity | Streaming correctness | `moon test` |
| T8 | Bit-exact (optional) | MoonBit compressed output == Go compressed output | Algorithmic equivalence | `diff` |

### 8c. Golden File Test Example

```moonbit
test "T1: flate decompress golden files" {
  let manifest = load_manifest!()
  for entry in manifest.entries {
    if entry.algorithm != "flate" { continue }
    let compressed = read_golden_file!(entry.compressed_file)
    let expected = read_testdata!(entry.input)
    let got = @flate.decompress!(compressed)
    assert_eq!(got, expected)
  }
}
```

### 8d. Streaming Round-Trip Test Example

```moonbit
test "T7: gzip streaming round-trip" {
  let (pr, pw) = @io.pipe()
  let input = read_testdata!("gettysburg.txt")

  @async.with_task_group!(async fn(g) {
    g.spawn(async fn() {
      let w = @gzip_async.GzipWriter::new!(pw)
      for chunk in input.chunks(256) {
        w.write!(chunk)
      }
      w.close!()
      pw.close()
    })
    g.spawn(async fn() {
      let r = @gzip_async.GzipReader::new!(pr)
      let output = r.read_all!()
      assert_eq!(output.binary(), input)
      r.close!()
    })
  })
}
```

### 8e. Cross-Validation Go Harness

`tools/cross_validate.go`:
- Reads MoonBit-compressed files from `testdata/moonbit_output/`
- Decompresses with Go stdlib
- Compares to original input
- Reports PASS/FAIL per file, byte offset of first difference

### 8f. CI Pipeline

```
1. moon check                              # Type check
2. moon test                               # T1, T2, T4, T5, T6, T7
3. go run tools/generate_golden.go         # Regenerate golden files
4. moon test --filter golden               # T1 re-run
5. moon run lib/export_compressed          # Export MoonBit compressed output
6. go test ./tools/ -run CrossValidate     # T3
7. moon bench --target native --release    # Benchmarks
8. go test ./tools/ -bench .               # Go benchmarks
9. bash tools/bench_compare.sh             # Compare results
```

---

## 9. Benchmarking Plan

### 9a. Goals

1. **Establish baseline performance** — measure MoonBit throughput (MB/s) for each algorithm × level
2. **Compare against Go** — same data, same algorithms, same machine
3. **Identify optimization targets** — which hotspots account for the gap
4. **Track regressions** — benchmark on every significant change
5. **Guide optimization work** — ranked list of where to spend effort

### 9b. Benchmark Corpus

`tools/generate_bench_data.go` generates standardized test data:

| Name | Size | Pattern | Purpose |
|------|------|---------|---------|
| `zeros_1mb` | 1 MB | `\x00` repeated | Best-case compression (trivial matches) |
| `random_1mb` | 1 MB | Cryptographic random | Worst-case compression (incompressible) |
| `text_100kb` | 100 KB | English text (e.txt) | Typical text workload |
| `text_1mb` | 1 MB | Repeated English text | Larger text workload |
| `binary_1mb` | 1 MB | Mixed binary (ELF-like) | Realistic binary workload |
| `json_1mb` | 1 MB | Nested JSON | Web API payload |
| `small_1kb` | 1 KB | English text | Small message latency |
| `small_100b` | 100 B | English text | Tiny message overhead |

### 9c. MoonBit Benchmarks

Using `moon bench` with `@bench.Bench`:

```moonbit
// bench/flate_bench.mbt
test "bench flate compress level 1 text_100kb" (b : @bench.T) {
  let data = read_bench_data("text_100kb")
  b.bench(name="flate_compress_l1_text100k", fn() {
    let result = @flate.compress!(data, level=BestSpeed)
    b.keep(result)
  })
}

test "bench flate compress level 6 text_100kb" (b : @bench.T) {
  let data = read_bench_data("text_100kb")
  b.bench(name="flate_compress_l6_text100k", fn() {
    let result = @flate.compress!(data, level=DefaultCompression)
    b.keep(result)
  })
}

test "bench flate decompress text_100kb" (b : @bench.T) {
  let data = read_bench_data("text_100kb")
  let compressed = @flate.compress!(data, level=DefaultCompression)
  b.bench(name="flate_decompress_text100k", fn() {
    let result = @flate.decompress!(compressed)
    b.keep(result)
  })
}

test "bench crc32 1mb" (b : @bench.T) {
  let data = read_bench_data("text_1mb")
  b.bench(name="crc32_1mb", fn() {
    let result = @checksum.crc32(data[..])
    b.keep(result)
  })
}
```

### 9d. Go Benchmarks (same corpus, same machine)

`tools/go_bench_test.go`:

```go
func BenchmarkFlateCompressL1Text100K(b *testing.B) {
    data := readBenchData("text_100kb")
    b.ResetTimer()
    b.SetBytes(int64(len(data)))
    for i := 0; i < b.N; i++ {
        var buf bytes.Buffer
        w, _ := flate.NewWriter(&buf, flate.BestSpeed)
        w.Write(data)
        w.Close()
    }
}

func BenchmarkFlateCompressL6Text100K(b *testing.B) {
    data := readBenchData("text_100kb")
    b.ResetTimer()
    b.SetBytes(int64(len(data)))
    for i := 0; i < b.N; i++ {
        var buf bytes.Buffer
        w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
        w.Write(data)
        w.Close()
    }
}

func BenchmarkFlateDecompressText100K(b *testing.B) {
    data := readBenchData("text_100kb")
    var cbuf bytes.Buffer
    w, _ := flate.NewWriter(&cbuf, flate.DefaultCompression)
    w.Write(data)
    w.Close()
    compressed := cbuf.Bytes()
    b.ResetTimer()
    b.SetBytes(int64(len(data)))
    for i := 0; i < b.N; i++ {
        r := flate.NewReader(bytes.NewReader(compressed))
        io.ReadAll(r)
        r.Close()
    }
}
```

### 9e. Benchmark Dimensions

Full matrix of what to measure:

| Dimension | Values |
|-----------|--------|
| Algorithm | flate, gzip, zlib, lzw, bzip2 |
| Operation | compress, decompress |
| Level (flate/gzip/zlib) | 1 (BestSpeed), 6 (Default), 9 (Best) |
| Data pattern | zeros, random, text, binary, json, small |
| Data size | 100B, 1KB, 100KB, 1MB |
| Target | native, wasm-gc, js |
| Component | crc32, adler32, huffman_encode, huffman_decode, dict_write_copy |

### 9f. Comparison Script

`tools/bench_compare.sh`:

```bash
#!/bin/bash
# Run both benchmark suites and produce comparison table

echo "=== MoonBit benchmarks ==="
moon bench --target native --release 2>&1 | tee /tmp/mb_bench.json

echo "=== Go benchmarks ==="
cd tools && go test -bench . -benchmem -count 5 2>&1 | tee /tmp/go_bench.txt

echo "=== Comparison ==="
# Parse and align results into table:
# | Benchmark              | Go (MB/s) | MoonBit (MB/s) | Ratio |
# |------------------------|-----------|----------------|-------|
# | flate_compress_l1_100k | 245.3     | 187.2          | 0.76x |
# | flate_compress_l6_100k | 89.1      | 67.4           | 0.76x |
# | flate_decompress_100k  | 412.7     | 389.1          | 0.94x |
# | crc32_1mb              | 4521.0    | 3890.0         | 0.86x |
```

### 9g. Component-Level Micro-Benchmarks

To identify optimization hotspots, benchmark individual components:

```moonbit
// bench/component_bench.mbt

test "bench huffman_decode 10k_symbols" (b : @bench.T) {
  let decoder = build_fixed_huffman_decoder()
  let encoded = encode_random_symbols(10000)
  b.bench(name="huffman_decode_10k", fn() {
    let result = decode_all(decoder, encoded)
    b.keep(result)
  })
}

test "bench dict_write_copy 32kb" (b : @bench.T) {
  let dict = DictDecoder::new(32768)
  // Pre-fill with data
  fill_dict(dict)
  b.bench(name="dict_write_copy_32k", fn() {
    dict.write_copy(distance=100, length=258)
    b.keep(dict)
  })
}

test "bench hash_chain_lookup" (b : @bench.T) {
  let state = DeflateState::new!(DefaultCompression)
  let data = read_bench_data("text_100kb")
  b.bench(name="hash_chain_lookup", fn() {
    state.find_match(data[..])
    b.keep(state)
  })
}
```

### 9h. Performance Optimization Workflow

```
1. Run full benchmark suite (MoonBit + Go)
2. Identify worst ratio (e.g., "flate compress L6 is 0.55x Go")
3. Run component micro-benchmarks to find hotspot
   (e.g., "hash chain lookup is 0.40x Go")
4. Profile with moon bench --target native (native target for profiling)
5. Optimize hotspot
6. Re-run benchmarks to verify improvement
7. Repeat until target ratio achieved
```

### 9i. Performance Targets

| Component | Initial Target | Stretch Target | Notes |
|-----------|---------------|----------------|-------|
| crc32 | 0.8x Go | 1.0x Go | Table-driven, should be close |
| adler32 | 0.8x Go | 1.0x Go | Simple arithmetic |
| flate decompress | 0.7x Go | 0.9x Go | Huffman decode + dict copy |
| flate compress L1 | 0.6x Go | 0.8x Go | Hash table + greedy match |
| flate compress L6 | 0.5x Go | 0.7x Go | Hash chains + lazy match |
| flate compress L9 | 0.5x Go | 0.7x Go | Exhaustive search |
| lzw | 0.7x Go | 0.9x Go | Simpler algorithm |
| bzip2 decompress | 0.6x Go | 0.8x Go | Inverse BWT is memory-intensive |

Rationale: Go has decades of optimization (SIMD CRC, assembly hot paths). Initial MoonBit port targets correctness first, then optimization. 0.7x Go average is a reasonable initial goal; MoonBit's native backend continues to improve.

### 9j. Benchmark Tracking

Store benchmark results in `bench/results/` as JSON for tracking over time:

```
bench/results/
  2026-03-10_native.json    # moon bench output
  2026-03-10_go.txt         # go test -bench output
  2026-03-15_native.json    # after optimization round
  ...
```

Plot trends with a simple script to detect regressions.

---

## 10. Estimated Scope

| Phase | Package | Layer 1 LOC | Layer 2 LOC | Layer 3 LOC | Test LOC | Milestone |
|-------|---------|-------------|-------------|-------------|----------|-----------|
| 1a | checksum | 120 | — | — | 100 | CRC-32 + Adler-32 pass Go vectors |
| 1b | internal | 150 | — | — | 80 | Bit reader/writer working |
| 1c-e | lzw | 400 | 150 | 100 | 350 | LZW round-trip + golden pass |
| 1f-g | bzip2 | 600 | 100 | 80 | 200 | All .bz2 test files decompress |
| 2a-f | flate | 2,500 | — | — | 1,500 | inflate + deflate pass golden |
| 2g | flate/async | — | 200 | — | 200 | Async streaming round-trip |
| 2h | flate/sync | — | — | 150 | 150 | Sync streaming round-trip |
| 3a | zlib (+async +sync) | 300 | 200 | 150 | 300 | zlib round-trip + golden |
| 3b | gzip (+async +sync) | 400 | 250 | 200 | 400 | gzip round-trip + golden |
| 4 | bench | — | — | — | 400 | Full benchmark suite |
| | **Total** | **~4,470** | **~900** | **~680** | **~3,680** | |

Grand total: ~9,730 LOC (source + tests + benchmarks)

---

## 11. Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| flate complexity (3,200 LOC Go) | High | Medium | Sub-phase decomposition; inflate before deflate; golden tests at each step |
| Bit manipulation correctness | High | Medium | Go test vectors + cross-validation |
| Performance gap too large | Medium | Medium | Component benchmarks identify hotspots; optimize iteratively |
| moonbitlang/async API changes | Medium | Low | Pin version in moon.mod.json; Layer 2 is thin wrapper |
| MoonBit `FixedArray` perf for 32KB window | Medium | Low | Benchmark; `Bytes` as fallback |
| bzip2 inverse BWT | Medium | Medium | Port Go's exact algorithm; validate with known .bz2 files |
| Layer package boundaries too chatty | Low | Medium | State machines are internal to Layer 1; Layers 2/3 only wrap |

---

## 12. What NOT to Port

| Go Feature | Why Skip |
|---|---|
| `sync.Pool` / object reuse | No shared mutable state; GC handles allocation |
| `Reset()` methods | Fresh instances instead |
| Fuzz tests | MoonBit doesn't have fuzz infrastructure yet |
| `encoding/binary` | Explicit byte manipulation / bit patterns |
| Example tests (`example_test.go`) | Go-specific doc format |
| Architecture-specific assembly (amd64 CRC, etc.) | MoonBit native backend handles optimization |

---

## 13. Porting Guidelines

### Encapsulation Rules

All structs are **abstract by default** — no `pub` on the struct declaration. This is mandatory for any struct that holds mutable state.

```
pub struct Foo { ... }       // WRONG — exposes fields, allows external construction
struct Foo { ... }           // CORRECT — abstract, opaque to callers
pub(all) struct Foo { ... }  // ONLY for pure data records with no invariants (e.g., gzip Header)
```

**What gets `pub`:**
- Factory functions: `pub fn Foo::new(...) -> Foo`
- Public API methods: `pub fn Foo::update(self, ...) -> ...`
- Trait implementations: `pub impl @io.Reader for Foo`
- Enums used in public APIs: `pub enum CompressionLevel { ... }`
- Error types: `pub type! CompressError { ... }`
- Traits: `pub(open) trait Hasher { ... }`
- Free functions: `pub fn compress(data : Bytes, ...) -> Bytes`

**What does NOT get `pub`:**
- Struct declarations (unless pure data record with no invariants)
- Internal helper functions
- State machine types (`InflateState`, `DeflateState`, `BlockState`)
- Internal constants and lookup tables
- Internal sub-types (`TokenKind`, `BitReader`, `BitWriter`)

**Rationale:** Callers interact through factory functions and methods only. Internal representation can change freely without breaking downstream code. Mutable state is never directly accessible.

### Do
- `ReadOnlyArray[T]` for precomputed lookup tables (CRC, Huffman fixed codes)
- `FixedArray[T]` for mutable fixed-size buffers (windows, hash chains)
- `Buffer` for dynamic output accumulation
- `BytesView` for zero-copy input slicing
- `#valtype` for tokens and small packed values
- Bit patterns in `match` for header parsing
- `enum` with pattern matching instead of integer constants
- `type!` error types with labeled fields
- Module-level `let` for lookup tables
- `@bench.Bench` with `keep()` for benchmarks
- Abstract structs with `::new()` factories — never `pub struct`

### Don't
- No `pub` on struct declarations (unless pure data record)
- No `pub` on internal/helper functions
- No global mutable state
- No I/O in Layer 1 packages
- No `moonbitlang/async` dependency in Layer 1 or Layer 3
- No reimplementing what `moonbitlang/core` provides
- No `Reset()` / pooling patterns
- No runtime reflection

---

## 14. CLI Examples

Complete usage examples for every public API across all packages and layers. Each example is a standalone `main` function.

| Section | Package | Layer | APIs Demonstrated |
|---------|---------|-------|-------------------|
| 14a | checksum | — | `crc32()`, `adler32()`, `CRC32::new/update/checksum/reset`, `Adler32::new`, `Hasher` trait |
| 14b | flate | L1 | `compress`, `decompress`, all levels, `compress_with_dict`, `decompress_with_dict`, error handling |
| 14c | flate/async | L2 | `DeflateWriter::new/write/flush/close`, `InflateReader::new/read_all/close`, file I/O, dict, concurrency |
| 14d | flate/sync | L3 | `Deflater::new/update/finish`, `Inflater::new/update/finish`, chunked processing, dict |
| 14e | gzip | L1 | `compress`, `decompress`, custom `Header`, levels, error handling |
| 14f | gzip/async | L2 | `GzipWriter::new/write/flush/close`, `GzipReader::new/read_all/header/close`, files, sockets, pipes, concurrency |
| 14g | gzip/sync | L3 | `GzipCompressor::new/update/finish`, `GzipDecompressor::new/update/finish/header` |
| 14h | zlib | L1 | `compress`, `decompress`, levels, dict, checksum error |
| 14i | zlib/async | L2 | `ZlibWriter`, `ZlibReader`, files, dict |
| 14j | zlib/sync | L3 | `ZlibCompressor`, `ZlibDecompressor`, dict |
| 14k | lzw | L1 | `compress`, `decompress`, LSB/MSB, lit widths |
| 14l | lzw/async | L2 | `LzwWriter`, `LzwReader`, files |
| 14m | lzw/sync | L3 | `LzwCompressor`, `LzwDecompressor` |
| 14n | bzip2 | L1 | `decompress`, error handling |
| 14o | bzip2/async | L2 | `Bzip2Reader`, file, socket, chunked read |
| 14p | bzip2/sync | L3 | `Bzip2Decompressor` |
| 14q | cross-layer | all | Layer composition, gzip→zlib conversion, concurrent decompress+checksum, timeout |

### 14a. checksum

```moonbit
// main.mbt — CRC-32 and Adler-32
fn main {
  let data = b"Hello, compression world!"

  // --- Convenience functions ---
  let crc = @checksum.crc32(data[..])
  println("CRC-32:  \{crc}")

  let adler = @checksum.adler32(data[..])
  println("Adler-32: \{adler}")

  // --- Stateful Hasher (for incremental hashing) ---
  let h = @checksum.CRC32::new()
  h.update(data[0..5])     // "Hello"
  h.update(data[5..])      // ", compression world!"
  let incremental_crc = h.checksum()
  println("CRC-32 (incremental): \{incremental_crc}")
  // assert: incremental_crc == crc

  // Reset and reuse
  h.reset()
  h.update(data[..])
  println("CRC-32 (after reset): \{h.checksum()}")

  // --- Hasher trait usage (generic) ---
  fn hash_with(hasher : &@checksum.Hasher, data : BytesView) -> UInt {
    hasher.reset()
    hasher.update(data)
    hasher.checksum()
  }
  let a = @checksum.Adler32::new()
  println("Adler-32 (via trait): \{hash_with(a, data[..])}")
  println("Hash output size: \{a.size()} bytes")
}
```

### 14b. flate — Layer 1 (Pure)

```moonbit
// main.mbt — DEFLATE compress/decompress (pure, Bytes -> Bytes)
fn main {
  let original = b"The quick brown fox jumps over the lazy dog. " |> repeat(100)

  // --- Compress with default level (6) ---
  let compressed = @flate.compress!(original)
  println("Original:   \{original.length()} bytes")
  println("Compressed: \{compressed.length()} bytes")

  // --- Decompress ---
  let restored = @flate.decompress!(compressed)
  assert_eq!(restored, original)
  println("Round-trip: OK")

  // --- Compress with specific levels ---
  let fast = @flate.compress!(original, level=BestSpeed)
  let best = @flate.compress!(original, level=BestCompression)
  let none = @flate.compress!(original, level=NoCompression)
  let huff = @flate.compress!(original, level=HuffmanOnly)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")
  println("NoCompression:   \{none.length()} bytes")
  println("HuffmanOnly:     \{huff.length()} bytes")

  // All decompress to the same original
  assert_eq!(@flate.decompress!(fast), original)
  assert_eq!(@flate.decompress!(best), original)
  assert_eq!(@flate.decompress!(none), original)
  assert_eq!(@flate.decompress!(huff), original)

  // --- Dictionary-based compression ---
  let dict = b"the quick brown fox lazy dog"
  let compressed_dict = @flate.compress_with_dict!(original, dict, level=DefaultCompression)
  let restored_dict = @flate.decompress_with_dict!(compressed_dict, dict)
  assert_eq!(restored_dict, original)
  println("With dict:  \{compressed_dict.length()} bytes (vs \{compressed.length()} without)")

  // --- Error handling ---
  match @flate.decompress?(b"\x00\xFF\xFE") {
    Err(CompressError::CorruptInput(msg)) => println("Expected error: \{msg}")
    Err(e) => println("Other error: \{e}")
    Ok(_) => println("Unexpected success")
  }
}
```

### 14c. flate/async — Layer 2 (Async Streams)

```moonbit
// main.mbt — DEFLATE streaming over async Reader/Writer
async fn main_async() -> Unit {
  let original = b"Streaming compression example data. " |> repeat(1000)

  // --- Compress: write through DeflateWriter to a pipe ---
  let (pr, pw) = @io.pipe()
  let compressed = {
    let w = @flate_async.DeflateWriter::new!(pw, level=DefaultCompression)
    w.write!(original)     // write data (impl @io.Writer)
    w.flush!()             // force pending output downstream
    w.close!()             // emit final block, flush
    pw.close()
    pr.read_all!().binary()
  }
  println("Compressed: \{compressed.length()} bytes")

  // --- Decompress: read through InflateReader from a pipe ---
  let (pr2, pw2) = @io.pipe()
  let restored = {
    // Feed compressed data to the pipe
    pw2.write!(compressed)
    pw2.close()
    // Read decompressed data through InflateReader
    let r = @flate_async.InflateReader::new(pr2)
    let data = r.read_all!().binary()  // impl @io.Reader
    r.close!()
    data
  }
  assert_eq!(restored, original)
  println("Round-trip: OK (\{restored.length()} bytes)")

  // --- Compress a file to another file ---
  let infile = @fs.open!("testdata/e.txt", mode=ReadOnly)
  let outfile = @fs.create!("output.deflate", permission=0o644)
  let w = @flate_async.DeflateWriter::new!(outfile, level=BestSpeed)
  w.write_reader!(infile)  // stream entire file through compressor
  w.close!()
  println("File compressed")

  // --- Decompress a file ---
  let infile2 = @fs.open!("output.deflate", mode=ReadOnly)
  let r = @flate_async.InflateReader::new(infile2)
  let content = r.read_all!().binary()
  r.close!()
  println("File decompressed: \{content.length()} bytes")

  // --- Dictionary-based streaming ---
  let dict = b"example data"
  let (pr3, pw3) = @io.pipe()
  let w2 = @flate_async.DeflateWriter::new!(pw3, level=DefaultCompression, dict=dict)
  w2.write!(original)
  w2.close!()
  pw3.close()
  let r2 = @flate_async.InflateReader::new(pr3, dict=dict)
  let restored2 = r2.read_all!().binary()
  r2.close!()
  assert_eq!(restored2, original)

  // --- Concurrent compression of multiple streams ---
  @async.with_task_group!(async fn(g) {
    let files = ["file1.txt", "file2.txt", "file3.txt"]
    for path in files {
      g.spawn(async fn() {
        let input = @fs.open!(path, mode=ReadOnly)
        let output = @fs.create!(path + ".deflate", permission=0o644)
        let w = @flate_async.DeflateWriter::new!(output, level=BestSpeed)
        w.write_reader!(input)
        w.close!()
        println("Compressed \{path}")
      })
    }
  })
}
```

### 14d. flate/sync — Layer 3 (Sync Streaming)

```moonbit
// main.mbt — DEFLATE sync chunked processing (no async runtime)
fn main {
  let original = b"Chunked compression without async. " |> repeat(1000)

  // --- Compress in chunks ---
  let deflater = @flate_sync.Deflater::new!(level=DefaultCompression)
  let chunks = original.chunks(4096)
  let compressed_parts : Array[Bytes] = []
  for chunk in chunks {
    let out = deflater.update(chunk)
    if out.length() > 0 {
      compressed_parts.push(out)
    }
  }
  let final_out = deflater.finish()
  compressed_parts.push(final_out)
  let compressed = Bytes::concat(compressed_parts)
  println("Compressed \{original.length()} -> \{compressed.length()} bytes")

  // --- Decompress in chunks ---
  let inflater = @flate_sync.Inflater::new()
  let decompressed_parts : Array[Bytes] = []
  for chunk in compressed.chunks(1024) {
    let out = inflater.update!(chunk)
    if out.length() > 0 {
      decompressed_parts.push(out)
    }
  }
  let final_decomp = inflater.finish!()
  decompressed_parts.push(final_decomp)
  let restored = Bytes::concat(decompressed_parts)
  assert_eq!(restored, original)
  println("Round-trip: OK")

  // --- Single-chunk shorthand ---
  let deflater2 = @flate_sync.Deflater::new!(level=BestSpeed)
  deflater2.update(original) |> ignore  // feed all at once
  let compressed2 = deflater2.finish()
  println("Single-chunk compressed: \{compressed2.length()} bytes")

  // --- With dictionary ---
  let dict = b"chunked compression async"
  let deflater3 = @flate_sync.Deflater::new!(level=DefaultCompression, dict=dict)
  deflater3.update(original) |> ignore
  let compressed3 = deflater3.finish()

  let inflater2 = @flate_sync.Inflater::new(dict=dict)
  inflater2.update!(compressed3) |> ignore
  let restored2 = inflater2.finish!()
  assert_eq!(restored2, original)
}
```

### 14e. gzip — Layer 1 (Pure)

```moonbit
// main.mbt — gzip compress/decompress (pure)
fn main {
  let original = b"gzip example data for compression. " |> repeat(200)

  // --- Compress with default settings ---
  let compressed = @gzip.compress!(original)
  println("gzip compressed: \{original.length()} -> \{compressed.length()} bytes")

  // --- Decompress (returns data + header) ---
  let (restored, header) = @gzip.decompress!(compressed)
  assert_eq!(restored, original)
  println("Round-trip: OK")
  println("Header OS: \{header.os}")

  // --- Compress with custom header ---
  let hdr = @gzip.Header::{
    name: "example.txt",
    comment: "compressed by blem/compress",
    extra: b"",
    mod_time: 1709856000L,  // unix timestamp
    os: 0xFFb,              // unknown
  }
  let compressed2 = @gzip.compress!(original, header=hdr, level=BestCompression)
  let (restored2, header2) = @gzip.decompress!(compressed2)
  assert_eq!(restored2, original)
  println("Name:    \{header2.name}")
  println("Comment: \{header2.comment}")

  // --- Compress with different levels ---
  let fast = @gzip.compress!(original, level=BestSpeed)
  let best = @gzip.compress!(original, level=BestCompression)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")

  // --- Error handling ---
  match @gzip.decompress?(b"\x00\x01\x02") {
    Err(CompressError::InvalidHeader(_)) => println("Expected: not gzip")
    _ => println("Unexpected result")
  }
}
```

### 14f. gzip/async — Layer 2 (Async Streams)

```moonbit
// main.mbt — gzip async streaming
async fn main_async() -> Unit {
  let original = b"Async gzip streaming example. " |> repeat(500)

  // --- Compress to file ---
  let outfile = @fs.create!("output.gz", permission=0o644)
  let hdr = @gzip.Header::{ name: "data.txt", ..@gzip.Header::default() }
  let w = @gzip_async.GzipWriter::new!(outfile, level=DefaultCompression, header=hdr)
  w.write!(original)
  w.flush!()               // force output to file
  w.close!()               // writes CRC-32 + size footer
  println("Wrote output.gz")

  // --- Decompress from file ---
  let infile = @fs.open!("output.gz", mode=ReadOnly)
  let r = @gzip_async.GzipReader::new!(infile)
  println("gzip name: \{r.header().name}")   // header available after construction
  let restored = r.read_all!().binary()
  r.close!()               // verifies CRC-32 checksum
  assert_eq!(restored, original)
  println("Decompressed: \{restored.length()} bytes")

  // --- Stream from network socket ---
  let tcp = @socket.Tcp::connect_to_host!("example.com", port=80)
  tcp.write!("GET /data.gz HTTP/1.1\r\nHost: example.com\r\n\r\n")
  // ... skip HTTP headers ...
  let gz_reader = @gzip_async.GzipReader::new!(tcp)
  let body = gz_reader.read_all!().binary()
  gz_reader.close!()
  println("Received \{body.length()} decompressed bytes")

  // --- Pipe: compress in one task, decompress in another ---
  let (pr, pw) = @io.pipe()
  @async.with_task_group!(async fn(g) {
    g.spawn(async fn() {
      let w = @gzip_async.GzipWriter::new!(pw)
      // Write in small chunks to exercise streaming
      for chunk in original.chunks(256) {
        w.write!(chunk)
      }
      w.close!()
      pw.close()
    })
    g.spawn(async fn() {
      let r = @gzip_async.GzipReader::new!(pr)
      let output = r.read_all!().binary()
      r.close!()
      assert_eq!(output, original)
      println("Pipe round-trip: OK")
    })
  })

  // --- Concurrent file compression ---
  @async.with_task_group!(async fn(g) {
    for path in ["a.txt", "b.txt", "c.txt"] {
      g.spawn(async fn() {
        let input = @fs.open!(path, mode=ReadOnly)
        let output = @fs.create!(path + ".gz", permission=0o644)
        let w = @gzip_async.GzipWriter::new!(output,
          header=@gzip.Header::{ name: path, ..@gzip.Header::default() })
        w.write_reader!(input)
        w.close!()
      })
    }
  })
  println("All files compressed concurrently")
}
```

### 14g. gzip/sync — Layer 3 (Sync Streaming)

```moonbit
// main.mbt — gzip sync chunked processing
fn main {
  let original = b"Sync gzip streaming. " |> repeat(500)

  // --- Compress in chunks ---
  let hdr = @gzip.Header::{ name: "data.txt", ..@gzip.Header::default() }
  let comp = @gzip_sync.GzipCompressor::new!(level=DefaultCompression, header=hdr)
  let parts : Array[Bytes] = []
  for chunk in original.chunks(8192) {
    let out = comp.update(chunk)
    if out.length() > 0 { parts.push(out) }
  }
  parts.push(comp.finish())  // writes CRC-32 + size footer
  let compressed = Bytes::concat(parts)
  println("Compressed: \{compressed.length()} bytes")

  // --- Decompress in chunks ---
  let decomp = @gzip_sync.GzipDecompressor::new!()
  let out_parts : Array[Bytes] = []
  for chunk in compressed.chunks(2048) {
    let out = decomp.update!(chunk)
    if out.length() > 0 { out_parts.push(out) }
  }
  out_parts.push(decomp.finish!())  // verifies CRC-32
  let restored = Bytes::concat(out_parts)
  assert_eq!(restored, original)
  println("Header name: \{decomp.header().name}")
  println("Round-trip: OK")
}
```

### 14h. zlib — Layer 1 (Pure)

```moonbit
// main.mbt — zlib compress/decompress (pure)
fn main {
  let original = b"zlib framing with Adler-32 checksum. " |> repeat(200)

  // --- Compress/decompress ---
  let compressed = @zlib.compress!(original)
  let restored = @zlib.decompress!(compressed)
  assert_eq!(restored, original)
  println("zlib: \{original.length()} -> \{compressed.length()} bytes")

  // --- With compression level ---
  let fast = @zlib.compress!(original, level=BestSpeed)
  let best = @zlib.compress!(original, level=BestCompression)
  println("BestSpeed: \{fast.length()}, BestCompression: \{best.length()}")

  // --- With preset dictionary ---
  let dict = b"zlib framing Adler checksum"
  let compressed_d = @zlib.compress_with_dict!(original, dict, level=DefaultCompression)
  let restored_d = @zlib.decompress_with_dict!(compressed_d, dict)
  assert_eq!(restored_d, original)
  println("With dict: \{compressed_d.length()} bytes")

  // --- Error: bad checksum ---
  let mut corrupt = compressed
  // flip last byte (Adler-32 footer)
  corrupt = corrupt.set(corrupt.length() - 1, 0x00)
  match @zlib.decompress?(corrupt) {
    Err(CompressError::ChecksumMismatch(expected~, got~)) =>
      println("Checksum mismatch: expected=\{expected}, got=\{got}")
    _ => println("Unexpected")
  }
}
```

### 14i. zlib/async — Layer 2 (Async Streams)

```moonbit
// main.mbt — zlib async streaming
async fn main_async() -> Unit {
  let original = b"Async zlib stream. " |> repeat(500)

  // --- Compress to file ---
  let outfile = @fs.create!("output.zlib", permission=0o644)
  let w = @zlib_async.ZlibWriter::new!(outfile, level=DefaultCompression)
  w.write!(original)
  w.flush!()
  w.close!()               // writes Adler-32 footer

  // --- Decompress from file ---
  let infile = @fs.open!("output.zlib", mode=ReadOnly)
  let r = @zlib_async.ZlibReader::new!(infile)
  let restored = r.read_all!().binary()
  r.close!()               // verifies Adler-32
  assert_eq!(restored, original)
  println("zlib file round-trip: OK")

  // --- With dictionary ---
  let dict = b"async zlib stream"
  let (pr, pw) = @io.pipe()
  let w2 = @zlib_async.ZlibWriter::new!(pw, dict=dict)
  w2.write!(original)
  w2.close!()
  pw.close()
  let r2 = @zlib_async.ZlibReader::new!(pr, dict=dict)
  let restored2 = r2.read_all!().binary()
  r2.close!()
  assert_eq!(restored2, original)
}
```

### 14j. zlib/sync — Layer 3 (Sync Streaming)

```moonbit
// main.mbt — zlib sync chunked processing
fn main {
  let original = b"Sync zlib chunked. " |> repeat(500)

  // --- Compress ---
  let comp = @zlib_sync.ZlibCompressor::new!(level=BestSpeed)
  let parts : Array[Bytes] = []
  for chunk in original.chunks(4096) {
    let out = comp.update(chunk)
    if out.length() > 0 { parts.push(out) }
  }
  parts.push(comp.finish())
  let compressed = Bytes::concat(parts)

  // --- Decompress ---
  let decomp = @zlib_sync.ZlibDecompressor::new!()
  let out_parts : Array[Bytes] = []
  for chunk in compressed.chunks(1024) {
    let out = decomp.update!(chunk)
    if out.length() > 0 { out_parts.push(out) }
  }
  out_parts.push(decomp.finish!())
  let restored = Bytes::concat(out_parts)
  assert_eq!(restored, original)
  println("zlib sync round-trip: OK")

  // --- With dictionary ---
  let dict = b"sync zlib chunked"
  let comp2 = @zlib_sync.ZlibCompressor::new!(level=DefaultCompression, dict=dict)
  comp2.update(original) |> ignore
  let compressed2 = comp2.finish()

  let decomp2 = @zlib_sync.ZlibDecompressor::new!(dict=dict)
  decomp2.update!(compressed2) |> ignore
  let restored2 = decomp2.finish!()
  assert_eq!(restored2, original)
}
```

### 14k. lzw — Layer 1 (Pure)

```moonbit
// main.mbt — LZW compress/decompress (pure)
fn main {
  let original = b"ABABABABABABABABABAB" |> repeat(50)

  // --- LSB order (GIF format) ---
  let compressed_lsb = @lzw.compress!(original, LSB, 8)
  let restored_lsb = @lzw.decompress!(compressed_lsb, LSB, 8)
  assert_eq!(restored_lsb, original)
  println("LZW LSB: \{original.length()} -> \{compressed_lsb.length()} bytes")

  // --- MSB order (TIFF/PDF format) ---
  let compressed_msb = @lzw.compress!(original, MSB, 8)
  let restored_msb = @lzw.decompress!(compressed_msb, MSB, 8)
  assert_eq!(restored_msb, original)
  println("LZW MSB: \{original.length()} -> \{compressed_msb.length()} bytes")

  // --- Different literal widths ---
  // litWidth=2 for 4-symbol alphabet
  let small = b"\x00\x01\x02\x03\x00\x01\x02\x03" |> repeat(100)
  let compressed_2 = @lzw.compress!(small, LSB, 2)
  let restored_2 = @lzw.decompress!(compressed_2, LSB, 2)
  assert_eq!(restored_2, small)
  println("LZW litWidth=2: \{small.length()} -> \{compressed_2.length()} bytes")
}
```

### 14l. lzw/async — Layer 2 (Async Streams)

```moonbit
// main.mbt — LZW async streaming
async fn main_async() -> Unit {
  let original = b"LZW async streaming data. " |> repeat(500)

  // --- Compress via LzwWriter ---
  let (pr, pw) = @io.pipe()
  let w = @lzw_async.LzwWriter::new(pw, LSB, 8)
  w.write!(original)
  w.close!()
  pw.close()

  // --- Decompress via LzwReader ---
  let r = @lzw_async.LzwReader::new(pr, LSB, 8)
  let restored = r.read_all!().binary()
  r.close!()
  assert_eq!(restored, original)
  println("LZW async round-trip: OK")

  // --- File I/O ---
  let outfile = @fs.create!("output.lzw", permission=0o644)
  let w2 = @lzw_async.LzwWriter::new(outfile, MSB, 8)
  w2.write!(original)
  w2.close!()

  let infile = @fs.open!("output.lzw", mode=ReadOnly)
  let r2 = @lzw_async.LzwReader::new(infile, MSB, 8)
  let content = r2.read_all!().binary()
  r2.close!()
  assert_eq!(content, original)
  println("LZW file round-trip: OK")
}
```

### 14m. lzw/sync — Layer 3 (Sync Streaming)

```moonbit
// main.mbt — LZW sync chunked processing
fn main {
  let original = b"LZW sync chunked data. " |> repeat(500)

  // --- Compress in chunks ---
  let comp = @lzw_sync.LzwCompressor::new(LSB, 8)
  let parts : Array[Bytes] = []
  for chunk in original.chunks(4096) {
    let out = comp.update(chunk)
    if out.length() > 0 { parts.push(out) }
  }
  parts.push(comp.finish())
  let compressed = Bytes::concat(parts)

  // --- Decompress in chunks ---
  let decomp = @lzw_sync.LzwDecompressor::new(LSB, 8)
  let out_parts : Array[Bytes] = []
  for chunk in compressed.chunks(1024) {
    let out = decomp.update!(chunk)
    if out.length() > 0 { out_parts.push(out) }
  }
  out_parts.push(decomp.finish!())
  let restored = Bytes::concat(out_parts)
  assert_eq!(restored, original)
  println("LZW sync round-trip: OK")
}
```

### 14n. bzip2 — Layer 1 (Pure, decompress only)

```moonbit
// main.mbt — bzip2 decompression (pure)
fn main {
  // bzip2 is decompress-only
  let compressed = read_file("testdata/e.txt.bz2")

  let decompressed = @bzip2.decompress!(compressed)
  println("bzip2 decompressed: \{decompressed.length()} bytes")

  // --- Error handling ---
  match @bzip2.decompress?(b"\x00\x01\x02") {
    Err(CompressError::InvalidHeader(msg)) => println("Expected error: \{msg}")
    _ => println("Unexpected")
  }

  // Verify against known plaintext
  let expected = read_file("testdata/e.txt")
  assert_eq!(decompressed, expected)
  println("Matches expected output: OK")
}
```

### 14o. bzip2/async — Layer 2 (Async Streams)

```moonbit
// main.mbt — bzip2 async streaming decompression
async fn main_async() -> Unit {
  // --- Decompress from file ---
  let infile = @fs.open!("testdata/e.txt.bz2", mode=ReadOnly)
  let r = @bzip2_async.Bzip2Reader::new!(infile)
  let decompressed = r.read_all!().binary()
  r.close!()
  println("bzip2 decompressed: \{decompressed.length()} bytes")

  // --- Decompress from network ---
  let tcp = @socket.Tcp::connect_to_host!("example.com", port=80)
  // ... send request, skip headers ...
  let r2 = @bzip2_async.Bzip2Reader::new!(tcp)
  let content = r2.read_all!().binary()
  r2.close!()
  println("Received \{content.length()} decompressed bytes")

  // --- Read in chunks (not all at once) ---
  let infile2 = @fs.open!("testdata/e.txt.bz2", mode=ReadOnly)
  let r3 = @bzip2_async.Bzip2Reader::new!(infile2)
  let buf = FixedArray::make(4096, b'\x00')
  let mut total = 0
  while true {
    let n = r3.read!(buf)
    if n == 0 { break }   // EOF
    total = total + n
    // process buf[0..n] ...
  }
  r3.close!()
  println("Read \{total} bytes in chunks")
}
```

### 14p. bzip2/sync — Layer 3 (Sync Streaming)

```moonbit
// main.mbt — bzip2 sync chunked decompression
fn main {
  let compressed = read_file("testdata/e.txt.bz2")

  // --- Decompress in chunks ---
  let decomp = @bzip2_sync.Bzip2Decompressor::new!()
  let parts : Array[Bytes] = []
  for chunk in compressed.chunks(2048) {
    let out = decomp.update!(chunk)
    if out.length() > 0 { parts.push(out) }
  }
  parts.push(decomp.finish!())
  let decompressed = Bytes::concat(parts)

  let expected = read_file("testdata/e.txt")
  assert_eq!(decompressed, expected)
  println("bzip2 sync decompression: OK (\{decompressed.length()} bytes)")
}
```

### 14q. Cross-Layer Composition

```moonbit
// main.mbt — composing layers and packages together
async fn main_async() -> Unit {
  // --- Layer 1: Quick one-shot in a test or script ---
  let data = b"Hello world"
  let gz = @gzip.compress!(data)
  let (back, _) = @gzip.decompress!(gz)
  assert_eq!(back, data)

  // --- Layer 2: Decompress gzip, recompress as zlib ---
  let infile = @fs.open!("input.gz", mode=ReadOnly)
  let outfile = @fs.create!("output.zlib", permission=0o644)
  let gz_reader = @gzip_async.GzipReader::new!(infile)
  let zlib_writer = @zlib_async.ZlibWriter::new!(outfile, level=BestSpeed)
  zlib_writer.write_reader!(gz_reader)   // stream: gzip -> zlib
  zlib_writer.close!()
  gz_reader.close!()
  println("Converted gzip -> zlib")

  // --- Layer 3: Process data from a non-async source (e.g., iterator) ---
  let deflater = @flate_sync.Deflater::new!(level=BestSpeed)
  let inflater = @flate_sync.Inflater::new()
  // Simulate reading from a blocking source
  let chunks = [b"chunk1_data", b"chunk2_data", b"chunk3_data"]
  let compressed_parts : Array[Bytes] = []
  for chunk in chunks {
    compressed_parts.push(deflater.update(chunk))
  }
  compressed_parts.push(deflater.finish())

  let decompressed_parts : Array[Bytes] = []
  for part in compressed_parts {
    if part.length() > 0 {
      decompressed_parts.push(inflater.update!(part))
    }
  }
  decompressed_parts.push(inflater.finish!())
  let result = Bytes::concat(decompressed_parts)
  assert_eq!(result, Bytes::concat(chunks))
  println("Layer 3 pipeline: OK")

  // --- Concurrent decompress + checksum ---
  @async.with_task_group!(async fn(g) {
    let (pr, pw) = @io.pipe()
    g.spawn(async fn() {
      let infile = @fs.open!("big.gz", mode=ReadOnly)
      let r = @gzip_async.GzipReader::new!(infile)
      // Forward decompressed data to pipe
      pw.write_reader!(r)
      r.close!()
      pw.close()
    })
    g.spawn(async fn() {
      // Read decompressed data, compute CRC incrementally
      let hasher = @checksum.CRC32::new()
      let buf = FixedArray::make(8192, b'\x00')
      let mut total = 0
      while true {
        let n = pr.read!(buf)
        if n == 0 { break }
        hasher.update(buf[0..n])
        total = total + n
      }
      println("Decompressed \{total} bytes, CRC-32: \{hasher.checksum()}")
    })
  })

  // --- Timeout protection ---
  match @async.with_timeout_opt!(5000, async fn() {
    let infile = @fs.open!("huge.gz", mode=ReadOnly)
    let r = @gzip_async.GzipReader::new!(infile)
    r.read_all!().binary()
  }) {
    Some(data) => println("Got \{data.length()} bytes")
    None => println("Timed out after 5s")
  }
}
```

---

## 15. Definition of Done

1. `moon check` — zero warnings
2. `moon test` — all pass (T1-T7 across all packages, all three layers)
3. `go test ./tools/` — cross-validation green (T3)
4. No global mutable state (code review verified)
5. Every Layer 2 Reader implements `@io.Reader`, every Writer implements `@io.Writer`
6. Layer 3 `Compressor::update/finish` works without async runtime
7. Layer 1 has zero dependency on `moonbitlang/async`
8. Streaming: compress/decompress 100MB+ in constant memory (Layer 2)
9. Concurrent compression via `with_task_group` works (Layer 2)
10. `moon bench` runs, results documented in `bench/results/`
11. Benchmark comparison table vs Go produced
12. Every pub function has `///|` doc comment
13. Parity matrix (Section 8b) fully green
