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
  let buf = @blit.Buffer::new(size_hint=1000)
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
  let buf = @blit.Buffer::new(size_hint=500)
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
test "golden: decompress Go-zlib-dict repeated 4k level6" {
  // Go compress/zlib NewWriterLevelDict level 6: "abcdefghijklmnop" * 256
  // dict = "the quick brown fox jumps over the lazy dog abcdefghijklmnop"
  let dict : Bytes = b"the quick brown fox jumps over the lazy dog abcdefghijklmnop"
  let compressed = zlib_hex_to_bytes(
    "78bba93516a2ecc7310d00000080a0feadede13861666666666666e6bf0b0000ffff100b885b",
  )
  let decompressed = @zlib.decompress(compressed, dict~)
  inspect(decompressed.length(), content="4096")
  let expected : Bytes = b"abcdefghijklmnop"
  let mut matches = true
  for i in 0..<16 {
    if decompressed[i] != expected[i] {
      matches = false
      break
    }
  }
  inspect(matches, content="true")
}

///|
test "zlib header validation - bad checksum" {
  let data : Bytes = [0x78, 0x9D, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
  let result = try? @zlib.decompress(data)
  guard result is Err(_) else { fail("expected error for bad header checksum") }
}

///|
test "zlib header validation - bad method" {
  let cmf = 0x74 // method=4, cinfo=7
  let remainder = cmf * 256 % 31
  let flg = if remainder == 0 { 0 } else { 31 - remainder }
  let buf = @blit.Buffer::new()
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
  let buf = @blit.Buffer::new(size_hint=compressed.length())
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
  let compressed = @zlib.compress(b"Hi")
  let cmf = compressed[0].to_int()
  let flg = compressed[1].to_int()
  assert_true((cmf * 256 + flg) % 31 == 0)
  assert_true((cmf & 0x0F) == 8)
  assert_true(((cmf >> 4) & 0x0F) <= 7)
}

///|
test "zlib round-trip larger data" {
  let buf = @blit.Buffer::new(size_hint=10000)
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
  let buf = @blit.Buffer::new(size_hint=5000)
  for _ in 0..<5000 {
    buf.write_byte(b'x')
  }
  let data = buf.to_bytes()
  let compressed = @zlib.compress(data)
  assert_true(compressed.length() < 100)
}
