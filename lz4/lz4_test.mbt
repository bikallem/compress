///|
test "lz4 round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip empty" {
  let original : Bytes = b""
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip abcabc" {
  let original : Bytes = b"abcabcabcabc"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip larger text" {
  let sb = @buffer.new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
  // Repetitive data should compress
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "lz4 round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 invalid magic" {
  let data : Bytes = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid magic") }
}

///|
test "lz4 truncated data" {
  let data : Bytes = [0x04, 0x22, 0x4D, 0x18]
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "lz4 single byte" {
  let original : Bytes = b"X"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 frame header checksum" {
  // Compress, then corrupt the header checksum byte
  let original : Bytes = b"Hello, World!"
  let compressed = @lz4.compress(original)
  // The header checksum is the last byte before block data
  // For our frame: 4(magic) + 1(flg) + 1(bd) + 8(content_size) + 1(hc) = 15
  let corrupted = Bytes::makei(compressed.length(), fn(i) {
    if i == 14 {
      // corrupt header checksum
      (compressed[i].to_int() ^ 0xFF).to_byte()
    } else {
      compressed[i]
    }
  })
  let result = try? @lz4.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}
