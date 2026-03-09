# LZW Streaming-First Redesign

## Problem

The current `lzw` package still materializes whole streams in memory in the two places that matter for large files:

- `lzw/compress.mbt` exposes `compress(data : Bytes, ...) -> Bytes`, so the batch API requires the full input and full compressed output in memory.
- `lzw/lzw_writer.mbt` buffers every input chunk into `buf : @buffer.Buffer` and only compresses on end-of-data.
- `lzw/lzw_reader.mbt` calls `read_all()` on its source and then holds the entire decompressed output in `self.output`.

That means the current API shape is not suitable for a 50GB file unless the caller accepts 50GB-scale buffering.

## Goal

Make both `lzw.compress()` and `lzw.decompress()` streaming transforms:

- input is pulled from `@io.Reader`
- output is pushed directly to `@io.Writer`
- the codec owns only LZW state, not an input or output buffering policy
- memory usage is constant with respect to file size
- neither direction materializes the full input or full output in memory

## Non-Goals

- No wire-format change.
- No change to GIF/TIFF/PDF bit ordering semantics.
- No hidden buffering inside `lzw`; if the caller wants buffered I/O, that belongs in the concrete `Reader` or `Writer` implementation.

## Recommended Public API

Make the stream-oriented function the primary API:

```moonbit
pub async fn compress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width : Int,
  forward_eod? : Bool = true,
) -> Unit raise LzwError
```

Keep a bytes convenience wrapper outside the core path:

```moonbit
pub async fn compress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError
```

`compress_bytes()` should be a thin adapter built from `@io.BytesReader`, `@io.BytesWriter`, and the streaming `compress()`.

Recommended symmetry on the read side:

```moonbit
pub async fn decompress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width : Int,
  forward_eod? : Bool = true,
) -> Unit raise LzwError

pub async fn decompress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError
```

If only compression is changed, large-file compression becomes constant-memory, but large-file decompression does not.

## No Public Reader/Writer Adapters

The redesign should remove `LzwStreamWriter` and `LzwReader` instead of preserving them as convenience shims.

Reasoning:

- `compress(src, dst, ...)` already is the streaming writer-side API.
- `decompress(src, dst, ...)` already is the streaming reader-side API.
- keeping `LzwStreamWriter` and `LzwReader` would duplicate the same transform in two extra public types with no new capability
- they also preserve an unnecessary public API surface that callers would need to learn and maintain

So the target public surface should be only:

- `compress(src, dst, ...)`
- `decompress(src, dst, ...)`
- `compress_bytes(...)`
- `decompress_bytes(...)`

If the package later needs reusable filter objects for composition, they can be introduced after a concrete use case appears. They should not be part of the redesign by default.

## Internal Design

Split the current LZW implementation into pure codec state machines plus direct function entrypoints for both encode and decode.

### 1. Encoder State Owns Only Codec State

Replace the current `buf : @buffer.Buffer` with only the minimum state required by LZW:

```moonbit
priv struct LzwEncoder {
  order : BitOrder
  lit_width : Int
  table : FixedArray[UInt]
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut saved_code : Int
  mut bits : UInt
  mut n_bits : Int
}
```

Notes:

- `table` is already fixed-size (`TABLE_SIZE = 16384`), so dictionary memory is constant.
- `saved_code`, `bits`, and `n_bits` are the only cross-chunk carry state needed.

### 2. Encoder Emits Bytes Directly via `write_byte()`

Refactor `write_code()` so that it emits completed bytes as soon as they exist:

```moonbit
async fn LzwEncoder::emit_byte(
  self : LzwEncoder,
  dst : &@io.Writer,
  b : Byte,
) -> Unit raise LzwError {
  dst.write_byte(b)
}
```

`write_code()` keeps only the partial-byte residue in `bits`/`n_bits`; every complete byte is pushed immediately to `dst`.

That satisfies the design constraint that `compress()` itself does not choose a buffering strategy. If the caller wants fewer downstream writes, they should pass a buffered writer implementation.

### 3. Encoder Processes One Input Byte At A Time

```moonbit
fn LzwEncoder::write_byte(
  self : LzwEncoder,
  b : Byte,
  dst : &@io.Writer,
) -> Unit raise LzwError

async fn LzwEncoder::finish(
  self : LzwEncoder,
  dst : &@io.Writer,
  forward_eod : Bool,
) -> Unit raise LzwError
```

`write_byte()` is almost the same algorithm as the existing `LzwCompressState::write()` once that loop is viewed as one byte at a time:

- on the first input byte, emit `clear`
- update `saved_code` across byte boundaries
- probe/insert into the fixed dictionary
- emit codes as phrases close
- never keep ownership of caller input beyond the current byte

`finish()`:

- emits the last pending code if present
- emits `eof`
- flushes the final partial byte
- optionally forwards the empty end-of-data marker to `dst`

### 4. `compress()` Is Just a Reader/Writer Loop

The top-level streaming function becomes a simple transform driver:

```moonbit
pub async fn compress(...) -> Unit raise LzwError {
  validate_lit_width_or_raise_format(...)
  let encoder = LzwEncoder::new(order, lit_width)
  loop {
    let b = src.read_byte() catch {
      ReaderClosed => break
    }
    encoder.write_byte(b, dst)
  }
  encoder.finish(dst, forward_eod)
}
```

This is the right ownership boundary:

- `Reader` decides how much input to expose per read
- `Writer` decides whether and how to buffer output
- `lzw.compress()` only performs codec translation

### 5. Decoder State Owns Only Codec State

`decompress()` should follow the same requirements as `compress()`:

- read compressed bytes directly from `src`
- write decoded bytes directly to `dst`
- keep only decoder tables, bit-reader residue, and bounded phrase/output scratch
- never call `read_all()`
- never accumulate the full decoded result before writing
- obtain compressed input bytes with `read_byte()` as the bit reader needs them

The decoder state can be derived from the current `LzwDecompressState`, but its output management needs to change:

```moonbit
priv struct LzwDecoder {
  lit_width : Int
  clear : Int
  eof : Int
  suffix : FixedArray[Byte]
  prefix : FixedArray[Int]
  output : FixedArray[Byte]
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut last : Int
  mut o : Int
  mut bits : UInt
  mut n_bits : Int
  mut finished : Bool
}
```

Notes:

- `suffix` and `prefix` are already fixed-size dictionary state, so they are constant-memory.
- `output` is bounded decoder scratch for phrase expansion and bulk writes, not a full decoded-output buffer.
- `bits` and `n_bits` are the only bit-reader carry state that must survive chunk boundaries.
- there should be no `Bytes`, `Buffer`, or chunk list owned by the decoder for whole-stream accumulation.

### 6. Decoder Emits Decoded Bytes Directly to the Writer

The current decompressor already uses a bounded `output` scratch array while decoding codes. The redesign should keep that pattern but flush it directly to `dst` instead of appending into an owning `OutputBuffer`.

Conceptually:

```moonbit
async fn LzwDecoder::flush_output(
  self : LzwDecoder,
  dst : &@io.Writer,
) -> Unit raise LzwError
```

When `self.o > 0`, `flush_output()` writes `self.output[:self.o]` to `dst` and resets `self.o` to `0`.

That gives decompression the same boundary as compression:

- `lzw.decompress()` does not choose a persistent buffering strategy
- the destination writer decides whether to batch, buffer, or forward immediately
- codec memory stays bounded regardless of decoded size

### 7. Decoder Reads Compressed Input With `read_byte()`

The decoder needs one extra detail that compression does not: partial codes may straddle byte boundaries. So the decoder should own a bit reader that pulls compressed bytes from `src.read_byte()` and carries only `bits` and `n_bits` between code reads.

Recommended shape:

```moonbit
async fn LzwDecoder::read_code(
  self : LzwDecoder,
  src : &@io.Reader,
) -> Int raise LzwError

async fn LzwDecoder::run(
  self : LzwDecoder,
  src : &@io.Reader,
  dst : &@io.Writer,
  forward_eod : Bool,
) -> Unit raise LzwError
```

`read_code()`:

- calls `src.read_byte()` until enough bits are available for the next code
- preserves any partial-code residue in `bits`/`n_bits` between calls
- raises `UnexpectedEOF` if the compressed stream ends before enough bits exist for a required code

`run()`:

- repeatedly calls `read_code()`
- feeds the existing code-processing logic
- flushes bounded decoded output to `dst` as scratch fills
- verifies that the decoder reached `eof`
- flushes any remaining decoded bytes
- optionally forwards the empty end-of-data marker to `dst`

### 8. `decompress()` Is Also Just a Reader/Writer Loop

```moonbit
pub async fn decompress(...) -> Unit raise LzwError {
  validate_lit_width_or_raise_format(...)
  let decoder = LzwDecoder::new(order, lit_width)
  decoder.run(src, dst, forward_eod)
}
```

This is the same ownership model as `compress()`:

- `Reader` controls input chunking
- `Writer` controls output buffering
- `lzw.decompress()` is only the codec transform
- memory stays bounded by decoder tables and scratch buffers, not stream size

## Bytes Convenience Wrappers

### `compress_bytes()`

```moonbit
pub async fn compress_bytes(...) -> Bytes raise LzwError {
  let reader = @io.BytesReader::new(data)
  let writer = @io.BytesWriter::new()
  compress(reader, writer, order, lit_width, forward_eod=false)
  writer.to_bytes()
}
```

This preserves the simple API for tests and small in-memory use cases without making the bytes path the core implementation.

### `decompress_bytes()`

```moonbit
pub async fn decompress_bytes(...) -> Bytes raise LzwError {
  let reader = @io.BytesReader::new(data)
  let writer = @io.BytesWriter::new()
  decompress(reader, writer, order, lit_width, forward_eod=false)
  writer.to_bytes()
}
```

This should be the only place where decompression intentionally accumulates the full output in memory, because that is the explicit contract of the bytes convenience API.

## Why This Is Constant-Memory

For compression, heap use is bounded by:

- dictionary/hash table: `TABLE_SIZE * sizeof(UInt)`
- encoder scalar state: `width`, `hi`, `saved_code`, `bits`, `n_bits`

No term scales with input size.

For decompression, heap use is bounded by:

- decoder dictionary tables: `suffix`, `prefix`
- decoder scalar state: `width`, `hi`, `overflow`, `last`, `bits`, `n_bits`
- bounded decode/output scratch used to expand phrases before writing

Again, no term scales with the total input size or total decoded size.

The current code already proves the algorithm does not need the whole input: compression only needs the current phrase (`saved_code`) and the fixed dictionary; decompression only needs the decoder tables, bit residue, and bounded phrase scratch. The existing `@buffer.Buffer`, `read_all()`, whole-output accumulation, and one-byte wrapper scratch are API artifacts, not algorithm requirements.

## Important Performance Consequence

This redesign removes buffering policy from both `lzw.compress()` and `lzw.decompress()` on purpose. That means performance depends on the destination writer:

- a buffered/file writer can batch writes efficiently
- an unbuffered writer may see many small writes

That is acceptable because it places buffering in the correct layer. If performance is poor with a concrete sink, add a generic buffered writer wrapper in `stream`, not a hidden output buffer inside `lzw`.

## Error Model

Recommended split:

- internal codec state machine keeps `LzwError`
- async public surfaces (`compress`, `decompress`, `compress_bytes`, `decompress_bytes`) keep `LzwError`
- `@io` transport-level behavior follows the `io` package semantics of the chosen runtime

This keeps the LZW redesign focused on codec errors instead of reintroducing a separate sync `stream` error layer.

## Migration Plan

1. Add `LzwEncoder` and move the current compression logic into `write_byte()` and `finish()`.
2. Introduce streaming `compress(src, dst, ...)` as the new primary entrypoint.
3. Rename the current bytes API to `compress_bytes()`.
4. Add `LzwDecoder` and move the current decompression logic into `read_code()` and `run()`.
5. Introduce streaming `decompress(src, dst, ...)` and rename the current bytes API to `decompress_bytes()`.
6. Replace the current whole-output decompression path with direct writes to `dst`.
7. Delete `lzw/lzw_writer.mbt` and `lzw/lzw_reader.mbt` from the final API surface.
8. Update examples, tests, benchmarks, and `pkg.generated.mbti`.

## Tests To Add Or Update

- compress round-trip with chunk boundaries at every byte position
- end-to-end compression using `@io.Reader` / `@io.Writer` pairs
- verify that `compress(src, dst, ...)` produces output incrementally instead of waiting for full input materialization
- verify that encoder output uses `write_byte()` directly with no one-byte wrapper buffer
- decompress round-trip with compressed input split at every byte position
- end-to-end decompression using `@io.Reader` / `@io.Writer` pairs
- verify that `decompress(src, dst, ...)` forwards decoded bytes before end-of-input
- `read_byte()`-driven partial-code boundary tests for both `LSB` and `MSB`
- decompressor `UnexpectedEOF` behavior when the final code is truncated across chunk boundaries
- writer error propagation from the middle of code emission
- writer error propagation from the middle of decoded output flush
- large generated input through `FnReader` to confirm flat memory use
- compatibility tests that compare `compress_bytes()` and `decompress_bytes()` with the streaming paths over `@io.BytesReader` / `@io.BytesWriter`

## Recommendation

If the concrete goal is "compress a 50GB file without exhausting memory", the minimum acceptable change is:

- make compression streaming-first exactly as above
- do not keep any input or output `Buffer` in `lzw`
- leave output buffering to the destination `Writer`

If the goal is "compress and decompress a 50GB file without exhausting memory", then decompression must satisfy the same requirements in the same milestone:

- `decompress()` reads from `Reader`
- `decompress()` writes directly to `Writer`
- `decompress()` does not call `read_all()`
- `decompress()` does not accumulate decoded output internally
- decompressor memory remains bounded by dictionary and scratch state only
