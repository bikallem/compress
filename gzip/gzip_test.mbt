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
  let buf = @blit.Buffer::new(size_hint=1000)
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
fn gzip_hex_to_bytes(hex : String) -> Bytes {
  let len = hex.length() / 2
  Bytes::makei(len, fn(i) {
    let hi = gzip_hex_digit(hex[i * 2])
    let lo = gzip_hex_digit(hex[i * 2 + 1])
    ((hi << 4) | lo).to_byte()
  })
}

///|
fn gzip_named_header(name : String) -> @gzip.Header {
  { name, comment: "", extra: Bytes::default(), mod_time: 0U, os: b'\xFF' }
}

///|
fn gzip_with_fhcrc(data : Bytes) -> Bytes {
  let header = Bytes::makei(10, fn(i) {
    if i == 3 {
      (data[i].to_int() | 0x02).to_byte()
    } else {
      data[i]
    }
  })
  let hcrc = @checksum.crc32(header[:]) & 0xFFFFU
  let out = @blit.Buffer::new(size_hint=data.length() + 2)
  out.write_bytes(header)
  out.write_byte((hcrc & 0xFFU).to_byte())
  out.write_byte(((hcrc >> 8) & 0xFFU).to_byte())
  out.write_bytesview(data[10:])
  out.to_bytes()
}

///|
fn gzip_with_bad_fhcrc(data : Bytes) -> Bytes {
  let with_crc = gzip_with_fhcrc(data)
  Bytes::makei(with_crc.length(), fn(i) {
    if i == 10 {
      (with_crc[i].to_int() ^ 0xFF).to_byte()
    } else {
      with_crc[i]
    }
  })
}

///|
fn gzip_hex_digit(c : UInt16) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 87
  } else {
    0
  }
}

///|
test "golden: decompress Go-gzip hello" {
  let compressed = gzip_hex_to_bytes(
    "1f8b08000000000000fff248cdc9c9d75108cf2fca495104040000ffffd0c34aec0d000000",
  )
  let (decompressed, _header) = @gzip.decompress(compressed)
  assert_eq(decompressed, b"Hello, World!")
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
  let buf = @blit.Buffer::new(size_hint=compressed.length())
  for i in 0..<(compressed.length() - 8) {
    buf.write_byte(compressed[i])
  }
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  for i in (compressed.length() - 4)..<compressed.length() {
    buf.write_byte(compressed[i])
  }
  let corrupted = buf.to_bytes()
  let result = try? @gzip.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}

///|
test "gzip accepts valid FHCRC" {
  let data = b"header crc fixture"
  let compressed = gzip_with_fhcrc(@gzip.compress(data))
  let (decompressed, _header) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip rejects invalid FHCRC" {
  let data = b"header crc fixture"
  let compressed = gzip_with_bad_fhcrc(@gzip.compress(data))
  let result = try? @gzip.decompress(compressed)
  guard result is Err(_) else { fail("expected error for bad header checksum") }
}

///|
test "gzip rejects reserved header flags" {
  let compressed = @gzip.compress(b"reserved flags")
  let corrupted = Bytes::makei(compressed.length(), fn(i) {
    if i == 3 {
      (compressed[i].to_int() | 0x20).to_byte()
    } else {
      compressed[i]
    }
  })
  let result = try? @gzip.decompress(corrupted)
  guard result is Err(_) else {
    fail("expected error for reserved gzip header flags")
  }
}

///|
test "gzip decompress concatenated members" {
  let first = @gzip.compress(
    b"first member",
    header=gzip_named_header("first.txt"),
  )
  let second = @gzip.compress(
    b"second member",
    header=gzip_named_header("second.txt"),
  )
  let (decompressed, header) = @gzip.decompress(first + second)
  assert_eq(decompressed, b"first membersecond member")
  assert_eq(header.name, "second.txt")
}

///|
test "gzip decompress_members returns per-member headers" {
  let first = @gzip.compress(
    b"first member",
    header=gzip_named_header("first.txt"),
  )
  let second = @gzip.compress(
    b"second member",
    header=gzip_named_header("second.txt"),
  )
  let (decompressed, headers) = @gzip.decompress_members(first + second)
  assert_eq(decompressed, b"first membersecond member")
  assert_eq(headers.length(), 2)
  assert_eq(headers[0].name, "first.txt")
  assert_eq(headers[1].name, "second.txt")
}

///|
test "gzip compression reduces size" {
  let buf = @blit.Buffer::new(size_hint=5000)
  for _ in 0..<5000 {
    buf.write_byte(b'x')
  }
  let data = buf.to_bytes()
  let compressed = @gzip.compress(data)
  assert_true(compressed.length() < 100)
}

///|
test "gzip round-trip single byte" {
  let data : Bytes = b"\x42"
  let compressed = @gzip.compress(data)
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip round-trip all 0xFF" {
  let data = Bytes::make(5000, b'\xFF')
  let compressed = @gzip.compress(data)
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip round-trip 32KB boundary" {
  let data = Bytes::makei(32768, fn(i) { (i % 256).to_byte() })
  let compressed = @gzip.compress(data)
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "gzip invalid method" {
  let data : Bytes = [
    0x1F, 0x8B, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let result = try? @gzip.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid method") }
}

///|
test "gzip size mismatch" {
  let data = b"test"
  let compressed = @gzip.compress(data)
  let buf = @blit.Buffer::new(size_hint=compressed.length())
  for i in 0..<(compressed.length() - 4) {
    buf.write_byte(compressed[i])
  }
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  buf.write_byte(b'\xFF')
  let corrupted = buf.to_bytes()
  let result = try? @gzip.decompress(corrupted)
  guard result is Err(_) else { fail("expected error for size mismatch") }
}

///|
test "gzip round-trip larger data" {
  let buf = @blit.Buffer::new(size_hint=10000)
  for i in 0..<10000 {
    buf.write_byte((i % 256).to_byte())
  }
  let data = buf.to_bytes()
  let compressed = @gzip.compress(data)
  assert_true(compressed.length() < data.length())
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, data)
}
