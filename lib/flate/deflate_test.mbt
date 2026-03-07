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

///|
fn hex_to_bytes(hex : String) -> Bytes {
  let len = hex.length() / 2
  Bytes::makei(len, fn(i) {
    let hi = hex_digit(hex[i * 2])
    let lo = hex_digit(hex[i * 2 + 1])
    ((hi << 4) | lo).to_byte()
  })
}

///|
fn hex_digit(c : UInt16) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 87
  } else {
    0
  }
}

///|
test "golden: decompress Go-deflate hello" {
  // Go compress/flate level 6: "Hello, World!"
  let compressed = hex_to_bytes("f248cdc9c9d75108cf2fca495104040000ffff")
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == b"Hello, World!", content="true")
}

///|
test "golden: decompress Go-deflate zeros 10k" {
  let compressed = hex_to_bytes(
    "ecc0010d000000c220fba736c7371800000000000000000090f3000000ffff",
  )
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed.length(), content="10240")
  // Verify all zeros
  let mut all_zero = true
  for i in 0..<decompressed.length() {
    if decompressed[i] != b'\x00' {
      all_zero = false
      break
    }
  }
  inspect(all_zero, content="true")
}

///|
test "golden: decompress Go-deflate repeated 4k" {
  // Go compress/flate level 6: "abcdefghijklmnop" * 256
  let compressed = hex_to_bytes(
    "ecc735110031000030ad0f65f43fd5472f639ef7fb434cb9d4d6c75c9b99999999999999eff3090000ffff",
  )
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed.length(), content="4096")
  // Verify first 16 bytes match pattern
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
test "compress all levels round-trip" {
  let buf = @buffer.new(size_hint=2000)
  let pattern : Bytes = b"The quick brown fox jumps over the lazy dog. "
  for _ in 0..<40 {
    buf.write_bytes(pattern)
  }
  let original = buf.to_bytes()
  for lvl in 1..<=9 {
    let compressed = @flate.compress(original, level=Level(lvl))
    let decompressed = @flate.decompress(compressed)
    assert_true(
      decompressed == original,
      msg="roundtrip failed at level \{lvl}",
    )
  }
}
