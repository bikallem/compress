# Async I/O Architecture

## Purpose

This document records the high-level async I/O direction for the compression library.
It is intentionally short. It should capture cross-package architectural decisions,
not duplicate detailed codec redesign work.

For the concrete LZW migration plan, use:

- `docs/lzw_streaming_redesign.md`

## Scope

This document applies to the packages that need streaming support over native files,
pipes, sockets, and other async I/O sources:

- `flate`
- `gzip`
- `zlib`
- `lzw`
- `bzip2` where applicable

## Core Decisions

### 1. Target `moonbitlang/async/io` Directly

The streaming API should use `moonbitlang/async/io.Reader` and `moonbitlang/async/io.Writer`
directly.

Reasoning:

- `@fs.File` already implements those traits
- native file streaming should not require an extra adapter layer
- this matches the direction of Go-style streaming APIs more closely
- it avoids maintaining a second local I/O abstraction just for codec entrypoints

### 2. Use Thin Local In-Memory Helpers for `Bytes -> Bytes`

The runtime `moonbitlang/async/io` package in this repo does not provide built-in
`BytesReader` and `BytesWriter` helpers.

For convenience wrappers such as `compress_bytes(...)` and `decompress_bytes(...)`,
add thin local helpers under:

- `internal/bytes/bytes_reader.mbt`
- `internal/bytes/bytes_writer.mbt`

These helpers should:

- implement `moonbitlang/async/io.Reader` / `Writer`
- stay allocation-light
- be used by tests and convenience wrappers
- not become the main file-streaming boundary

### 3. Native File Streaming Uses `@fs.File`

For large-file compression and decompression, the intended path is:

- open the input with `@fs.open(...)`
- open the output with `@fs.create(...)` or `@fs.open(...)`
- pass those file handles directly to codec streaming entrypoints

That is the path that should satisfy the 50GB constant-memory requirement.

### 4. Buffering Policy Belongs Outside the Codec

Codec entrypoints should perform transformation only:

- read from `Reader`
- write to `Writer`
- keep only bounded codec state

They should not:

- materialize the whole input
- materialize the whole output
- hide a buffering policy inside the codec implementation

If a specific sink benefits from batching, the caller should pass a buffered runtime
writer such as `@io.BufferedWriter`.

### 5. Batch Convenience APIs Are Thin Wrappers

For codecs that expose both streaming and in-memory entrypoints, the intended layering is:

- streaming transform is the primary implementation
- `Bytes -> Bytes` wrapper is a thin adapter built on `internal/bytes`

Conceptually:

```moonbit
pub async fn compress(src : &@io.Reader, dst : &@io.Writer, ...) -> Unit raise Error
pub async fn decompress(src : &@io.Reader, dst : &@io.Writer, ...) -> Unit raise Error

pub async fn compress_bytes(data : Bytes, ...) -> Bytes raise Error
pub async fn decompress_bytes(data : Bytes, ...) -> Bytes raise Error
```

### 6. Remove Redundant Wrapper Types

If a codec already exposes a direct streaming transform like:

- `compress(src, dst, ...)`
- `decompress(src, dst, ...)`

then extra public wrapper types should not be kept unless they add real capability.

For LZW specifically, this means the redesign should remove:

- `LzwStreamWriter`
- `LzwReader`

### 7. Shrink or Delete the Repo-Local `io` Package After Migration

The repo-local `bikallem/compress/io` package is no longer the target abstraction for
streaming codec APIs.

After codecs are migrated to `moonbitlang/async/io` directly:

- delete the local `io` package if nothing still needs it, or
- reduce it to any remaining narrow use cases outside the codec streaming boundary

## Package-Level Direction

### `lzw`

- concrete redesign lives in `docs/lzw_streaming_redesign.md`
- primary target is direct `Reader` -> `Writer` streaming
- bytes wrappers use `internal/bytes`

### `flate`, `gzip`, `zlib`

- keep the same high-level layering
- streaming reader/writer APIs should target `moonbitlang/async/io`
- in-memory wrappers should also use `internal/bytes`

### `bzip2`

- follow the same direction wherever streaming entrypoints are introduced
- avoid creating a separate local I/O abstraction just for consistency with old code

## Module Layout Guidance

At a high level, the module should converge toward:

```text
internal/
  bytes/
    bytes_reader.mbt
    bytes_writer.mbt

flate/
gzip/
zlib/
lzw/
bzip2/
```

The important point is not the exact file tree. The important point is:

- shared in-memory async helpers live under `internal/bytes`
- codec packages target runtime async I/O directly
- large-file streaming uses runtime readers/writers directly

## Definition of Done for This Direction

The architecture is in the intended state when:

1. streaming codec entrypoints use `moonbitlang/async/io.Reader` / `Writer`
2. `Bytes -> Bytes` wrappers use thin helpers from `internal/bytes`
3. large-file native paths use `@fs.File` directly
4. codec implementations do not buffer full streams internally
5. obsolete duplicate abstractions and wrapper types are removed
