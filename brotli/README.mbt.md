# Brotli

Pure MoonBit Brotli compression and decompression, following RFC 7932.

## One-shot API

```mbt check
test "brotli one-shot readme example" {
  let data = b"Brotli in pure MoonBit."
  let compressed = try! @brotli.compress(data)
  let restored = try! @brotli.decompress(compressed)
  assert_eq(restored, data)
}
```

## Streaming API

```mbt check
test "brotli streaming readme example" {
  let original = b"streaming brotli example"

  let deflater = @brotli.Deflater::new(level=BestCompression)
  let cbuf = @buffer.new()
  match deflater.encode(Some(original[:])) {
    Data(out) => cbuf.write_bytes(out)
    Ok | End | Error(_) => ()
  }
  loop deflater.encode(None) {
    Data(out) => {
      cbuf.write_bytes(out)
      continue deflater.encode(None)
    }
    End | Ok | Error(_) => break
  }

  let inflater = @brotli.Inflater::new()
  inflater.src(cbuf.to_bytes()[:])
  let dbuf = @buffer.new()
  loop inflater.decode() {
    Await => break
    Data(out) => {
      dbuf.write_bytes(out)
      continue inflater.decode()
    }
    End => break
    Error(e) => abort(e.to_string())
  }

  assert_eq(dbuf.to_bytes(), original)
}
```

## Quality Notes

- `NoCompression` emits uncompressed meta-blocks.
- `BestSpeed` and `Level(n)` emit compressed output for `n > 0`.
- `DefaultCompression` currently aliases `BestCompression`.
- The decoder is the more complete half of the package today; the encoder is correctness-first and currently improves most noticeably on long-run inputs at higher qualities.

## Generated Data

Static RFC and vendor-derived tables in this directory are generated, not hand-edited.

Regenerate them with:

```mbt nocheck
python3 tools/generate_brotli_data.py
```

Verify they are up to date with:

```mbt nocheck
python3 tools/generate_brotli_data.py --check
```
