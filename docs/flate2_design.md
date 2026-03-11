# flate2: Jsonm-Style Streaming DEFLATE

## The Jsonm Pattern

The OCaml `jsonm` library separates codec logic from I/O through a **signal protocol**:

```
decode(d) → Await | Data(bytes) | End | Error(e)
```

- **`Await`** — decoder needs more input. Caller calls `src(d, bytes)` then retries.
- **`Data(bytes)`** — decoder produced output. Caller consumes it, then retries.
- **`End`** — stream is complete.
- **`Error(e)`** — unrecoverable format error.

The codec never reads or writes I/O. It's a **state machine** that the caller drives in a loop. The caller decides where bytes come from and where they go — files, network, memory, async runtime, whatever. The codec doesn't care.

Encoding mirrors this:

```
encode(e, data) → Ok | Partial
```

- **`Ok`** — input consumed, ready for more.
- **`Partial`** — output buffer full. Caller drains via `dst(e)` then retries.

## Why This Matters for flate

The current flate package has three layers because it conflates **algorithm** with **I/O strategy**:

| Layer | Coupling |
|-------|----------|
| L1 `decompress(Bytes) -> Bytes` | Requires all input in memory, produces all output in memory |
| L2 async | Requires `moonbitlang/async` runtime |
| L3 sync stream | Requires `@stream.Reader`/`@stream.Writer` traits |

The jsonm pattern eliminates all three layers. One codec, zero I/O dependencies. The caller provides the I/O glue — which can be a 5-line loop for any of the above use cases.

## Design

### Signal Types

```moonbit
/// Decoder signals — returned by Inflater::decode()
pub enum Decode {
  Await       // Need input. Call src(bytes) then decode() again.
  Data(Bytes) // Produced output. Consume it, then decode() again.
  End         // Stream complete. Remaining input via Inflater::remaining().
  Error(CompressError)
}

/// Encoder signals — returned by Deflater::encode()
pub enum Encode {
  Ok          // Input consumed. Call encode(Some(more)) or encode(None) to finish.
  Data(Bytes) // Produced output. Consume it, then call encode() again with same arg.
  End         // Final output flushed. Encoding complete.
  Error(CompressError)
}
```

### Decoder (Inflater)

```moonbit
pub struct Inflater { .. }  // abstract

pub fn Inflater::new(dict? : Bytes) -> Inflater

/// Feed input bytes. Only valid after decode() returned Await.
pub fn Inflater::src(self, data : Bytes) -> Unit

/// Advance the decoder one step.
pub fn Inflater::decode(self) -> Decode

/// After End: bytes consumed from input but not part of the DEFLATE stream.
/// Useful for wrapper formats (gzip/zlib) that read a footer.
pub fn Inflater::remaining(self) -> Bytes
```

**Usage — decompress all at once:**
```moonbit
fn decompress(data : Bytes) -> Bytes!CompressError {
  let d = Inflater::new()
  d.src(data)
  let buf = Buffer::new()
  loop d.decode() {
    Await => raise CompressError::UnexpectedEOF
    Data(chunk) => { buf.write_bytes(chunk); continue d.decode() }
    End => buf.to_bytes()
    Error(e) => raise e
  }
}
```

**Usage — streaming from any source:**
```moonbit
fn decompress_stream(
  read_chunk : () -> Bytes?,
  out : (Bytes) -> Unit,
) -> Unit!CompressError {
  let d = Inflater::new()
  loop d.decode() {
    Await =>
      match read_chunk() {
        Some(chunk) => { d.src(chunk); continue d.decode() }
        None => raise CompressError::UnexpectedEOF
      }
    Data(chunk) => { out(chunk); continue d.decode() }
    End => ()
    Error(e) => raise e
  }
}
```

**Usage — with async I/O (no dependency on async in flate2 itself):**
```moonbit
// In user code or a thin adapter package
async fn decompress_async(r : &@io.Reader, w : &@io.Writer) -> Unit! {
  let d = @flate2.Inflater::new()
  loop d.decode() {
    Await => {
      let chunk = r.read_some(65536)  // async
      d.src(chunk)
      continue d.decode()
    }
    Data(chunk) => { w.write(chunk[:]); continue d.decode() }  // async
    End => ()
    Error(e) => raise e
  }
}
```

### Encoder (Deflater)

```moonbit
pub struct Deflater { .. }  // abstract

pub fn Deflater::new(level? : CompressionLevel, dict? : Bytes) -> Deflater

/// Single entry point for encoding.
///   encode(Some(data)) — feed input to compress
///   encode(None)       — signal end of input, flush final block
/// Returns Ok (ready for more), Data(chunk) (output to consume), or End (done).
pub fn Deflater::encode(self, data : Bytes?) -> Encode
```

**Usage — compress all at once:**
```moonbit
fn compress(data : Bytes) -> Bytes!CompressError {
  let e = Deflater::new()
  let buf = Buffer::new()
  drain(e, buf, Some(data))
  drain(e, buf, None)
  buf.to_bytes()
}

fn drain(e : Deflater, buf : Buffer, input : Bytes?) -> Unit!CompressError {
  loop e.encode(input) {
    Ok | End => ()
    Data(chunk) => { buf.write_bytes(chunk); continue e.encode(input) }
    Error(e) => raise e
  }
}
```

**Usage — streaming from any source:**
```moonbit
fn compress_stream(
  read_chunk : () -> Bytes?,
  out : (Bytes) -> Unit
) -> Unit!CompressError {
  let e = Deflater::new()
  fn drain(input : Bytes?) {
    loop e.encode(input) {
      Ok | End => ()
      Data(chunk) => { out(chunk); continue e.encode(input) }
      Error(e) => raise e
    }
  }
  // Feed chunks until source is exhausted, then signal EOF
  loop read_chunk() {
    Some(chunk) => { drain(Some(chunk)); continue read_chunk() }
    None => drain(None)
  }
}
```
```

### Chunk Size

The decoder/encoder emit `Data(Bytes)` in bounded chunks (e.g. 32KB — the DEFLATE window size). This is natural:

- **Decoder**: emits whenever the 32KB DictDecoder window fills, exactly as today's `dd.read_flush()` / `dd.flush_to_writer()` calls do.
- **Encoder**: emits whenever the internal `BufferedBitWriter` auto-flushes its 8KB buffer.

No unbounded allocation. The caller processes each chunk before the next `decode()`/`encode()` call.

## Implementation Guidelines

### 1. Functional Loops with Invariants

Use MoonBit's functional `loop`/`for` with explicit state threading instead of C-style `while` + mutation. Annotate with `where { invariant:, reasoning: }` for non-trivial loops.

**Before (imperative):**
```moonbit
fn fill(self : BitBuf) -> Bool {
  while self.count <= 56 && self.pos < self.input.length() {
    self.buf = self.buf | (self.input[self.pos].to_uint64() << self.count)
    self.pos += 1
    self.count += 8
  }
  self.count > 0
}
```

**After (functional loop with invariant):**
```moonbit
fn fill(self : BitBuf) -> Bool {
  let (buf, count, pos) = for buf = self.buf, count = self.count, pos = self.pos
    count <= 56 && pos < self.input.length() {
    continue
      buf | (self.input[pos].to_uint64() << count),
      count + 8,
      pos + 1
  } nobreak {
    (buf, count, pos)
  } where {
    invariant: count <= 64 && pos <= self.input.length(),
    reasoning: "Each iteration packs one byte (8 bits) into buf from input[pos].",
  }
  self.buf = buf
  self.count = count
  self.pos = pos
  count > 0
}
```

Use bare `loop` (MoonBit's tail-recursive loop) for state machines where the next state is computed dynamically:

```moonbit
/// Drive the inflater to completion, collecting output.
fn collect(d : Inflater, src : Bytes) -> Bytes!CompressError {
  d.src(src)
  let buf = Buffer::new()
  loop d.decode() {
    Await => raise CompressError::UnexpectedEOF
    Data(chunk) => { buf.write_bytes(chunk); continue d.decode() }
    End => buf.to_bytes()
    Error(e) => raise e
  }
}
```

Use `for v in collection` for simple iteration without index tracking.

### 2. Methods over Free Functions

All operations on a type are methods on that type. No free functions that take the struct as first arg.

```moonbit
// Yes — method
fn BitBuf::read(self, n : Int) -> Int { .. }
fn Inflater::decode(self) -> Decode { .. }
fn DictDecoder::write_copy(self, dist : Int, length : Int) -> Int { .. }

// No — free function
fn read_bits(buf : BitBuf, n : Int) -> Int { .. }
fn decode_next(d : Inflater) -> Decode { .. }
```

Internal helpers that operate on the Inflater's sub-components are private methods on those components:

```moonbit
fn BitBuf::ensure(self, n : Int) -> Bool { .. }       // returns false if needs input
fn DictDecoder::flush(self) -> Bytes { .. }            // returns window contents
fn HuffmanDecoder::decode(self, bits : BitBuf) -> Int? { .. }  // None if needs input
```

### 3. Loop Invariant Placement

Add `where { invariant:, reasoning: }` to:
- **BitBuf::fill** — bit count stays in [0, 64], pos in [0, input.length()]
- **DictDecoder::write_copy** — overlapping copy correctness
- **Huffman table construction** — code length bounds
- **LZ77 matching loops** — window bounds, hash chain termination
- **Dynamic header parsing** — total code lengths = hlit + hdist

Skip invariants for trivial `for v in xs` loops.

## Internal Architecture

### What Changes

The core algorithms (Huffman tables, DictDecoder, LZ77 matching, bit manipulation) are **unchanged**. The refactoring is purely about the control flow boundary.

**Current**: Algorithm calls `br.fill()` which calls `reader.read()` — I/O is *inside* the loop.
**New**: Algorithm runs until it needs input, then *returns* `Await` — I/O is *outside* the loop.

This means converting the current recursive/loop-based decompressor into a **resumable state machine**.

### Inflater State Machine

```
                    ┌──────────────────────────────┐
                    │         BlockHeader           │
                    │  Read 3 bits: BFINAL, BTYPE   │
                    └──────┬───────┬───────┬────────┘
                           │       │       │
                    ┌──────▼──┐ ┌──▼────┐ ┌▼─────────┐
                    │ Stored  │ │ Fixed │ │ Dynamic   │
                    │ Block   │ │ Huff  │ │ Header    │
                    └────┬────┘ └───┬───┘ └─────┬─────┘
                         │         │            │
                         └────┬────┘            │
                              │    ┌────────────┘
                              ▼    ▼
                    ┌──────────────────────────────┐
                    │     HuffmanDecode Loop        │
                    │  (literals, lengths, dists)   │
                    └──────────────┬────────────────┘
                                   │
                              ┌────▼────┐
                              │ EndBlock│──→ next block or End
                              └─────────┘
```

At any point where the bit buffer is exhausted and more input is needed, the machine **suspends** by returning `Await`. The current position (which block type, where in the Huffman loop, partial length/distance decode) is saved in the `Inflater` struct.

The key states:

```moonbit
priv enum InflatePhase {
  BlockHeader
  StoredInit           // reading LEN/NLEN
  StoredCopy(Int)      // remaining bytes to copy
  DynamicHeader        // reading code length tables
  HuffmanLoop(HuffmanDecoder, HuffmanDecoder)
  Done
}
```

Each call to `decode()` runs the machine forward from its current phase, consuming bits from an internal `BitBuf` (just the `UInt64` + count — no Reader dependency). When bits run out:

1. Flush any pending DictDecoder output as `Data(chunk)`
2. Return `Await`

When the caller provides bytes via `src()`, they're appended to an input queue. Next `decode()` refills the bit buffer and resumes.

### Deflater State Machine

Similar pattern. The `StreamingCompressor` already works incrementally (fill window, step, emit tokens). The change:

- Instead of writing to a `BufferedBitWriter` that writes to a `@stream.Writer`, the `BufferedBitWriter` writes to an internal `Buffer`.
- When the buffer exceeds a threshold, `encode()` returns `Data(chunk)`.
- `encode(None)` flushes the final block and drains the buffer, returning `End` when complete.

### BitBuf — Replacing BitReader

Current `BitReader` wraps `@stream.Reader`. New `BitBuf` is just arithmetic:

```moonbit
priv struct BitBuf {
  mut buf : UInt64    // bit accumulator (LSB-first)
  mut count : Int     // valid bits in buf
  mut input : Bytes   // current input segment
  mut pos : Int       // position in input
}
```

`fill()` pulls bytes from `input[pos..]` into `buf`. When `input` is exhausted and more bits are needed, returns a "need input" signal to the caller (Inflater), which bubbles up as `Await`.

## Package Structure

```
flate2/
  types.mbt           # Decode, Encode, CompressError, CompressionLevel, RFC tables
  inflater.mbt         # Inflater struct + decode() state machine
  deflater.mbt         # Deflater struct + encode() state machine
  bitbuf.mbt           # BitBuf (pure, no I/O)
  dict_decoder.mbt     # DictDecoder (unchanged from flate/)
  huffman.mbt          # HuffmanDecoder (unchanged from flate/)
  huffman_encoder.mbt  # HuffmanCode (unchanged from flate/)
  fixed_huffman.mbt    # Fixed tables (unchanged from flate/)
  output_buffer.mbt    # OutputBuffer (unchanged from flate/)
  streaming_compressor.mbt  # LZ77 engine (adapted: writes to Buffer not Writer)
  blit.mbt + blit_stub.c   # Native FFI blit (unchanged from flate/)
  convenience.mbt      # decompress(Bytes)->Bytes, compress(Bytes)->Bytes wrappers
  inflater_test.mbt
  deflater_test.mbt
  round_trip_test.mbt
```

No `@stream` dependency. No `@io` dependency. No `moonbitlang/async` dependency.

The `moon.pkg.json` imports only `blem/compress/checksum` (if needed) and `moonbitlang/core`.

## What Happens to flate/, stream/, L2, L3?

Two options:

**Option A — Deprecate.** `flate2/` is the only flate package. Thin adapter functions (5-10 lines each) in gzip/, zlib/, or user code bridge to `@stream.Reader`/`@io.Reader`. The `stream/` package and its `Reader`/`Writer` traits remain for the adapters but flate2 itself doesn't use them.

**Option B — Coexist.** Keep `flate/` for backward compatibility. `flate2/` is the new recommended API. Migrate gzip/zlib to flate2 over time.

Recommendation: **Option A.** The three-layer split was the original design's answer to the I/O problem. The jsonm pattern *is* the answer — one layer serves all use cases. Less code, fewer packages, simpler dependency graph.

## Migration Path for gzip/zlib

These wrapper formats need to:
1. Read a header (fixed bytes)
2. Decompress a DEFLATE stream
3. Read a footer (checksum, length)

With the current flate, they use `decompress_reader()` which returns `(output, remaining_bytes)`.

With flate2, they drive the `Inflater` directly, which is *more* natural:

```moonbit
fn gunzip(data : Bytes) -> Bytes! {
  let pos = parse_gzip_header(data)  // returns offset after header
  let d = @flate2.Inflater::new()
  d.src(data.sub_bytes(pos))
  let buf = Buffer::new()
  let crc = CRC32::new()
  loop d.decode() {
    Await => raise CompressError::UnexpectedEOF
    Data(chunk) => {
      crc.update(chunk)
      buf.write_bytes(chunk)
      continue d.decode()
    }
    End => ()
    Error(e) => raise e
  }
  let footer = d.remaining()  // leftover bytes = gzip footer
  verify_gzip_footer(footer, crc.sum(), buf.length())
  buf.to_bytes()
}
```

The streaming case is equally clean — `Await` causes an async read, and the CRC updates happen naturally on each `Data` chunk.

## Implementation Plan

### Phase 1: Core Types + BitBuf (0.5 day)
- Create `flate2/` package
- `types.mbt` — signal enums, error type, constants, RFC tables (copy from flate/)
- `bitbuf.mbt` — `BitBuf` struct with fill/read/ensure that return need-input signals
- Copy unchanged internals: `dict_decoder.mbt`, `huffman.mbt`, `fixed_huffman.mbt`, `output_buffer.mbt`, `blit.mbt`, `blit_stub.c`

### Phase 2: Inflater (1-2 days)
- `inflater.mbt` — state machine wrapping the decompression loop
- Key challenge: converting the current straight-line `while` loops into resumable states
- The Huffman decode hot loop stays tight — suspension only happens at block boundaries and when the bit buffer is truly empty (rare mid-block for reasonably-sized input chunks)
- Test with existing golden files

### Phase 3: Deflater (1-2 days)
- Adapt `StreamingCompressor` to write to internal `Buffer` instead of `@stream.Writer`
- Adapt `BufferedBitWriter` similarly
- `deflater.mbt` — state machine wrapping encode/finish
- Simpler than Inflater since compression is naturally chunked (fill window → emit block)

### Phase 4: Convenience + Migration (0.5 day)
- `convenience.mbt` — `decompress()`, `compress()` one-shot wrappers
- Migrate gzip/ and zlib/ to use `@flate2.Inflater`/`Deflater`
- Update or remove `flate/`, `stream/`, L2 async adapters

### Phase 5: Testing + Benchmarks (0.5 day)
- Full golden-file round-trip tests
- Cross-validation with Go
- Benchmark comparison against current flate/ to verify no regression
- The hot loops are identical; the overhead is one enum match per chunk boundary

## Key Invariants

1. **`decode()` never blocks.** It always returns immediately with a signal.
2. **`Data` chunks are bounded.** ≤32KB for decoder (window flush), ≤8KB for encoder (buffer flush).
3. **No allocation on the hot path.** `Data(Bytes)` reuses the DictDecoder's window slice; the caller must consume before the next `decode()` call (documented borrow-invalidate, same as `@stream.Reader`).
4. **`src()` is cheap.** Just stores a reference; no copy. Old unconsumed input is an error (must be fully consumed before `Await` is returned, since the codec controls consumption rate).
5. **Error is terminal.** After `Error`, further `decode()`/`encode()` calls return `Error` again.
