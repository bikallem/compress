///|
test "lzw sync round-trip LSB" {
  let comp = @sync.LzwCompressor::new(@lzw.LSB, 8)
  comp.update(b"TOBEORNOT")
  comp.update(b"TOBEORNOT")
  let compressed = comp.finish()
  let decomp = @sync.LzwDecompressor::new(@lzw.LSB, 8)
  decomp.update(compressed)
  let result = decomp.finish()
  assert_eq(result, b"TOBEORNOTTOBEORNOT")
}

///|
test "lzw sync round-trip MSB" {
  let comp = @sync.LzwCompressor::new(@lzw.MSB, 8)
  comp.update(b"Hello LZW")
  let compressed = comp.finish()
  let decomp = @sync.LzwDecompressor::new(@lzw.MSB, 8)
  decomp.update(compressed)
  let result = decomp.finish()
  assert_eq(result, b"Hello LZW")
}
