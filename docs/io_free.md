# Porting Go `compress` to MoonBit — Comprehensive Plan

## 1. Scope & Package Inventory

Go's `compress` contains 5 sub-packages (~5,500 LOC production, ~5,200 LOC tests):

| Package | LOC | Role | Dependencies | Compress? | Decompress? |
|---------|-----|------|-------------|-----------|-------------|
| `flate` | 3,205 | DEFLATE (RFC 1951) | none | yes | yes |
| `gzip` | 540 | gzip framing (RFC 1952) | flate | yes | yes |
| `zlib` | 374 | zlib framing (RFC 1950) | flate | yes | yes |
| `lzw` | 583 | LZW (GIF/TIFF/PDF) | none | yes | yes |
| `bzip2` | 869 | bzip2 decompression | none | no | yes |

## 2. Architecture: I/O-Free Design

Go's packages are tightly coupled to `io.Reader`/`io.Writer`. The MoonBit port **separates pure algorithms from I/O** using a layered approach:

### Layer 1: Pure Algorithms (core of each package)
```
// Bytes-in, Bytes-out — no streaming, no side effects
fn deflate_compress(input : Bytes, level~ : Int = 6) -> Bytes!CompressError
fn deflate_decompress(input : Bytes) -> Bytes!CompressError
```

### Layer 2: Incremental/Streaming (optional, for large data)
```
// State machine that processes chunks — still no I/O
struct DeflateCompressor { ... }  // holds sliding window, hash chains, etc.
fn DeflateCompressor::new(level~ : Int = 6) -> DeflateCompressor
fn DeflateCompressor::update(self : DeflateCompressor, chunk : Bytes) -> Bytes
fn DeflateCompressor::finish(self : DeflateCompressor) -> Bytes
```

### Why this works
- **Concurrency safe**: No globals, no shared mutable state. Each compressor/decompressor is an independent value.
- **Testable**: Pure functions are trivially testable with byte vectors.
- **Composable**: gzip/zlib just wrap flate output with headers + checksums — no I/O needed.
- **Functional where practical**: Huffman tree construction, CRC tables, BWT as pure functions. Internal state machines (sliding window, dictionary) use controlled mutability via structs with explicit state.

### I/O Boundary Decisions

| Go Concept | MoonBit Equivalent | Rationale |
|---|---|---|
| `io.Reader`/`io.Writer` | **Not ported** | I/O concern — caller's responsibility |
| `bufio.Reader` | **Not ported** | Buffering is I/O concern |
| `NewReader(io.Reader)` | `decompress(Bytes)` | Caller provides complete input |
| `NewWriter(io.Writer)` | `compress(Bytes)` | Returns complete output |
| `Reset()` for reuse | `::new()` fresh instance | Immutable-first; no pooling needed |
| `Flush()` | `update()` + `finish()` | Explicit state transitions |

## 3. MoonBit Module Structure

```
compress-claude/
├── moon.mod.json                    # module: "blem/compress"
├── lib/
│   ├── flate/
│   │   ├── moon.pkg.json
│   │   ├── types.mbt              # Error types, compression levels, tokens
│   │   ├── huffman.mbt            # Huffman tree construction & coding
│   │   ├── dict_decoder.mbt       # Sliding window / dictionary
│   │   ├── inflate.mbt            # DEFLATE decompression
│   │   ├── deflate.mbt            # DEFLATE compression
│   │   ├── deflate_fast.mbt       # Fast compression (level 1)
│   │   ├── huffman_bit_writer.mbt # Bit-level Huffman output
│   │   ├── compress.mbt           # Public API: compress/decompress
│   │   └── *_test.mbt             # Tests
│   ├── gzip/
│   │   ├── moon.pkg.json          # depends on: flate, checksum
│   │   ├── types.mbt              # Header struct, error types
│   │   ├── gunzip.mbt             # Decompression (header parsing + flate)
│   │   ├── gzip.mbt               # Compression (header writing + flate)
│   │   └── *_test.mbt
│   ├── zlib/
│   │   ├── moon.pkg.json          # depends on: flate, checksum
│   │   ├── types.mbt
│   │   ├── reader.mbt             # Decompression
│   │   ├── writer.mbt             # Compression
│   │   └── *_test.mbt
│   ├── lzw/
│   │   ├── moon.pkg.json
│   │   ├── types.mbt              # Order enum (LSB/MSB), error types
│   │   ├── compress.mbt           # LZW compression
│   │   ├── decompress.mbt         # LZW decompression
│   │   └── *_test.mbt
│   ├── bzip2/
│   │   ├── moon.pkg.json          # depends on: checksum
│   │   ├── types.mbt              # Error types
│   │   ├── bit_reader.mbt         # Bit-level reading from Bytes
│   │   ├── huffman.mbt            # Huffman tree for bzip2
│   │   ├── move_to_front.mbt      # MTF transform
│   │   ├── bwt.mbt               # Inverse BWT
│   │   ├── decompress.mbt         # Public API
│   │   └── *_test.mbt
│   └── checksum/
│       ├── moon.pkg.json
│       ├── crc32.mbt              # CRC-32 (for gzip)
│       ├── adler32.mbt            # Adler-32 (for zlib)
│       └── *_test.mbt
├── testdata/                       # Shared test fixtures
│   ├── e.txt
│   ├── gettysburg.txt
│   ├── pi.txt
│   └── golden/                    # Generated golden files (see parity)
└── vendor/go/                      # Go reference (already present)
```

### Key: `checksum` package
Go uses `hash/crc32` and `hash/adler32` from stdlib. We create a small `checksum` package since these are pure math — no external dependency needed.

## 4. Porting Order (Dependency-Driven)

```
Phase 1: Foundations (no inter-package deps)
  ├── 1a. checksum (crc32 + adler32) — small, high confidence, needed by gzip/zlib
  ├── 1b. lzw — independent, self-contained, good warmup (~583 LOC)
  └── 1c. bzip2 — independent, decompress-only (~869 LOC)

Phase 2: Core compression engine
  └── 2. flate — largest package (~3,205 LOC), critical path
       Port in sub-phases:
       2a. Types, constants, error types
       2b. Huffman coding (huffman_code.go → huffman.mbt)
       2c. Dictionary decoder (dict_decoder.go → dict_decoder.mbt)
       2d. Inflate/decompress (inflate.go → inflate.mbt)
       2e. Huffman bit writer (huffman_bit_writer.go)
       2f. Deflate/compress (deflate.go + deflatefast.go)
       2g. Public API + integration tests

Phase 3: Format wrappers
  ├── 3a. zlib — thin wrapper over flate + adler32 (~374 LOC)
  └── 3b. gzip — thin wrapper over flate + crc32 (~540 LOC)
```

## 5. Design Patterns & MoonBit Idioms

### Error Handling
```moonbit
// Tagged error type per package
type! CompressError {
  CorruptInput(String)      // Invalid compressed data
  InternalError(String)     // Bug in compressor
  InvalidLevel(Int)         // Bad compression level
  ChecksumMismatch(expected~: UInt, got~: UInt)
  InvalidHeader(String)
}
```

### Enums over Constants
```moonbit
// Go: const NoCompression = 0; const BestSpeed = 1; ...
// MoonBit: algebraic data type
enum CompressionLevel {
  NoCompression
  BestSpeed
  DefaultCompression
  BestCompression
  HuffmanOnly
  Level(Int)  // 1-9
}
```

### Immutable Where Possible, Controlled Mutation Where Necessary
```moonbit
// Huffman tree — naturally immutable (built once, read many)
enum HuffmanTree {
  Leaf(symbol~: UInt, code~: UInt, length~: Int)
  Node(left~: HuffmanTree, right~: HuffmanTree)
}

// Sliding window — requires mutation (perf-critical inner loop)
// Use struct with explicit owned state, no sharing
struct DictDecoder {
  buf : FixedArray[Byte]   // circular buffer
  mut wr_pos : Int
  mut rd_pos : Int
  mut full : Bool
}
```

### Bit Ordering (LZW)
```moonbit
// Go uses runtime if/else on Order; MoonBit uses enum dispatch
enum BitOrder { LSB; MSB }

// Pattern match instead of method pointers
fn read_code(self : LzwDecompressor) -> UInt!CompressError {
  match self.order {
    LSB => self.read_code_lsb!()
    MSB => self.read_code_msb!()
  }
}
```

### Container Type Selection
```
ReadOnlyArray[T]  — fixed size, immutable contents (lookup tables, precomputed constants)
FixedArray[T]     — fixed size, mutable contents (sliding windows, hash chains, circular buffers)
Array[T]          — growable, mutable (token accumulation, output collection)
```

```moonbit
// Static lookup table — ReadOnlyArray, computed once, never mutated
let crc32_table : ReadOnlyArray[UInt] = make_crc32_table()

// Compressor uses FixedArray for mutable fixed-size buffers
struct DeflateCompressor {
  window : FixedArray[Byte]       // 32KB sliding window — mutated in place
  hash_head : FixedArray[Int]     // hash lookup — mutated on each input byte
  hash_prev : FixedArray[Int]     // hash chains — mutated on each input byte
  tokens : Array[Token]           // growable — size varies per block
  pending : Buffer                // compressed output accumulator
  mut pos : Int
  mut block_start : Int
}
```

## 6. Parity Comparison Mechanism

### 6a. Golden File Testing
Generate golden test data using the vendored Go implementation:

```
tools/
  generate_golden.go    # Go program that:
    1. Reads testdata/*.txt
    2. Compresses with each algorithm at each level
    3. Writes golden compressed output to testdata/golden/
    4. Writes metadata JSON (sizes, checksums, params)
```

Golden files serve as **ground truth** — MoonBit decompressor must produce identical output from Go-compressed data, and Go decompressor must accept MoonBit-compressed data.

### 6b. Round-Trip Property Tests
```moonbit
test "flate round-trip" {
  let inputs = [b"", b"hello", read_testdata("gettysburg.txt"), random_bytes(65536)]
  for input in inputs {
    let compressed = @flate.compress!(input)
    let decompressed = @flate.decompress!(compressed)
    assert_eq!(decompressed, input)
  }
}
```

### 6c. Cross-Implementation Validation Script
A Go test harness that:
1. Reads MoonBit-compressed output files
2. Decompresses with Go stdlib
3. Compares to original input
4. Reports byte-level differences

```
tools/
  cross_validate.go     # Validates MoonBit output against Go decompressor
  cross_validate_test.go
```

### 6d. Parity Matrix

| Test Category | What it validates | Format |
|---|---|---|
| **Go→MoonBit decompress** | MoonBit decompresses Go-compressed golden files | Golden `.gz`/`.zlib`/`.lzw`/`.bz2` files |
| **MoonBit round-trip** | compress then decompress = identity | MoonBit unit tests |
| **MoonBit→Go decompress** | Go decompresses MoonBit-compressed output | Go test harness |
| **Edge cases** | Empty input, single byte, max block size, all-zeros, random | Both MoonBit + Go tests |
| **Error cases** | Truncated data, corrupt headers, bad checksums | MoonBit unit tests (ported from Go) |
| **Bit-exact output** | MoonBit compressed output = Go compressed output (same level) | Optional — not required for correctness |

### 6e. Test Data Categories (ported from Go)

| File | Purpose | Used by |
|---|---|---|
| `gettysburg.txt` | Short English text (1.5KB) | All packages |
| `e.txt` | Repetitive digits (100KB) | flate, gzip, zlib |
| `pi.txt` | Random-looking digits (100KB) | flate, gzip, zlib |
| `huffman-*.in` / `*.golden` | Huffman edge cases | flate |
| `*.bz2` + `*.bin` | bzip2 test vectors | bzip2 |
| Generated random data | Stress tests | All packages |

## 7. What NOT to Port

| Go Feature | Why Skip |
|---|---|
| `sync.Pool` / object reuse | MoonBit GC handles this; no pooling needed |
| `io.Reader`/`io.Writer` interfaces | I/O concern — out of scope |
| `bufio` wrapping | I/O concern |
| `Reset()` methods | Create fresh instances instead |
| Fuzz tests | MoonBit doesn't have fuzz infrastructure yet |
| `encoding/binary` usage | Replace with explicit byte manipulation |
| Example tests (`example_test.go`) | Go-specific doc format |

## 8. Risk & Complexity Assessment

| Package | Risk | Notes |
|---|---|---|
| checksum | Low | Pure math, well-defined, easy to validate |
| lzw | Low | Self-contained, moderate size, clear algorithm |
| bzip2 | Medium | BWT inverse is tricky; decompress-only simplifies it |
| flate | **High** | Largest package; LZ77 + Huffman + bit manipulation; most Go-isms to translate |
| gzip | Low | Thin wrapper once flate works |
| zlib | Low | Thin wrapper once flate works |

## 9. Success Criteria

1. **All Go test vectors pass** — every non-I/O test from the Go suite has a MoonBit equivalent that passes
2. **Cross-implementation round-trip** — Go can decompress MoonBit output; MoonBit can decompress Go output
3. **No global mutable state** — verified by code review
4. **Concurrency safe** — each compressor/decompressor is an independent value with no shared state
5. **`moon test` passes** — all MoonBit tests green
6. **`moon check` clean** — no warnings
