///|
test "compress empty" {
  let result = @flate.compress(b"")
  let decompressed = @flate.decompress(result)
  inspect(decompressed.length(), content="0")
}

///|
test "compress hello" {
  let original : Bytes = b"Hello, World!"
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
}

///|
test "compress stored (NoCompression)" {
  let original : Bytes = b"Hello, World!"
  let compressed = @flate.compress(original, level=NoCompression)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
  // Stored should be larger than original (5-byte header per block)
  inspect(compressed.length() > original.length(), content="true")
}

///|
test "compress round-trip repeated data" {
  let buf = @buffer.new(size_hint=5000)
  let pattern : Bytes = b"The quick brown fox jumps over the lazy dog. "
  for _ in 0..<100 {
    buf.write_bytes(pattern)
  }
  let original = buf.to_bytes()
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
  // Should achieve actual compression on repeated data
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "compress round-trip all zeros" {
  let original = Bytes::make(10000, b'\x00')
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "compress round-trip single byte" {
  let original : Bytes = b"\x42"
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip binary data" {
  let buf = @buffer.new(size_hint=256)
  for i in 0..<256 {
    buf.write_byte(i.to_byte())
  }
  let original = buf.to_bytes()
  let compressed = @flate.compress(original)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
}

///|
test "compress BestSpeed" {
  let original : Bytes = b"Hello, World! Hello, World! Hello, World!"
  let compressed = @flate.compress(original, level=BestSpeed)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
}

///|
test "compress BestCompression" {
  let original : Bytes = b"Hello, World! Hello, World! Hello, World!"
  let compressed = @flate.compress(original, level=BestCompression)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
}

///|
test "compress HuffmanOnly" {
  let original : Bytes = b"Hello, World! Hello, World! Hello, World!"
  let compressed = @flate.compress(original, level=HuffmanOnly)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == original, content="true")
}

///|
test "compress invalid level" {
  let result = try? @flate.compress(b"test", level=Level(10))
  inspect(result is Err(_), content="true")
}
