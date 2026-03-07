///|
test "deflater/inflater round-trip" {
  let deflater = @sync.Deflater::new()
  deflater.update(b"Hello, ")
  deflater.update(b"World!")
  let compressed = deflater.finish()
  let inflater = @sync.Inflater::new()
  inflater.update(compressed)
  let decompressed = inflater.finish()
  assert_eq(decompressed, b"Hello, World!")
}

///|
test "deflater/inflater round-trip multi-chunk" {
  let deflater = @sync.Deflater::new()
  let chunks : Array[Bytes] = [
    b"The quick brown fox ", b"jumps over ", b"the lazy dog.",
  ]
  for chunk in chunks {
    deflater.update(chunk)
  }
  let compressed = deflater.finish()
  // Feed compressed data in two chunks
  let mid = compressed.length() / 2
  let inflater = @sync.Inflater::new()
  let chunk1 = @buffer.new(size_hint=mid)
  for i in 0..<mid {
    chunk1.write_byte(compressed[i])
  }
  inflater.update(chunk1.to_bytes())
  let chunk2 = @buffer.new(size_hint=compressed.length() - mid)
  for i in mid..<compressed.length() {
    chunk2.write_byte(compressed[i])
  }
  inflater.update(chunk2.to_bytes())
  let decompressed = inflater.finish()
  assert_eq(decompressed, b"The quick brown fox jumps over the lazy dog.")
}

///|
test "deflater/inflater empty" {
  let deflater = @sync.Deflater::new()
  let compressed = deflater.finish()
  let inflater = @sync.Inflater::new()
  inflater.update(compressed)
  let decompressed = inflater.finish()
  assert_eq(decompressed, b"")
}

///|
test "deflater/inflater all levels" {
  let data = b"ABCDEFGH"
  let levels : Array[@flate.CompressionLevel] = [
    NoCompression,
    BestSpeed,
    DefaultCompression,
    BestCompression,
  ]
  for level in levels {
    let deflater = @sync.Deflater::new(level~)
    deflater.update(data)
    let compressed = deflater.finish()
    let inflater = @sync.Inflater::new()
    inflater.update(compressed)
    let decompressed = inflater.finish()
    assert_eq(decompressed, data)
  }
}
