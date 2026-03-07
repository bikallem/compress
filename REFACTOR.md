# Stream Refactor Plan

## Motivation

The current async streaming layer across all codec packages (flate, gzip, zlib, lzw, bzip2) is **fake streaming**. Every writer buffers the entire input in `@buffer.Buffer` and compresses on `close()`. Decompression reads all input into memory before calling the pure Layer 1 function. A 1GB file loads 1GB into RAM before any work begins.

This refactor introduces a reusable `@stream` package inspired by [bytesrw](https://github.com/dbuenzli/bytesrw) that provides:
- True incremental streaming with bounded memory (O(slice_length), default 64 KiB)
- Buffer reuse via the borrow-invalidate pattern (BytesView into FixedArray[Byte])
- Composable Reader/Writer traits with trait objects
- Clean separation: sync codecs in `@stream`, async bridging in `@stream/async`

## Design

### Core Types (`stream/`)

```moonbit
pub type! StreamError {
  UnexpectedEod
  Format(~message : String)
  Io(~message : String)
}

/// Pull-based byte stream.
/// Returned BytesView is valid only until next read() call (borrow-invalidate).
/// Empty BytesView (length 0) = end of data.
pub trait Reader {
  read(Self) -> BytesView!StreamError
}

/// Push-based byte stream.
/// Empty BytesView = end of data.
pub trait Writer {
  write(Self, BytesView) -> Unit!StreamError
}
```

### Concrete Implementations (`stream/`)

| Type | Implements | Purpose |
|------|-----------|---------|
| `SliceReader` | `Reader` | Reads from `Bytes`, yields `slice_length`-bounded chunks |
| `FnReader` | `Reader` | Reads via a fill callback, owns reusable `FixedArray[Byte]` buffer |
| `BufferWriter` | `Writer` | Collects output into `Buffer`, extract with `to_bytes()` |
| `FnWriter` | `Writer` | Writes via a callback |

### Combinators (`stream/`)

| Type | Implements | Purpose |
|------|-----------|---------|
| `Buffered` | `Reader` | Wraps `&Reader`, adds 1-element `push_back` for header sniffing |
| `LimitReader` | `Reader` | Limits reads to first N bytes |
| `AppendReader` | `Reader` | Concatenates two readers sequentially |
| `TapReader` | `Reader` | Observes slices without transforming (hashing, logging) |
| `TapWriter` | `Writer` | Same for writers |
| `CountedReader` | `Reader` | Tracks byte position |
| `CountedWriter` | `Writer` | Tracks byte position |

### Free Functions (`stream/`)

```moonbit
pub fn pipe(reader : &Reader, writer : &Writer) -> Unit!StreamError
pub fn read_all(reader : &Reader) -> Bytes!StreamError
```

### Async Adapter (`stream/async/`)

Bridge between `@io.Reader`/`@io.Writer` (moonbitlang/async) and `@stream.Reader`/`@stream.Writer`.

```moonbit
/// Wraps @io.Writer as @stream.Writer (async-to-sync boundary)
struct IoWriterAdapter { ... }
impl @stream.Writer for IoWriterAdapter

/// Wraps @stream.Reader as @io.Reader (sync-to-async, trivial)
struct StreamToIoReader { ... }
impl @io.Reader for StreamToIoReader

/// Async source -> sync Writer filter -> async dest
/// Push-based: async caller controls the loop, pushes chunks into sync codec
pub async fn pipe_async(
  source : &@io.Reader,
  dest : &@io.Writer,
  filter : (&@stream.Writer) -> &@stream.Writer,
  ~slice_length : Int = 65536,
) -> Unit!@stream.StreamError
```

### Codec Integration Pattern

Each codec implements `@stream.Reader` (decompression) and/or `@stream.Writer` (compression):

```moonbit
// In @flate:
struct InflateReader { source : &@stream.Reader, ... }
impl @stream.Reader for InflateReader

struct DeflateWriter { dest : &@stream.Writer, ... }
impl @stream.Writer for DeflateWriter

// In @gzip (wraps @flate):
struct GzipReader { inner : InflateReader, ... }
impl @stream.Reader for GzipReader

struct GzipWriter { inner : DeflateWriter, ... }
impl @stream.Writer for GzipWriter
```

### Layer Architecture After Refactor

```
@stream              (new, zero deps, WASM-safe)
├── Reader/Writer traits
├── SliceReader, BufferWriter, combinators
├── pipe, read_all

@flate               (depends: @stream, @internal, @checksum)
├── compress/decompress         Layer 1: pure Bytes -> Bytes
├── InflateReader : Reader      Layer 3: sync streaming decompress
├── DeflateWriter : Writer      Layer 3: sync streaming compress

@gzip                (depends: @stream, @flate, @checksum)
├── compress/decompress         Layer 1: pure Bytes -> Bytes
├── GzipReader : Reader         Layer 3: header + inflate + footer
├── GzipWriter : Writer         Layer 3: header + deflate + footer

@zlib, @lzw, @bzip2  (same pattern)

@stream/async        (depends: @stream, moonbitlang/async)
├── IoWriterAdapter, StreamToIoReader
├── pipe_async
├── NO codec logic — just bridging

moonbitlang/async dependency REMOVED from all codec packages
```

## Phases

### Phase 1: `@stream` package

Create the new `stream/` package with zero dependencies. All core types, concrete implementations, combinators, and free functions. Full test coverage.

**Tasks:**
- 1a. Package setup, StreamError, Reader trait, Writer trait
- 1b. SliceReader, FnReader implementations
- 1c. BufferWriter, FnWriter implementations
- 1d. Combinators: Buffered, LimitReader, AppendReader
- 1e. Combinators: TapReader, TapWriter, CountedReader, CountedWriter
- 1f. Free functions: pipe, read_all
- 1g. Tests for all types and edge cases

### Phase 2: Refactor flate to use `@stream`

Make the core decompression/compression algorithms work incrementally with `@stream.Reader`/`@stream.Writer`. This is the hardest phase — BitReader needs to pull from `&Reader`, DictDecoder needs to flush as BytesView chunks.

**Tasks:**
- 2a. Refactor BitReader to pull chunks from `&@stream.Reader` on demand
- 2b. Refactor DictDecoder to yield BytesView output chunks (not Buffer)
- 2c. InflateReader: struct implementing `@stream.Reader`, incremental block decoding
- 2d. DeflateWriter: struct implementing `@stream.Writer`, incremental LZ77 + Huffman
- 2e. Keep Layer 1 pure API (compress/decompress Bytes->Bytes) implemented via stream types
- 2f. Delete async_inflate.mbt, async_deflate_writer.mbt; update tests

### Phase 3: Refactor wrapper codecs

Each wrapper codec (gzip, zlib, lzw, bzip2) gets Reader/Writer types wrapping the underlying codec's stream types.

**Tasks:**
- 3a. gzip: GzipReader (header parse + InflateReader + CRC32 tap + footer verify)
- 3b. gzip: GzipWriter (header emit + DeflateWriter + CRC32 tap + footer emit)
- 3c. zlib: ZlibReader, ZlibWriter (same pattern with Adler-32)
- 3d. lzw: LzwReader, LzwWriter (incremental LZW state machine)
- 3e. bzip2: Bzip2Reader (incremental bzip2 decompression)
- 3f. Delete all async_*.mbt files from wrapper packages; update tests

### Phase 4: `@stream/async` adapter package

Thin adapter between `@stream` and `moonbitlang/async`. This is the ONLY package that depends on `moonbitlang/async`.

**Tasks:**
- 4a. Package setup, IoWriterAdapter, StreamToIoReader
- 4b. pipe_async function
- 4c. Remove moonbitlang/async dependency from all codec packages
- 4d. Update moon.mod.json, all moon.pkg files

### Phase 5: Update examples, tests, benchmarks

**Tasks:**
- 5a. Update all examples/ to use new stream API
- 5b. Verify golden file parity (cross_validate.go)
- 5c. Update benchmarks
- 5d. Update PLAN.md, README.md, docs

## Migration Strategy

- Layer 1 pure APIs (`compress`/`decompress` taking `Bytes`) remain unchanged — no breaking change for simple use cases
- Async examples migrate to use `@stream/async.pipe_async` with codec writer filters
- Each phase is independently testable and committable
- Golden file tests validate byte-level parity throughout

## Files to Delete (Phase 2-3)

```
flate/async_inflate.mbt
flate/async_deflate_writer.mbt
flate/async_inflate_test.mbt
gzip/async_decompress.mbt
gzip/async_writer.mbt
gzip/async_decompress_test.mbt
zlib/async_decompress.mbt
zlib/async_writer.mbt
lzw/async_decompress.mbt
lzw/async_writer.mbt
lzw/async_decompress_test.mbt
bzip2/async_decompress.mbt
bzip2/async_decompress_test.mbt
```

## Files to Create

```
stream/moon.pkg
stream/types.mbt              # StreamError, Reader, Writer traits
stream/slice_reader.mbt       # SliceReader
stream/fn_reader.mbt          # FnReader
stream/buffer_writer.mbt      # BufferWriter
stream/fn_writer.mbt          # FnWriter
stream/combinators.mbt        # Buffered, LimitReader, AppendReader, Tap*, Counted*
stream/pipe.mbt               # pipe, read_all
stream/stream_test.mbt        # Tests
stream/async/moon.pkg
stream/async/adapters.mbt     # IoWriterAdapter, StreamToIoReader
stream/async/pipe_async.mbt   # pipe_async
stream/async/async_test.mbt   # Tests
```
