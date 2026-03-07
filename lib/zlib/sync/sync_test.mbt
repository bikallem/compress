///|
test "zlib sync round-trip" {
  let comp = @sync.ZlibCompressor::new()
  comp.update(b"Hello, ")
  comp.update(b"World!")
  let compressed = comp.finish()
  let decomp = @sync.ZlibDecompressor::new()
  decomp.update(compressed)
  let result = decomp.finish()
  assert_eq(result, b"Hello, World!")
}

///|
test "zlib sync empty" {
  let comp = @sync.ZlibCompressor::new()
  let compressed = comp.finish()
  let decomp = @sync.ZlibDecompressor::new()
  decomp.update(compressed)
  let result = decomp.finish()
  assert_eq(result, b"")
}
