///|
test "snappy round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "snappy round-trip empty" {
  let original : Bytes = b""
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "snappy round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "snappy round-trip abcabc" {
  let original : Bytes = b"abcabcabcabc"
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "snappy round-trip larger text" {
  let sb = @blit.Buffer::new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
  // Repetitive data should compress
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "snappy round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "snappy invalid data" {
  // Invalid varint followed by garbage
  let data : Bytes = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
  let result = try? @snappy.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid data") }
}

///|
test "snappy truncated data" {
  // Valid varint saying 100 bytes, but no actual data
  let data : Bytes = [0x64]
  let result = try? @snappy.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "snappy rejects trailing bytes after payload" {
  let compressed = @snappy.compress(b"hello")
  let trailing = compressed + b"\x00"
  let result = try? @snappy.decompress(trailing)
  guard result is Err(_) else { fail("expected error for trailing bytes") }
}

///|
test "snappy rejects trailing bytes after empty stream" {
  let compressed = @snappy.compress(b"")
  let trailing = compressed + b"\x00"
  let result = try? @snappy.decompress(trailing)
  guard result is Err(_) else { fail("expected error for trailing bytes") }
}

///|
test "snappy single byte" {
  let original : Bytes = b"X"
  let compressed = @snappy.compress(original)
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, original)
}
