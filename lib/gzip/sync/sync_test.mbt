///|
test "gzip sync round-trip" {
  let comp = @sync.GzipCompressor::new()
  comp.update(b"Hello, ")
  comp.update(b"World!")
  let compressed = comp.finish()
  let decomp = @sync.GzipDecompressor::new()
  decomp.update(compressed)
  let (result, _) = decomp.finish()
  assert_eq(result, b"Hello, World!")
}

///|
test "gzip sync empty" {
  let comp = @sync.GzipCompressor::new()
  let compressed = comp.finish()
  let decomp = @sync.GzipDecompressor::new()
  decomp.update(compressed)
  let (result, _) = decomp.finish()
  assert_eq(result, b"")
}
