# Go `compress` -> MoonBit: Design with Async I/O Streams

## Overview

This design integrates `moonbitlang/async` I/O streams directly into the compression library, mirroring Go's `io.Reader`/`io.Writer`-based API while preserving MoonBit idioms. Unlike the I/O-free plan (`PLAN.md`), this design provides streaming compression/decompression over any async `Reader`/`Writer` — files, sockets, pipes, in-memory buffers — just like Go's original.

The key insight: Go's compress API is **stream-oriented by design**. Rather than fighting that by buffering everything into `Bytes`, this plan embraces streaming and maps directly onto `moonbitlang/async`'s `Reader`/`Writer` traits.

---

## 1. Architecture: Three Layers

```
Layer 3: Convenience (Bytes-in/Bytes-out)
  compress(Bytes) -> Bytes       // buffers internally, calls Layer 2
  decompress(Bytes) -> Bytes

Layer 2: Streaming (async Reader/Writer)
  CompressWriter : @io.Writer    // wraps downstream Writer, compresses on write
  DecompressReader : @io.Reader  // wraps upstream Reader, decompresses on read

Layer 1: Core Algorithms (pure, no I/O)
  Huffman trees, dict decoder, token encoding, CRC/Adler tables
  State machines that consume/produce byte chunks
```

**Layer 1** is pure and I/O-free — the algorithmic core shared by both streaming and batch APIs.

**Layer 2** is the primary API — async streaming, matching Go's design intent.

**Layer 3** is sugar — wraps Layer 2 using thin in-memory `BytesReader` / `BytesWriter` helpers under `internal/bytes` for callers who just want `Bytes -> Bytes`.

---

## 2. Mapping Go Patterns to moonbitlang/async

### 2a. Reader/Writer Traits

Go:
```go
type Reader interface { Read(p []byte) (n int, err error) }
type Writer interface { Write(p []byte) (n int, err error) }
```

moonbitlang/async (already exists):
```moonbit
pub(open) trait Reader {
  async read(Self, FixedArray[Byte], offset? : Int, max_len? : Int) -> Int
  async read_byte(Self) -> Byte raise ReaderClosed
  async read_exactly(Self, Int) -> Bytes raise ReaderClosed
  async read_some(Self, max_len? : Int) -> Bytes?
  async read_all(Self) -> &Data
}

pub(open) trait Writer {
  async write_byte(Self, Byte) -> Unit
  async write_once(Self, Bytes, offset~ : Int, len~ : Int) -> Int
  async write(Self, &Data) -> Unit
}
```

No custom traits needed. We implement `@io.Reader` and `@io.Writer` directly.

For `Bytes -> Bytes` convenience wrappers, add thin local helpers under `internal/bytes`. The vendored `moonbitlang/async/io` version in this repo provides buffered wrappers, but not built-in `BytesReader` / `BytesWriter` types.

### 2b. Go's NewReader/NewWriter Pattern

Go:
```go
r := gzip.NewReader(fileReader)
defer r.Close()
data, _ := io.ReadAll(r)
```

MoonBit:
```moonbit
let file = @fs.open!("data.gz", mode=ReadOnly)
let r = @gzip.new_reader!(file)
let data = r.read_all!()
r.close!()
```

Go:
```go
w := gzip.NewWriter(fileWriter)
w.Write(data)
w.Close()
```

MoonBit:
```moonbit
let file = @fs.create!("data.gz", permission=0o644)
let w = @gzip.new_writer(file)
w.write!(data)
w.close!()
```

### 2c. Reset Pattern -> Close + New

Go reuses compressor/decompressor state via `Reset()`. In MoonBit, create a fresh instance — no shared mutable state, no `sync.Pool`.

### 2d. Error Mapping

| Go | MoonBit |
|----|---------|
| `io.EOF` | `read_some()` returns `None` / `read_byte()` or `read_exactly()` raises `ReaderClosed` |
| `io.ErrUnexpectedEOF` | `raise CompressError::UnexpectedEOF` |
| `flate.CorruptInputError` | `raise CompressError::CorruptInput(msg)` |
| `gzip.ErrChecksum` | `raise CompressError::ChecksumMismatch(expected~, got~)` |
| `gzip.ErrHeader` | `raise CompressError::InvalidHeader(msg)` |

---

## 3. Package API Surfaces

### 3a. flate

```moonbit
// --- Streaming API (Layer 2) ---

pub struct DeflateWriter {
  priv downstream : &@io.Writer
  priv mut state : DeflateState       // internal compression state machine
  priv level : CompressionLevel
  priv dict : Bytes?
}

pub async fn DeflateWriter::new(
  w : &@io.Writer,
  level~ : CompressionLevel = DefaultCompression,
  dict~ : Bytes? = None
) -> DeflateWriter raise CompressError

pub async fn DeflateWriter::write(self : DeflateWriter, data : &@io.Data) -> Unit
pub async fn DeflateWriter::flush(self : DeflateWriter) -> Unit
pub async fn DeflateWriter::close(self : DeflateWriter) -> Unit

pub struct InflateReader {
  priv upstream : &@io.Reader
  priv mut state : InflateState       // internal decompression state machine
  priv dict : Bytes?
}

pub fn InflateReader::new(
  r : &@io.Reader,
  dict~ : Bytes? = None
) -> InflateReader

pub async fn InflateReader::read(
  self : InflateReader,
  buf : FixedArray[Byte],
  offset? : Int,
  max_len? : Int
) -> Int

pub async fn InflateReader::close(self : InflateReader) -> Unit

// Implement async traits
pub impl @io.Reader for InflateReader
pub impl @io.Writer for DeflateWriter

// --- Convenience API (Layer 3) ---

pub async fn compress(
  data : Bytes,
  level~ : CompressionLevel = DefaultCompression,
  dict~ : Bytes? = None
) -> Bytes raise CompressError

pub async fn decompress(
  data : Bytes,
  dict~ : Bytes? = None
) -> Bytes raise CompressError
```

### 3b. gzip

```moonbit
pub(all) struct Header {
  name : String
  comment : String
  extra : Bytes
  mod_time : Int64           // unix timestamp, 0 = omitted
  os : Byte                  // OS identifier (0xFF = unknown)
}

pub fn Header::default() -> Header

pub struct GzipWriter {
  priv downstream : &@io.Writer
  priv deflater : DeflateWriter
  priv mut crc : UInt
  priv mut size : UInt
  priv header : Header
  priv mut header_written : Bool
}

pub async fn GzipWriter::new(
  w : &@io.Writer,
  level~ : CompressionLevel = DefaultCompression,
  header~ : Header = Header::default()
) -> GzipWriter raise CompressError

pub async fn GzipWriter::write(self : GzipWriter, data : &@io.Data) -> Unit
pub async fn GzipWriter::flush(self : GzipWriter) -> Unit
pub async fn GzipWriter::close(self : GzipWriter) -> Unit  // writes CRC + size footer

pub struct GzipReader {
  priv upstream : &@io.Reader
  priv inflater : InflateReader
  priv mut crc : UInt
  priv mut size : UInt
  pub header : Header                  // populated after construction
}

pub async fn GzipReader::new(r : &@io.Reader) -> GzipReader raise CompressError
pub async fn GzipReader::read(
  self : GzipReader, buf : FixedArray[Byte], offset? : Int, max_len? : Int
) -> Int
pub async fn GzipReader::close(self : GzipReader) -> Unit raise CompressError  // verifies checksum

pub impl @io.Reader for GzipReader
pub impl @io.Writer for GzipWriter

// --- Convenience ---
pub async fn compress(data : Bytes, level~ : CompressionLevel = DefaultCompression, header~ : Header = Header::default()) -> Bytes raise CompressError
pub async fn decompress(data : Bytes) -> (Bytes, Header) raise CompressError
```

### 3c. zlib

```moonbit
pub struct ZlibWriter {
  priv downstream : &@io.Writer
  priv deflater : DeflateWriter
  priv mut adler : UInt
  priv dict : Bytes?
}

pub async fn ZlibWriter::new(
  w : &@io.Writer,
  level~ : CompressionLevel = DefaultCompression,
  dict~ : Bytes? = None
) -> ZlibWriter raise CompressError

pub async fn ZlibWriter::write(self : ZlibWriter, data : &@io.Data) -> Unit
pub async fn ZlibWriter::flush(self : ZlibWriter) -> Unit
pub async fn ZlibWriter::close(self : ZlibWriter) -> Unit  // writes Adler-32 footer

pub struct ZlibReader {
  priv upstream : &@io.Reader
  priv inflater : InflateReader
  priv mut adler : UInt
}

pub async fn ZlibReader::new(r : &@io.Reader, dict~ : Bytes? = None) -> ZlibReader raise CompressError
pub async fn ZlibReader::read(self : ZlibReader, buf : FixedArray[Byte], offset? : Int, max_len? : Int) -> Int
pub async fn ZlibReader::close(self : ZlibReader) -> Unit raise CompressError

pub impl @io.Reader for ZlibReader
pub impl @io.Writer for ZlibWriter

// --- Convenience ---
pub async fn compress(data : Bytes, level~ : CompressionLevel = DefaultCompression, dict~ : Bytes? = None) -> Bytes raise CompressError
pub async fn decompress(data : Bytes, dict~ : Bytes? = None) -> Bytes raise CompressError
```

### 3d. lzw

```moonbit
pub enum BitOrder { LSB; MSB }

pub async fn compress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width : Int
) -> Unit raise CompressError

pub async fn decompress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width : Int
) -> Unit raise CompressError

// --- Convenience ---
pub async fn compress_bytes(data : Bytes, order : BitOrder, lit_width : Int) -> Bytes raise CompressError
pub async fn decompress_bytes(data : Bytes, order : BitOrder, lit_width : Int) -> Bytes raise CompressError
```

`compress_bytes()` and `decompress_bytes()` should be thin wrappers over local helpers in `internal/bytes`, not implementations built on top of `@io.pipe()`.

### 3e. bzip2 (decompress only)

```moonbit
pub struct Bzip2Reader {
  priv upstream : &@io.Reader
  priv mut state : Bzip2DecompressState
}

pub async fn Bzip2Reader::new(r : &@io.Reader) -> Bzip2Reader raise CompressError
pub async fn Bzip2Reader::read(self : Bzip2Reader, buf : FixedArray[Byte], offset? : Int, max_len? : Int) -> Int
pub async fn Bzip2Reader::close(self : Bzip2Reader) -> Unit

pub impl @io.Reader for Bzip2Reader

// --- Convenience ---
pub async fn decompress(data : Bytes) -> Bytes raise CompressError
```

### 3f. checksum

```moonbit
// Pure, no async needed — these are just math

pub(open) trait Hasher {
  size(Self) -> Int
  reset(Self) -> Unit
  update(Self, BytesView) -> Unit
  checksum(Self) -> UInt
}

pub struct CRC32 { priv mut crc : UInt }
pub fn CRC32::new() -> CRC32
pub impl Hasher for CRC32

pub struct Adler32 { priv mut s1 : UInt; priv mut s2 : UInt }
pub fn Adler32::new() -> Adler32
pub impl Hasher for Adler32

// Convenience pure functions
pub fn crc32(data : BytesView) -> UInt
pub fn adler32(data : BytesView) -> UInt
```

---

## 4. Internal Architecture: State Machines

The streaming wrappers (Layer 2) drive pure state machines (Layer 1) that process chunks. The state machines themselves do no I/O.

### 4a. Inflate State Machine

```moonbit
// Internal — not pub. Driven by InflateReader.
enum InflateStep {
  NeedInput                    // needs more compressed bytes from upstream
  ProducedOutput(Bytes)        // has decompressed bytes ready
  Finished                     // stream complete
  Error(CompressError)         // unrecoverable
}

struct InflateState {
  dict : DictDecoder           // 32KB sliding window
  mut bit_buf : UInt64         // bit accumulator
  mut bit_count : Int
  mut block_state : BlockState // which block type, how far through it
  mut final_block : Bool
}

fn InflateState::new(dict : Bytes?) -> InflateState
fn InflateState::feed(self : InflateState, input : BytesView) -> Unit
fn InflateState::step(self : InflateState) -> InflateStep
```

The `InflateReader.read()` loop:
```
1. Call state.step()
2. If NeedInput: read chunk from upstream Reader, call state.feed(chunk)
3. If ProducedOutput(bytes): copy into caller's buffer, return count
4. If Finished: return 0 (EOF)
5. If Error: raise
```

### 4b. Deflate State Machine

```moonbit
enum DeflateStep {
  NeedInput                    // ready for more uncompressed data
  ProducedOutput(Bytes)        // has compressed bytes ready
  Finished                     // after close(), final block emitted
}

struct DeflateState {
  level : CompressionLevel
  window : FixedArray[Byte]    // 32KB sliding window
  hash_chains : FixedArray[Int] // string match hash table
  mut pending : Buffer         // compressed output accumulator
  mut bit_buf : UInt64
  mut bit_count : Int
  // ... match finder state, block state
}

fn DeflateState::new(level : CompressionLevel, dict : Bytes?) -> DeflateState raise CompressError
fn DeflateState::write(self : DeflateState, input : BytesView) -> Unit
fn DeflateState::flush(self : DeflateState) -> Bytes
fn DeflateState::finish(self : DeflateState) -> Bytes
```

The `DeflateWriter.write()` loop:
```
1. Feed input to state.write(chunk)
2. Call state.flush() to get compressed output
3. Write output to downstream Writer
```

### 4c. Composability via Reader/Writer Chaining

Because `GzipReader` implements `@io.Reader` and wraps an `@io.Reader`, streams compose naturally:

```moonbit
// Decompress gzip from a TCP socket
let tcp = @socket.Tcp::connect!(addr)
let gz = @gzip.GzipReader::new!(tcp)
let data = gz.read_all!()

// Compress to a file with zlib framing
let file = @fs.create!("out.zlib", permission=0o644)
let zw = @zlib.ZlibWriter::new!(file)
zw.write!(data)
zw.close!()

// Pipe: compress in one task, decompress in another
let (pr, pw) = @io.pipe()
@async.with_task_group!(async fn(g) {
  g.spawn(async fn() {
    let w = @gzip.GzipWriter::new!(pw)
    w.write!(input_data)
    w.close!()
    pw.close()
  })
  g.spawn(async fn() {
    let r = @gzip.GzipReader::new!(pr)
    let result = r.read_all!()
    r.close!()
  })
})
```

---

## 5. Module Structure

```
compress-claude/
  moon.mod.json                     # module: "blem/compress"
                                    # deps: moonbitlang/async
  lib/
    checksum/                       # Pure, no async dependency
      moon.pkg.json
      hasher.mbt                    # Hasher trait
      crc32.mbt
      adler32.mbt
      *_test.mbt

    internal/                       # Shared internals (not pub)
      moon.pkg.json
      bit_reader.mbt               # Read bits from BytesView
      bit_writer.mbt               # Write bits to Buffer

    internal/bytes/                 # Thin in-memory async io helpers
      moon.pkg.json
      bytes_reader.mbt
      bytes_writer.mbt
      *_test.mbt

    flate/
      moon.pkg.json                 # deps: [checksum, internal]
                                    # import: moonbitlang/async/io
      types.mbt                     # CompressionLevel, CompressError, Token (#valtype)
      huffman.mbt                   # Huffman tree build + code tables
      dict_decoder.mbt              # 32KB sliding window
      inflate_state.mbt             # Pure inflate state machine (Layer 1)
      deflate_state.mbt             # Pure deflate state machine (Layer 1)
      deflate_fast.mbt              # Level 1 fast path
      huffman_bit_writer.mbt        # Bit-level Huffman output
      inflate_reader.mbt            # InflateReader : @io.Reader (Layer 2)
      deflate_writer.mbt            # DeflateWriter : @io.Writer (Layer 2)
      compress.mbt                  # Convenience Bytes->Bytes (Layer 3)
      *_test.mbt

    gzip/
      moon.pkg.json                 # deps: [flate, checksum]
      types.mbt                     # Header, errors
      gzip_reader.mbt              # GzipReader : @io.Reader
      gzip_writer.mbt              # GzipWriter : @io.Writer
      compress.mbt                  # Convenience API
      *_test.mbt

    zlib/
      moon.pkg.json                 # deps: [flate, checksum]
      types.mbt
      zlib_reader.mbt              # ZlibReader : @io.Reader
      zlib_writer.mbt              # ZlibWriter : @io.Writer
      compress.mbt
      *_test.mbt

    lzw/
      moon.pkg.json                 # deps: [internal, internal/bytes]
      types.mbt                     # BitOrder, LzwCompressState, LzwDecompressState
      lzw_state.mbt                # Pure LZW state machines
      compress.mbt
      *_test.mbt

    bzip2/
      moon.pkg.json                 # deps: [internal, checksum]
      types.mbt
      huffman.mbt                   # bzip2-specific Huffman
      move_to_front.mbt
      bzip2_state.mbt              # Pure bzip2 decompress state machine
      bzip2_reader.mbt             # Bzip2Reader : @io.Reader
      decompress.mbt               # Convenience API
      *_test.mbt

  testdata/
    e.txt
    gettysburg.txt
    pi.txt
    golden/                         # Go-generated golden compressed files
      manifest.json

  tools/
    generate_golden.go
    cross_validate.go
```

### Dependency Graph

```
checksum ──────────────────────────┐
    (pure, no async)               │
                                   │
internal ──────────────────────────┤
    (pure bit reader/writer)       │
                                   │
flate ─────────────────────────────┤
    depends on: checksum, internal │
    imports: moonbitlang/async/io  │
                                   │
gzip ──┬── depends on: flate, checksum
zlib ──┤
       │
lzw ───┴── depends on: internal
bzip2 ──── depends on: internal, checksum
```

---

## 6. MoonBit Design Patterns

### 6a. Value Types for Tokens

```moonbit
#valtype
pub(all) struct Token {
  bits : UInt  // packed type|length|offset
}

fn Token::literal(b : Byte) -> Token {
  Token::{ bits: b.to_uint() }
}

fn Token::match_(length : Int, offset : Int) -> Token {
  Token::{ bits: 0x4000_0000U.lor(length.to_uint().lsl(15)).lor(offset.to_uint()) }
}
```

### 6b. Bit Patterns for Header Parsing

```moonbit
async fn parse_gzip_header(r : &@io.Reader) -> Header raise CompressError {
  let header_bytes = try { r.read_exactly!(10) } catch {
    ReaderClosed(_) => raise CompressError::UnexpectedEOF
  }
  match header_bytes[..] {
    [ 0x1Fu8, 0x8Bu8, 0x08u8, flags, mtime0, mtime1, mtime2, mtime3, _xfl, os ] => {
      let mod_time = mtime0.to_int64()
        .lor(mtime1.to_int64().lsl(8))
        .lor(mtime2.to_int64().lsl(16))
        .lor(mtime3.to_int64().lsl(24))
      // parse optional fields based on flags...
      Header::{ name: "", comment: "", extra: b"", mod_time, os }
    }
    _ => raise CompressError::InvalidHeader("not gzip")
  }
}
```

### 6c. Async Read Loop Pattern

```moonbit
// InflateReader.read — the core async decompression loop
pub async fn InflateReader::read(
  self : InflateReader,
  buf : FixedArray[Byte],
  offset~ : Int = 0,
  max_len~ : Int = buf.length() - offset
) -> Int {
  loop {
    match self.state.step() {
      NeedInput => {
        // Read from upstream — async suspension point
        match self.upstream.read_some!() {
          Some(chunk) => self.state.feed(chunk[..])
          None => raise CompressError::UnexpectedEOF
        }
      }
      ProducedOutput(data) => {
        let n = @math.minimum(data.length(), max_len)
        data.blit_to(buf, dst_offset=offset, length=n)
        return n
      }
      Finished => return 0
      Error(e) => raise e
    }
  }
}
```

### 6d. Async Write + Flush Pattern

```moonbit
pub async fn DeflateWriter::write(self : DeflateWriter, data : &@io.Data) -> Unit {
  let bytes = data.binary()
  self.state.write(bytes[..])
  // Flush compressed output to downstream
  let compressed = self.state.flush()
  if compressed.length() > 0 {
    self.downstream.write!(compressed)
  }
}

pub async fn DeflateWriter::close(self : DeflateWriter) -> Unit {
  let final_bytes = self.state.finish()
  if final_bytes.length() > 0 {
    self.downstream.write!(final_bytes)
  }
}
```

### 6e. Convenience API via Internal Bytes Helpers

```moonbit
pub async fn compress(
  data : Bytes,
  level~ : CompressionLevel = DefaultCompression
) -> Bytes raise CompressError {
  let reader = @ibytes.BytesReader::new(data)
  let writer = @ibytes.BytesWriter::new()
  compress(reader, writer, level~)
  writer.content()
}
```

Or, for the simple case, bypass async entirely with a synchronous buffer path:

```moonbit
// Alternative: pure synchronous path for Bytes->Bytes
// Uses Layer 1 state machine directly, no async overhead
pub fn compress_sync(
  data : Bytes,
  level~ : CompressionLevel = DefaultCompression
) -> Bytes raise CompressError {
  let state = DeflateState::new!(level)
  state.write(data[..])
  state.finish()
}
```

### 6f. Structured Concurrency for Parallel Streams

```moonbit
// Compress multiple files concurrently
async fn compress_files(paths : Array[String]) -> Unit raise Error {
  @async.with_task_group!(async fn(g) {
    for path in paths {
      g.spawn(async fn() {
        let infile = @fs.open!(path, mode=ReadOnly)
        let outfile = @fs.create!(path + ".gz", permission=0o644)
        let gz = @gzip.GzipWriter::new!(outfile,
          header=Header::{ name: path, ..Header::default() })
        gz.write_reader!(infile)  // stream from file through compressor
        gz.close!()
        outfile.close()
        infile.close()
      })
    }
  })
}
```

---

## 7. Concurrency Safety

### By Design

- **No global mutable state.** Lookup tables (CRC-32, Huffman fixed codes) are module-level `let` bindings — immutable after init.
- **Each Reader/Writer owns its state.** No shared references between instances. A `GzipWriter` owns its `DeflateWriter` which owns its `DeflateState`.
- **Structured concurrency via task groups.** moonbitlang/async's `with_task_group` ensures no orphan tasks, automatic cancellation on failure.
- **No locks needed.** State machines are single-owner. Concurrency happens at the stream level (different tasks compress different streams), not within a single compressor.

### Safe Patterns

```moonbit
// SAFE: Each task has its own compressor instance
@async.with_task_group!(async fn(g) {
  for file in files {
    g.spawn(async fn() {
      let w = @gzip.GzipWriter::new!(output)  // fresh instance per task
      w.write!(data)
      w.close!()
    })
  }
})

// SAFE: Pipeline — one task writes, another reads, connected by pipe
let (pr, pw) = @io.pipe()
g.spawn(async fn() { /* compress to pw */ })
g.spawn(async fn() { /* read from pr */ })
```

---

## 8. Porting Phases

### Phase 1: Foundations

**1a. checksum** (~120 LOC) — Pure, no async
- CRC-32 IEEE: table-driven, `update(BytesView) -> UInt`
- Adler-32: two sums mod 65521
- Tests from Go's `hash/crc32` and `hash/adler32`

**1b. internal/bit_reader + bit_writer** (~150 LOC) — Pure
- `BitReader`: read N bits from `BytesView`, track position
- `BitWriter`: write N bits to `Buffer`, flush to bytes

**1c. lzw** (~500 LOC)
- Layer 1: `LzwCompressState` / `LzwDecompressState`
- Layer 2: `compress(reader, writer, ...)` / `decompress(reader, writer, ...)`
- Layer 3: `compress_bytes(...) -> Bytes` / `decompress_bytes(...) -> Bytes`
- Tests: port `reader_test.go` (313 lines), `writer_test.go` (238 lines)

**1d. bzip2** (~600 LOC, decompress only)
- Layer 1: `Bzip2DecompressState` (Huffman, MTF, inverse BWT)
- Layer 2: `Bzip2Reader : @io.Reader`
- Layer 3: `decompress(Bytes) -> Bytes`
- Tests: port `bzip2_test.go` (250 lines)

### Phase 2: Core Engine — flate

**2a. Types + constants** (~100 LOC)
- `CompressionLevel` enum, `CompressError` type, `Token` valtype

**2b. Huffman coding** (~300 LOC)
- Tree construction from frequencies
- Fixed tables (RFC 1951 literal/length + distance)
- `HuffmanEncoder` / `HuffmanDecoder`

**2c. Dict decoder** (~180 LOC)
- 32KB circular buffer: `write_byte`, `write_copy`, `read_flush`

**2d. Inflate state machine** (~600 LOC)
- `InflateState`: block parsing, Huffman decoding, dict writes
- `InflateReader : @io.Reader`

**2e. Huffman bit writer** (~500 LOC)
- Stored, fixed, dynamic block emission

**2f. Deflate state machine** (~800 LOC)
- Hash chains (levels 2-9), fast path (level 1), lazy matching
- `DeflateState`: `write()`, `flush()`, `finish()`
- `DeflateWriter : @io.Writer`

**2g. Public API + integration** (~100 LOC)
- `compress()` / `decompress()` convenience functions
- Round-trip tests, golden file tests

### Phase 3: Format Wrappers

**3a. zlib** (~300 LOC)
- Header/footer with Adler-32
- `ZlibReader : @io.Reader`, `ZlibWriter : @io.Writer`
- Wraps `InflateReader`/`DeflateWriter` + checksum

**3b. gzip** (~400 LOC)
- Header/footer with CRC-32
- `GzipReader : @io.Reader`, `GzipWriter : @io.Writer`
- Bit pattern parsing for headers
- `Header` struct with name, comment, extra, mod_time, os

---

## 9. Parity Comparison Mechanism

Same 6-level matrix as `PLAN.md`, adapted for async:

### 9a. Golden File Generation

`tools/generate_golden.go` produces:
- `testdata/golden/<algo>_<level>_<input>.compressed`
- `testdata/golden/manifest.json` (sizes, CRC-32s, params)

### 9b. Test Matrix

| Test | Method | Validates |
|------|--------|-----------|
| **T1: Go->MoonBit** | Load golden file as `Bytes`, wrap in `@io.pipe()`, decompress via `XxxReader` | Decompressor correctness |
| **T2: Round-trip** | Compress via `XxxWriter` to pipe, decompress via `XxxReader`, assert identity | Internal consistency |
| **T3: MoonBit->Go** | Compress in MoonBit, write to file, Go `cross_validate.go` decompresses | Standards compliance |
| **T4: Error cases** | Feed corrupt data via pipe, assert `CompressError` raised | Error handling |
| **T5: Edge cases** | Empty, 1-byte, 32KB boundary, all-zeros, random | Boundary conditions |
| **T6: Stream cancel** | Cancel task mid-stream, verify no hangs or leaks | Async robustness |

### 9c. Streaming-Specific Tests

```moonbit
test "T2: gzip streaming round-trip" {
  // Use in-memory pipe to test streaming behavior
  let (pr, pw) = @io.pipe()
  let input = read_testdata!("gettysburg.txt")

  @async.with_task_group!(async fn(g) {
    // Producer: compress
    g.spawn(async fn() {
      let w = @gzip.GzipWriter::new!(pw)
      // Write in small chunks to exercise streaming
      for chunk in input.chunks(256) {
        w.write!(chunk)
      }
      w.close!()
      pw.close()
    })

    // Consumer: decompress
    g.spawn(async fn() {
      let r = @gzip.GzipReader::new!(pr)
      let output = r.read_all!()
      assert_eq!(output.binary(), input)
      r.close!()
    })
  })
}

test "T6: cancel mid-stream" {
  let (pr, pw) = @io.pipe()
  let large_input = random_bytes(1_000_000)

  match @async.with_timeout!(100, async fn() {
    let w = @gzip.GzipWriter::new!(pw)
    w.write!(large_input)  // will be cancelled mid-write
    w.close!()
  }) {
    _ => ()  // timeout is expected
  }
  // Verify no deadlock — pipe cleanup handles cancellation
}
```

### 9d. CI Pipeline

```
1. moon check
2. moon test                                # T1, T2, T4, T5, T6
3. go run tools/generate_golden.go          # regenerate if needed
4. moon test --filter golden                # T1 re-run
5. moon run lib/export_compressed           # write MoonBit output to files
6. go test ./tools/ -run CrossValidate      # T3
```

---

## 10. Comparison: I/O-Free vs Async I/O Design

| Aspect | I/O-Free (`PLAN.md`) | Async I/O (this plan) |
|--------|----------------------|----------------------|
| Primary API | `fn(Bytes) -> Bytes` | `Reader`/`Writer` streams |
| Streaming | Optional Layer 2 | Primary design |
| Memory for large files | Must buffer entire input | Constant memory (chunk-based) |
| Composability | Manual: `gzip(flate(data))` | Chain: `GzipWriter(file)` |
| Dependency | None (pure MoonBit) | `moonbitlang/async` |
| Go API fidelity | Low — different paradigm | High — same Reader/Writer pattern |
| Testing | Simpler (pure functions) | Needs async test harness |
| Concurrency | Trivially safe (pure) | Safe via structured concurrency |
| Use with sockets/files | Caller must buffer+call | Direct streaming |
| Sync `Bytes->Bytes` | Primary | Available via local `internal/bytes` helpers |

### Recommendation

This async design is the better choice when:
- Processing files larger than available memory
- Streaming over network connections (HTTP, sockets)
- Building pipelines (decompress -> transform -> recompress)
- Maximum fidelity to Go's original API intent

The I/O-free design is better when:
- Targeting WASM (no async runtime)
- Embedding in pure-functional pipelines
- Minimal dependency footprint

Both designs share Layer 1 (pure state machines), so they can coexist.

---

## 11. Definition of Done

1. `moon check` — zero warnings
2. `moon test` — all pass (golden, round-trip, streaming, error, edge, cancel)
3. `go test ./tools/` — cross-validation green
4. Every Reader implements `@io.Reader`, every Writer implements `@io.Writer`
5. Streaming works: compress/decompress 100MB+ file in constant memory
6. Concurrent compression of N files via `with_task_group` works correctly
7. No global mutable state
8. Parity matrix (Section 9b) fully green
