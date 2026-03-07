///|
test "inflate empty" {
  // Raw deflate of empty data: single empty stored block
  let compressed : Bytes = b"\x03\x00"
  let result = @flate.decompress(compressed)
  inspect(result.length(), content="0")
}

///|
test "inflate stored block" {
  // Raw deflate stored block of "Hello"
  let compressed : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate fixed huffman" {
  // Raw deflate fixed Huffman of "Hello"
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\x07\x00"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate dynamic huffman" {
  // Raw deflate of "Hello, World!" with default level
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello, World!"
  inspect(result == expected, content="true")
}

///|
test "inflate corrupt input" {
  let result = try? @flate.decompress(b"\xFF\xFF")
  inspect(result is Err(_), content="true")
}

///|
test "inflate truncated input" {
  let result = try? @flate.decompress(b"\xf3\x48")
  inspect(result is Err(_), content="true")
}

///|
test "inflate invalid block type 3" {
  // BFINAL=1, BTYPE=11 (invalid)
  let result = try? @flate.decompress(b"\x07")
  inspect(result is Err(_), content="true")
}

///|
test "inflate stored block bad nlen" {
  // Stored block: BFINAL=1, BTYPE=00, LEN=5, NLEN=wrong
  let result = try? @flate.decompress(
    b"\x01\x05\x00\x00\x00\x48\x65\x6c\x6c\x6f",
  )
  inspect(result is Err(_), content="true")
}

///|
test "inflate single byte input" {
  let original : Bytes = b"\x42"
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "inflate all 0xFF bytes" {
  let original = Bytes::make(1000, b'\xFF')
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "inflate 32KB boundary" {
  // Test data that exactly fills the 32KB sliding window
  let size = 32768
  let original = Bytes::makei(size, fn(i) { (i % 256).to_byte() })
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed.length(), size)
  assert_eq(decompressed, original)
}

///|
test "inflate just over 32KB" {
  let size = 32769
  let original = Bytes::makei(size, fn(i) { (i % 256).to_byte() })
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "inflate highly compressible data" {
  // Single byte repeated many times — tests run-length encoding path
  let original = Bytes::make(50000, b'A')
  let compressed = @flate.compress(original)
  assert_true(compressed.length() < 200)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "inflate empty stored block" {
  // Stored block with LEN=0
  let compressed : Bytes = b"\x01\x00\x00\xff\xff"
  let result = @flate.decompress(compressed)
  assert_eq(result.length(), 0)
}

///|
test "inflate 256 byte values" {
  // All possible byte values
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "inflate two-byte repeating pattern" {
  let buf = @buffer.new(size_hint=10000)
  for _ in 0..<5000 {
    buf.write_byte(b'\xAA')
    buf.write_byte(b'\x55')
  }
  let original = buf.to_bytes()
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}
