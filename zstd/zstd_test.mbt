///|
test "zstd round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd round-trip empty" {
  let original : Bytes = b""
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd round-trip larger text" {
  let sb = @blit.Buffer::new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd invalid magic" {
  let data : Bytes = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
  let result = try? @zstd.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid magic") }
}

///|
test "zstd truncated data" {
  let data : Bytes = [0x28, 0xB5, 0x2F, 0xFD]
  let result = try? @zstd.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "zstd single byte" {
  let original : Bytes = b"X"
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd all zeros" {
  let original = Bytes::make(10000, b'\x00')
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
  // RLE should compress well
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "zstd all 0xFF" {
  let original = Bytes::make(10000, b'\xFF')
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "zstd compression ratio on repeated pattern" {
  // 4KB of "abcdefghijklmnop" repeated (256 times)
  let pattern = b"abcdefghijklmnop"
  let buf = @blit.Buffer::new()
  for _ in 0..<256 {
    buf.write_bytes(pattern)
  }
  let original = buf.to_bytes()
  let compressed = @zstd.compress(original)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, original)
  // Should achieve at least 2x compression
  inspect(compressed.length() * 2 < original.length(), content="true")
}

///|
test "zstd frame checksum" {
  let original : Bytes = b"Hello, World!"
  let compressed = @zstd.compress(original)
  // Corrupt the last byte (checksum)
  let corrupted = Bytes::makei(compressed.length(), fn(i) {
    if i == compressed.length() - 1 {
      (compressed[i].to_int() ^ 0xFF).to_byte()
    } else {
      compressed[i]
    }
  })
  let result = try? @zstd.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}

///|
test "golden: decompress zstd CLI hello" {
  let compressed : Bytes = b"\x28\xb5\x2f\xfd\x24\x0d\x69\x00\x00\x48\x65\x6c\x6c\x6f\x2c\x20\x57\x6f\x72\x6c\x64\x21\x7f\xe4\x0f\x08"
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, b"Hello, World!")
}

///|
test "golden: decompress zstd CLI repeated abc" {
  let compressed : Bytes = b"\x28\xb5\x2f\xfd\x24\x3c\x4d\x00\x00\x18\x61\x62\x63\x01\x00\xf6\x74\x43\x38\x4b\x20\x2f"
  let decompressed = @zstd.decompress(compressed)
  let expected = b"abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc"
  assert_eq(decompressed, expected)
}

///|
test "zstd reject unsupported sequence modes" {
  let compressed : Bytes = b"\x28\xb5\x2f\xfd\x24\x3c\x4d\x00\x00\x18\x61\x62\x63\x01\x01\xf6\x74\x43\x38\x4b\x20\x2f"
  let result = try? @zstd.decompress(compressed)
  guard result is Err(_) else {
    fail("expected error for unsupported sequence modes")
  }
}
