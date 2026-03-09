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
async test "decompress empty LSB 8" {
  let compressed : Bytes = b"\x01\x01"
  let result = @lzw.decompress_bytes(compressed, @lzw.LSB, 8)
  inspect(result.length(), content="0")
}

///|
async test "decompress empty MSB 8" {
  let compressed : Bytes = b"\x80\x80"
  let result = @lzw.decompress_bytes(compressed, @lzw.MSB, 8)
  inspect(result.length(), content="0")
}

///|
async test "decompress Go vectors" {
  let tobe_lsb_7 : Bytes = b"\x54\x4f\x42\x45\x4f\x52\x4e\x4f\x54\x82\x84\x86\x8b\x85\x87\x89\x81"
  let tobe_lsb_8 : Bytes = b"\x54\x9e\x08\x29\xf2\x44\x8a\x93\x27\x54\x04\x12\x34\xb8\xb0\xe0\xc1\x84\x01\x01"
  let tobe_msb_7 : Bytes = b"\x54\x4f\x42\x45\x4f\x52\x4e\x4f\x54\x82\x84\x86\x8b\x85\x87\x89\x81"
  let tobe_msb_8 : Bytes = b"\x2a\x13\xc8\x44\x52\x79\x48\x9c\x4f\x2a\x40\xa0\x90\x68\x5c\x16\x0f\x09\x80\x80"
  let expected : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  assert_eq(@lzw.decompress_bytes(tobe_lsb_7, @lzw.LSB, 7), expected)
  assert_eq(@lzw.decompress_bytes(tobe_lsb_8, @lzw.LSB, 8), expected)
  assert_eq(@lzw.decompress_bytes(tobe_msb_7, @lzw.MSB, 7), expected)
  assert_eq(@lzw.decompress_bytes(tobe_msb_8, @lzw.MSB, 8), expected)
}

///|
async test "decompress gif and pdf vectors" {
  let gif : Bytes = b"\x00\x51\xfc\x1b\x28\x70\xa0\xc1\x83\x01\x01"
  let pdf : Bytes = b"\x80\x0b\x60\x50\x22\x0c\x0c\x85\x01"
  assert_eq(
    @lzw.decompress_bytes(gif, @lzw.LSB, 8),
    b"\x28\xff\xff\xff\x28\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
  )
  assert_eq(@lzw.decompress_bytes(pdf, @lzw.MSB, 8), b"-----A---B")
}

///|
async test "golden: decompress Go-lzw hello" {
  let compressed = lzw_hex_to_bytes("00919461c3e60d0b1057dec86143264440")
  let decompressed = @lzw.decompress_bytes(compressed, @lzw.LSB, 8)
  assert_eq(decompressed, b"Hello, World!")
}

///|
async test "round-trip LSB and MSB" {
  let original : Bytes = b"TOBEORNOTTOBEORTOBEORNOT"
  assert_eq(
    @lzw.decompress_bytes(
      @lzw.compress_bytes(original, @lzw.LSB, 8),
      @lzw.LSB,
      8,
    ),
    original,
  )
  assert_eq(
    @lzw.decompress_bytes(
      @lzw.compress_bytes(original, @lzw.MSB, 8),
      @lzw.MSB,
      8,
    ),
    original,
  )
}

///|
async test "round-trip edge cases" {
  assert_eq(
    @lzw.decompress_bytes(@lzw.compress_bytes(b"", @lzw.LSB, 8), @lzw.LSB, 8),
    b"",
  )
  assert_eq(
    @lzw.decompress_bytes(
      @lzw.compress_bytes(b"\x42", @lzw.LSB, 8),
      @lzw.LSB,
      8,
    ),
    b"\x42",
  )
  let zeros = Bytes::make(1000, b'\x00')
  assert_eq(
    @lzw.decompress_bytes(@lzw.compress_bytes(zeros, @lzw.LSB, 8), @lzw.LSB, 8),
    zeros,
  )
  let ff = Bytes::make(1000, b'\xFF')
  assert_eq(
    @lzw.decompress_bytes(@lzw.compress_bytes(ff, @lzw.LSB, 8), @lzw.LSB, 8),
    ff,
  )
}

///|
async test "round-trip all byte values and litWidth 2" {
  let all_bytes = Bytes::makei(256, fn(i) { i.to_byte() })
  assert_eq(
    @lzw.decompress_bytes(
      @lzw.compress_bytes(all_bytes, @lzw.LSB, 8),
      @lzw.LSB,
      8,
    ),
    all_bytes,
  )

  let buf = @buffer.new(size_hint=400)
  for _ in 0..<100 {
    buf.write_byte(b'\x00')
    buf.write_byte(b'\x01')
    buf.write_byte(b'\x02')
    buf.write_byte(b'\x03')
  }
  let small = buf.to_bytes()
  assert_eq(
    @lzw.decompress_bytes(@lzw.compress_bytes(small, @lzw.LSB, 2), @lzw.LSB, 2),
    small,
  )
}

///|
async test "invalid data raises" {
  let truncated = try? @lzw.decompress_bytes(
    b"\x54\x9e\x08\x29\xf2\x44\x8a\x93\x27\x54\x04",
    @lzw.LSB,
    8,
  )
  assert_true(truncated is Err(_))

  let invalid = try? @lzw.decompress_bytes(b"\xff\xff\xff\xff", @lzw.LSB, 8)
  assert_true(invalid is Err(_))

  let bad_lit_1 = try? @lzw.decompress_bytes(b"", @lzw.LSB, 1)
  let bad_lit_9 = try? @lzw.decompress_bytes(b"", @lzw.LSB, 9)
  assert_true(bad_lit_1 is Err(_))
  assert_true(bad_lit_9 is Err(_))
}
