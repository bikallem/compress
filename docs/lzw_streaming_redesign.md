# LZW Streaming-First Redesign

## Problem

The current `lzw` package still materializes whole streams in memory in the two places that matter for large files:

- `lzw/compress.mbt` exposes `compress(data : Bytes, ...) -> Bytes`, so the batch API requires the full input and full compressed output in memory.
- `lzw/lzw_writer.mbt` buffers every input chunk into `buf : @buffer.Buffer` and only compresses on end-of-data.
- `lzw/lzw_reader.mbt` calls `@stream.read_all(self.source)` and then holds the entire decompressed output in `self.output`.

That means the current API shape is not suitable for a 50GB file unless the caller accepts 50GB-scale buffering.

## Goal

Make `lzw.compress()` a streaming transform:

- input is pulled from `@stream.Reader`
- compressed bytes are pushed directly to `@stream.Writer`
- the codec owns only LZW state, not an input or output buffering policy
- memory usage is constant with respect to file size

## Non-Goals

- No wire-format change.
- No change to GIF/TIFF/PDF bit ordering semantics.
- No hidden buffering inside `lzw`; if the caller wants buffered I/O, that belongs in the concrete `Reader` or `Writer` implementation.

## Recommended Public API

Make the stream-oriented function the primary API:

```moonbit
pub fn compress(
  src : &@stream.Reader,
  dst : &@stream.Writer,
  order : BitOrder,
  lit_width : Int,
  forward_eod? : Bool = true,
) -> Unit raise @stream.StreamError
```

Keep a bytes convenience wrapper outside the core path:

```moonbit
pub fn compress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError
```

`compress_bytes()` should be a thin adapter built from `@stream.BytesReader`, `@stream.BytesWriter`, and the streaming `compress()`.

Recommended symmetry on the read side:

```moonbit
pub fn decompress(
  src : &@stream.Reader,
  dst : &@stream.Writer,
  order : BitOrder,
  lit_width : Int,
  forward_eod? : Bool = true,
) -> Unit raise @stream.StreamError

pub fn decompress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError
```

If only compression is changed, large-file compression becomes constant-memory, but large-file decompression does not.

## Internal Design

Split the current `LzwCompressState` into a pure codec state machine plus thin adapters.

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
  scratch : FixedArray[Byte]
}
```

Notes:

- `table` is already fixed-size (`TABLE_SIZE = 16384`), so dictionary memory is constant.
- `saved_code`, `bits`, and `n_bits` are the only cross-chunk carry state needed.
- `scratch` is not an output buffer. It is only a reusable 1-byte view so the encoder can hand completed bytes to `Writer::write()` immediately.

### 2. Emit Bytes Directly to the Writer

Refactor `write_code()` so that it emits completed bytes as soon as they exist:

```moonbit
fn LzwEncoder::emit_byte(
  self : LzwEncoder,
  dst : &@stream.Writer,
  b : Byte,
) -> Unit raise @stream.StreamError {
  self.scratch[0] = b
  dst.write(self.scratch[:1])
}
```

`write_code()` keeps only the partial-byte residue in `bits`/`n_bits`; every complete byte is pushed immediately to `dst`.

That satisfies the design constraint that `compress()` itself does not choose a buffering strategy. If the caller wants fewer downstream writes, they should pass a buffered writer implementation.

### 3. Chunk Processing Becomes Stateless With Respect to Input Ownership

```moonbit
fn LzwEncoder::write_chunk(
  self : LzwEncoder,
  data : BytesView,
  dst : &@stream.Writer,
) -> Unit raise @stream.StreamError

fn LzwEncoder::finish(
  self : LzwEncoder,
  dst : &@stream.Writer,
  forward_eod : Bool,
) -> Unit raise @stream.StreamError
```

`write_chunk()` is almost the same algorithm as the existing `LzwCompressState::write()`:

- on the first non-empty chunk, emit `clear`
- update `saved_code` across chunk boundaries
- probe/insert into the fixed dictionary
- emit codes as phrases close
- never keep ownership of the caller's `BytesView`

`finish()`:

- emits the last pending code if present
- emits `eof`
- flushes the final partial byte
- optionally forwards the empty end-of-data marker to `dst`

### 4. `compress()` Is Just a Reader/Writer Loop

The top-level streaming function becomes a simple transform driver:

```moonbit
pub fn compress(...) -> Unit raise @stream.StreamError {
  validate_lit_width_or_raise_format(...)
  let encoder = LzwEncoder::new(order, lit_width)
  while true {
    let chunk = src.read()
    if chunk.is_empty() {
      encoder.finish(dst, forward_eod)
      break
    }
    encoder.write_chunk(chunk, dst)
  }
}
```

This is the right ownership boundary:

- `Reader` decides how much input to expose per read
- `Writer` decides whether and how to buffer output
- `lzw.compress()` only performs codec translation

## Adapter Types After The Redesign

### `LzwStreamWriter`

Keep it as a convenience adapter, but make it a thin wrapper over `LzwEncoder`.

```moonbit
pub struct LzwStreamWriter {
  priv dest : &@stream.Writer
  priv encoder : LzwEncoder
  priv forward_eod : Bool
  priv mut closed : Bool
}
```

Behavior:

- non-empty `write(data)` calls `encoder.write_chunk(data, dest)`
- empty `write(b""[:])` calls `encoder.finish(dest, forward_eod)` once
- no `@buffer.Buffer`
- no delayed whole-stream compression
- no `slice_length` argument, because chunking is now the reader's concern and buffering is the writer's concern

### `compress_bytes()`

```moonbit
pub fn compress_bytes(...) -> Bytes raise LzwError {
  let reader = @stream.BytesReader::new(data)
  let writer = @stream.BytesWriter::new()
  compress(reader, writer, order, lit_width, forward_eod=false) catch {
    e => raise stream_error_to_lzw_error(e)
  }
  writer.content()
}
```

This preserves the simple API for tests and small in-memory use cases without making the bytes path the core implementation.

## Why This Is Constant-Memory

For compression, heap use is bounded by:

- dictionary/hash table: `TABLE_SIZE * sizeof(UInt)`
- encoder scalar state: `width`, `hi`, `saved_code`, `bits`, `n_bits`
- 1-byte scratch view for `Writer::write()`

No term scales with input size.

The current code already proves the algorithm does not need the whole input: it only needs the current phrase (`saved_code`) and the fixed dictionary. The existing `@buffer.Buffer` is an API artifact, not an algorithm requirement.

## Important Performance Consequence

This redesign removes buffering from `lzw.compress()` on purpose. That means performance depends on the destination writer:

- a buffered/file writer can batch writes efficiently
- an unbuffered writer may see many small writes

That is acceptable because it places buffering in the correct layer. If performance is poor with a concrete sink, add a generic buffered writer wrapper in `stream`, not a hidden output buffer inside `lzw`.

## Error Model

Recommended split:

- internal codec state machine keeps `LzwError`
- streaming surfaces (`compress`, `decompress`, stream adapters) expose `@stream.StreamError`, mapping codec failures to `StreamError::Format`
- bytes convenience wrappers keep `LzwError`

This matches the existing stream wrappers in the repo and avoids introducing a second streaming error hierarchy unless there is a strong need for typed format errors.

## Migration Plan

1. Add `LzwEncoder` and move the current compression logic into `write_chunk()` and `finish()`.
2. Change `LzwStreamWriter` to own `LzwEncoder` instead of `@buffer.Buffer`.
3. Introduce streaming `compress(src, dst, ...)` as the new primary entrypoint.
4. Rename the current bytes API to `compress_bytes()`.
5. Update examples, tests, benchmarks, and `pkg.generated.mbti`.
6. Apply the same pattern to decompression so `LzwReader` stops calling `@stream.read_all()`.

## Tests To Add Or Update

- compress round-trip with chunk boundaries at every byte position
- stream-to-stream compression using `FnReader` and `FnWriter`
- verify that `LzwStreamWriter` forwards output before end-of-data
- writer error propagation from the middle of code emission
- large generated input through `FnReader` to confirm flat memory use
- compatibility tests that compare `compress_bytes()` output with the streaming path over `BytesReader`/`BytesWriter`

## Recommendation

If the concrete goal is "compress a 50GB file without exhausting memory", the minimum acceptable change is:

- make compression streaming-first exactly as above
- do not keep any input or output `Buffer` in `lzw`
- leave output buffering to the destination `Writer`

If the goal is "compress and decompress 50GB files without exhausting memory", then `lzw/decompress` and `LzwReader` need the same redesign in the same milestone.
