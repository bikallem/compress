///|
test "gzip round-trip empty" {
  let data : Bytes = b""
  let compressed = @gzip.compress(data)
  let (decompressed, _header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip round-trip hello" {
  let data = b"Hello, World!"
  let compressed = @gzip.compress(data)
  let (decompressed, _header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip round-trip repeated data" {
  let buf = @buffer.new(size_hint=1000)
  for i in 0..<1000 {
    buf.write_byte((i % 256).to_byte())
  }
  let data = buf.to_bytes()
  let compressed = @gzip.compress(data)
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip round-trip all compression levels" {
  let data = b"The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
  let levels : Array[@flate.CompressionLevel] = [
    NoCompression,
    BestSpeed,
    Level(5),
    DefaultCompression,
    BestCompression,
  ]
  for level in levels {
    let compressed = @gzip.compress(data, level~)
    let (decompressed, _) = @gzip.decompress(compressed)
    assert_eq(decompressed, data)
  }
}

///|
test "gzip header with name" {
  let data = b"test data"
  let header = @gzip.Header::{
    name: "test.txt",
    comment: "",
    extra: Bytes::default(),
    mod_time: 0U,
    os: b'\xFF',
  }
  let compressed = @gzip.compress(data, header~)
  let (decompressed, got_header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
  assert_eq(got_header.name, "test.txt")
}

///|
test "gzip header with comment" {
  let data = b"test data"
  let header = @gzip.Header::{
    name: "",
    comment: "this is a comment",
    extra: Bytes::default(),
    mod_time: 0U,
    os: b'\xFF',
  }
  let compressed = @gzip.compress(data, header~)
  let (decompressed, got_header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
  assert_eq(got_header.comment, "this is a comment")
}

///|
test "gzip header with extra" {
  let data = b"test data"
  let extra : Bytes = [0x01, 0x02, 0x03, 0x04]
  let header = @gzip.Header::{
    name: "",
    comment: "",
    extra,
    mod_time: 0U,
    os: b'\xFF',
  }
  let compressed = @gzip.compress(data, header~)
  let (decompressed, got_header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
  assert_eq(got_header.extra, extra)
}

///|
test "gzip header with name and comment" {
  let data = b"hello gzip"
  let header = @gzip.Header::{
    name: "hello.txt",
    comment: "greeting file",
    extra: Bytes::default(),
    mod_time: 1234567890U,
    os: b'\x03',
  }
  let compressed = @gzip.compress(data, header~)
  let (decompressed, got_header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
  assert_eq(got_header.name, "hello.txt")
  assert_eq(got_header.comment, "greeting file")
  assert_eq(got_header.mod_time, 1234567890U)
  assert_eq(got_header.os, b'\x03')
}

///|
test "gzip invalid magic" {
  let data : Bytes = [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let result = try? @gzip.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid magic") }
}

///|
test "gzip too short" {
  let data : Bytes = [0x1F, 0x8B, 0x08]
  let result = try? @gzip.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "gzip checksum mismatch" {
  let data = b"test"
  let compressed = @gzip.compress(data)
  // Corrupt CRC-32 in footer (last 8 bytes: 4 CRC + 4 ISIZE)
  let buf = @buffer.new(size_hint=compressed.length())
  for i in 0..<(compressed.length() - 8) {
    buf.write_byte(compressed[i])
  }
  // Write corrupted CRC
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  // Keep original ISIZE
  for i in (compressed.length() - 4)..<compressed.length() {
    buf.write_byte(compressed[i])
  }
  let corrupted = buf.to_bytes()
  let result = try? @gzip.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}

///|
test "gzip compression reduces size" {
  let buf = @buffer.new(size_hint=5000)
  for _ in 0..<5000 {
    buf.write_byte(b'x')
  }
  let data = buf.to_bytes()
  let compressed = @gzip.compress(data)
  // 5000 bytes of 'x' should compress well (gzip header ~18 bytes overhead)
  assert_true(compressed.length() < 100)
}

///|
test "gzip round-trip larger data" {
  let buf = @buffer.new(size_hint=10000)
  for i in 0..<10000 {
    buf.write_byte((i % 256).to_byte())
  }
  let data = buf.to_bytes()
  let compressed = @gzip.compress(data)
  assert_true(compressed.length() < data.length())
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}
