///|
test "brotli round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip empty" {
  let original : Bytes = b""
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip larger text" {
  let sb = @buffer.new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli single byte" {
  let original : Bytes = b"X"
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli all zeros" {
  let original = Bytes::make(1000, b'\x00')
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli all 0xFF" {
  let original = Bytes::make(1000, b'\xFF')
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli level 0 (no compression)" {
  let original : Bytes = b"Hello, level 0!"
  let compressed = @brotli.compress(original, level=Level(0))
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli default level" {
  let original : Bytes = b"Hello, default level!"
  let compressed = @brotli.compress(original, level=Default)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli best level" {
  let original : Bytes = b"Hello, best level!"
  let compressed = @brotli.compress(original, level=Best)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}
