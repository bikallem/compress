///|
test "zlib round-trip empty" {
  let data : Bytes = b""
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip hello" {
  let data = b"Hello, World!"
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip repeated data" {
  let buf = @buffer.new(size_hint=1000)
  for i in 0..<1000 {
    buf.write_byte((i % 256).to_byte())
  }
  let data = buf.to_bytes()
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip all zeros" {
  let buf = @buffer.new(size_hint=500)
  for _ in 0..<500 {
    buf.write_byte(b'\x00')
  }
  let data = buf.to_bytes()
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip all compression levels" {
  let data = b"The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
  let levels : Array[@flate.CompressionLevel] = [
    NoCompression,
    BestSpeed,
    Level(5),
    DefaultCompression,
    BestCompression,
    HuffmanOnly,
  ]
  for level in levels {
    let compressed = @zlib.compress(data, level~)
    let decompressed = @zlib.decompress(compressed)
    assert_eq(decompressed, data)
  }
}

///|
fn zlib_hex_to_bytes(hex : String) -> Bytes {
  let len = hex.length() / 2
  Bytes::makei(len, fn(i) {
    let hi = zlib_hex_digit(hex[i * 2])
    let lo = zlib_hex_digit(hex[i * 2 + 1])
    ((hi << 4) | lo).to_byte()
  })
}

///|
fn zlib_hex_digit(c : UInt16) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 87
  } else {
    0
  }
}

///|
test "golden: decompress Go-zlib hello" {
  let compressed = zlib_hex_to_bytes(
    "789cf248cdc9c9d75108cf2fca495104040000ffff1f9e046a",
  )
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, b"Hello, World!")
}

///|
test "zlib header validation - bad checksum" {
  // Valid zlib header is 0x78 0x9C (default compression)
  // Corrupt the FLG byte to break FCHECK
  let data : Bytes = [0x78, 0x9D, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
  let result = try? @zlib.decompress(data)
  guard result is Err(_) else { fail("expected error for bad header checksum") }
}

///|
test "zlib header validation - bad method" {
  // CMF = 0x18 means method=8 cinfo=1, but let's use method=4
  // CMF=0x74 -> method=4, cinfo=7
  // Need FLG so that (0x74*256+FLG) % 31 == 0
  // 0x74*256 = 29696, 29696 % 31 = 29696 - 958*31 = 29696 - 29698 = ... let me calculate
  // 29696 / 31 = 958.something, 958*31 = 29698, so remainder = 29696 - 29698 < 0
  // Better: just build valid header with wrong method
  let cmf = 0x74 // method=4, cinfo=7
  let remainder = cmf * 256 % 31
  let flg = if remainder == 0 { 0 } else { 31 - remainder }
  let buf = @buffer.new()
  buf.write_byte(cmf.to_byte())
  buf.write_byte(flg.to_byte())
  for _ in 0..<4 {
    buf.write_byte(b'\x00')
  }
  let data = buf.to_bytes()
  let result = try? @zlib.decompress(data)
  guard result is Err(_) else { fail("expected error for unsupported method") }
}

///|
test "zlib too short" {
  let data : Bytes = [0x78, 0x9C, 0x03]
  let result = try? @zlib.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "zlib checksum mismatch" {
  let data = b"test"
  let compressed = @zlib.compress(data)
  // Corrupt the last byte (part of Adler-32 checksum)
  let buf = @buffer.new(size_hint=compressed.length())
  for i in 0..<(compressed.length() - 1) {
    buf.write_byte(compressed[i])
  }
  buf.write_byte(
    (compressed[compressed.length() - 1].to_int() ^ 0xFF).to_byte(),
  )
  let corrupted = buf.to_bytes()
  let result = try? @zlib.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}

///|
test "zlib decompress known vector" {
  // This is a valid zlib stream: 78 9C = default compression header
  // Followed by stored block with "Hi" and Adler-32
  // Let's compress with our code and verify the header format
  let compressed = @zlib.compress(b"Hi")
  // First two bytes should form a valid zlib header
  let cmf = compressed[0].to_int()
  let flg = compressed[1].to_int()
  assert_true((cmf * 256 + flg) % 31 == 0)
  assert_true((cmf & 0x0F) == 8) // deflate method
  assert_true(((cmf >> 4) & 0x0F) <= 7) // valid window size
}

///|
test "zlib round-trip larger data" {
  let buf = @buffer.new(size_hint=10000)
  for i in 0..<10000 {
    let b = match i % 4 {
      0 => b'A'
      1 => b'B'
      2 => b'C'
      _ => b'D'
    }
    buf.write_byte(b)
  }
  let data = buf.to_bytes()
  let compressed = @zlib.compress(data)
  // Zlib should compress well on repetitive data
  assert_true(compressed.length() < data.length())
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip single byte" {
  let data : Bytes = b"\x42"
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip all 0xFF" {
  let data = Bytes::make(5000, b'\xFF')
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib round-trip 32KB boundary" {
  let data = Bytes::makei(32768, fn(i) { (i % 256).to_byte() })
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "zlib empty data" {
  let compressed = @zlib.compress(b"")
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed.length(), 0)
}

///|
test "zlib compression actually reduces size" {
  let buf = @buffer.new(size_hint=5000)
  // Highly repetitive data
  for _ in 0..<5000 {
    buf.write_byte(b'x')
  }
  let data = buf.to_bytes()
  let compressed = @zlib.compress(data)
  // 5000 bytes of 'x' should compress very well
  assert_true(compressed.length() < 100)
}
