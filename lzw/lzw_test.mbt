///|
// Test vectors from Go compress/lzw reader_test.go

test "decompress empty LSB 8" {
  let compressed : Bytes = b"\x01\x01"
  let result = @lzw.decompress(compressed, LSB, 8)
  inspect(result.length(), content="0")
}

///|
test "decompress empty MSB 8" {
  let compressed : Bytes = b"\x80\x80"
  let result = @lzw.decompress(compressed, MSB, 8)
  inspect(result.length(), content="0")
}

///|
test "decompress tobe LSB 7" {
  let compressed : Bytes = b"\x54\x4f\x42\x45\x4f\x52\x4e\x4f\x54\x82\x84\x86\x8b\x85\x87\x89\x81"
  let result = @lzw.decompress(compressed, LSB, 7)
  let expected : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  inspect(result == expected, content="true")
}

///|
test "decompress tobe LSB 8" {
  let compressed : Bytes = b"\x54\x9e\x08\x29\xf2\x44\x8a\x93\x27\x54\x04\x12\x34\xb8\xb0\xe0\xc1\x84\x01\x01"
  let result = @lzw.decompress(compressed, LSB, 8)
  let expected : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  inspect(result == expected, content="true")
}

///|
test "decompress tobe MSB 7" {
  let compressed : Bytes = b"\x54\x4f\x42\x45\x4f\x52\x4e\x4f\x54\x82\x84\x86\x8b\x85\x87\x89\x81"
  let result = @lzw.decompress(compressed, MSB, 7)
  let expected : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  inspect(result == expected, content="true")
}

///|
test "decompress tobe MSB 8" {
  let compressed : Bytes = b"\x2a\x13\xc8\x44\x52\x79\x48\x9c\x4f\x2a\x40\xa0\x90\x68\x5c\x16\x0f\x09\x80\x80"
  let result = @lzw.decompress(compressed, MSB, 8)
  let expected : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  inspect(result == expected, content="true")
}

///|
test "decompress gif LSB 8" {
  let compressed : Bytes = b"\x00\x51\xfc\x1b\x28\x70\xa0\xc1\x83\x01\x01"
  let result = @lzw.decompress(compressed, LSB, 8)
  let expected : Bytes = b"\x28\xff\xff\xff\x28\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
  inspect(result == expected, content="true")
}

///|
test "decompress pdf MSB 8" {
  let compressed : Bytes = b"\x80\x0b\x60\x50\x22\x0c\x0c\x85\x01"
  let result = @lzw.decompress(compressed, MSB, 8)
  let expected : Bytes = b"-----A---B"
  inspect(result == expected, content="true")
}

///|
test "decompress truncated LSB 8 raises" {
  let compressed : Bytes = b"\x54\x9e\x08\x29\xf2\x44\x8a\x93\x27\x54\x04"
  let result = try? @lzw.decompress(compressed, LSB, 8)
  inspect(result is Err(_), content="true")
}

///|
test "invalid litWidth" {
  let result = try? @lzw.decompress(b"", LSB, 1)
  inspect(result is Err(_), content="true")
  let result2 = try? @lzw.decompress(b"", LSB, 9)
  inspect(result2 is Err(_), content="true")
}

///|
fn lzw_hex_to_bytes(hex : String) -> Bytes {
  let len = hex.length() / 2
  Bytes::makei(len, fn(i) {
    let hi = lzw_hex_digit(hex[i * 2])
    let lo = lzw_hex_digit(hex[i * 2 + 1])
    ((hi << 4) | lo).to_byte()
  })
}

///|
fn lzw_hex_digit(c : UInt16) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 87
  } else {
    0
  }
}

///|
test "golden: decompress Go-lzw hello" {
  // Go compress/lzw LSB litWidth=8: "Hello, World!"
  let compressed = lzw_hex_to_bytes("00919461c3e60d0b1057dec86143264440")
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  assert_eq(decompressed, b"Hello, World!")
}

///|
test "compress round-trip LSB 8" {
  let original : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip MSB 8" {
  let original : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  let compressed = @lzw.compress(original, MSB, 8)
  let decompressed = @lzw.decompress(compressed, MSB, 8)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip LSB 7" {
  // Only use values < 128 for litWidth 7
  let original : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  let compressed = @lzw.compress(original, LSB, 7)
  let decompressed = @lzw.decompress(compressed, LSB, 7)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip empty" {
  let original : Bytes = b""
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip single byte" {
  let original : Bytes = b"\x42"
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip all zeros" {
  let original = Bytes::make(1000, b'\x00')
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed == original, content="true")
  // Compression should actually reduce size for repetitive data
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "compress round-trip repeated pattern" {
  let pattern : Bytes = b"abcdefghij"
  let buf = @blit.Buffer::new(size_hint=1000)
  for _ in 0..<100 {
    buf.write_bytes(pattern)
  }
  let original = buf.to_bytes()
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip MSB 7" {
  let original : Bytes = b"ABCABCABCABCABC"
  let compressed = @lzw.compress(original, MSB, 7)
  let decompressed = @lzw.decompress(compressed, MSB, 7)
  inspect(decompressed == original, content="true")
}

///|
test "compress round-trip all byte values LSB 8" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  assert_eq(decompressed, original)
}

///|
test "compress round-trip large data MSB 8" {
  let original = Bytes::makei(5000, fn(i) { (i % 256).to_byte() })
  let compressed = @lzw.compress(original, MSB, 8)
  let decompressed = @lzw.decompress(compressed, MSB, 8)
  assert_eq(decompressed, original)
}

///|
test "compress round-trip litWidth 2 LSB" {
  // Only values 0-3 for litWidth 2
  let buf = @blit.Buffer::new(size_hint=100)
  for _ in 0..<100 {
    buf.write_byte(b'\x00')
    buf.write_byte(b'\x01')
    buf.write_byte(b'\x02')
    buf.write_byte(b'\x03')
  }
  let original = buf.to_bytes()
  let compressed = @lzw.compress(original, LSB, 2)
  let decompressed = @lzw.decompress(compressed, LSB, 2)
  assert_eq(decompressed, original)
}

///|
test "decompress invalid code" {
  // Craft input with an invalid code
  let result = try? @lzw.decompress(b"\xff\xff\xff\xff", LSB, 8)
  inspect(result is Err(_), content="true")
}

///|
test "compress round-trip all 0xFF LSB 8" {
  let original = Bytes::make(1000, b'\xFF')
  let compressed = @lzw.compress(original, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  assert_eq(decompressed, original)
  assert_true(compressed.length() < original.length())
}
