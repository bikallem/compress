///|
test "bzip2 sync decompressor" {
  // bzip2-compressed "Hello"
  let compressed : Bytes = [
    0x42, 0x5A, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x1A, 0x54, 0x64,
    0x92, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x40, 0x02, 0x04, 0xA0, 0x00, 0x21,
    0x9A, 0x68, 0x33, 0x4D, 0x13, 0x33, 0x8B, 0xB9, 0x22, 0x9C, 0x28, 0x48, 0x0D,
    0x2A, 0x32, 0x49, 0x00,
  ]
  let decomp = @sync.Bzip2Decompressor::new()
  // Feed in two chunks
  let mid = compressed.length() / 2
  let chunk1 = @buffer.new(size_hint=mid)
  for i in 0..<mid {
    chunk1.write_byte(compressed[i])
  }
  decomp.update(chunk1.to_bytes())
  let chunk2 = @buffer.new(size_hint=compressed.length() - mid)
  for i in mid..<compressed.length() {
    chunk2.write_byte(compressed[i])
  }
  decomp.update(chunk2.to_bytes())
  let result = decomp.finish()
  assert_eq(result, b"Hello")
}
