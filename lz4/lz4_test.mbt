///|
test "lz4 round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip empty" {
  let original : Bytes = b""
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip abcabc" {
  let original : Bytes = b"abcabcabcabc"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip larger text" {
  let sb = @blit.Buffer::new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
  // Repetitive data should compress
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "lz4 round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 invalid magic" {
  let data : Bytes = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid magic") }
}

///|
test "lz4 truncated data" {
  let data : Bytes = [0x04, 0x22, 0x4D, 0x18]
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "lz4 single byte" {
  let original : Bytes = b"X"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 frame header checksum" {
  // Compress, then corrupt the header checksum byte
  let original : Bytes = b"Hello, World!"
  let compressed = @lz4.compress(original)
  // The header checksum is the last byte before block data
  // For our frame: 4(magic) + 1(flg) + 1(bd) + 1(hc) = 7
  let corrupted = Bytes::makei(compressed.length(), fn(i) {
    if i == 6 {
      // corrupt header checksum
      (compressed[i].to_int() ^ 0xFF).to_byte()
    } else {
      compressed[i]
    }
  })
  let result = try? @lz4.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}

///|
fn lz4_write_u32_le(buf : @blit.Buffer, value : UInt) -> Unit {
  buf.write_byte((value & 0xFFU).to_byte())
  buf.write_byte(((value >> 8) & 0xFFU).to_byte())
  buf.write_byte(((value >> 16) & 0xFFU).to_byte())
  buf.write_byte(((value >> 24) & 0xFFU).to_byte())
}

///|
fn lz4_custom_frame(
  block_independence : Bool,
  block_checksum : Bool,
  dict_id : UInt,
  blocks : Array[Bytes],
  uncompressed : Array[Bool],
) -> Bytes {
  let out = @blit.Buffer::new()
  lz4_write_u32_le(out, 0x184D2204U)
  let flg = 0x40 |
    (if block_independence { 0x20 } else { 0 }) |
    (if block_checksum { 0x10 } else { 0 }) |
    (if dict_id != 0U { 0x01 } else { 0 })
  out.write_byte(flg.to_byte())
  out.write_byte((4 << 4).to_byte())
  if dict_id != 0U {
    lz4_write_u32_le(out, dict_id)
  }
  let header_bytes = out.to_bytes()
  let hc = (@checksum.xxh32(header_bytes[4:]) >> 8) & 0xFFU
  out.write_byte(hc.to_byte())
  for i in 0..<blocks.length() {
    let payload = blocks[i]
    let size = payload.length().reinterpret_as_uint()
    let header = if uncompressed[i] { size | 0x80000000U } else { size }
    lz4_write_u32_le(out, header)
    out.write_bytes(payload)
    if block_checksum {
      lz4_write_u32_le(out, @checksum.xxh32(payload[:]))
    }
  }
  lz4_write_u32_le(out, 0U)
  out.to_bytes()
}

///|
test "lz4 decompresses dependent blocks" {
  let frame = lz4_custom_frame(false, false, 0U, [b"ABCD", b"\x00\x04\x00"], [
    true, false,
  ])
  let decompressed = @lz4.decompress(frame)
  assert_eq(decompressed, b"ABCDABCD")
}

///|
test "lz4 accepts frames with block checksums" {
  let frame = lz4_custom_frame(true, true, 0U, [b"checked block"], [true])
  let decompressed = @lz4.decompress(frame)
  assert_eq(decompressed, b"checked block")
}

///|
test "lz4 accepts dict-id frames when a dictionary is provided" {
  let frame = lz4_custom_frame(
    false,
    false,
    0x12345678U,
    [b"dict-id payload"],
    [true],
  )
  let result = try? @lz4.decompress(frame)
  guard result is Err(_) else {
    fail("expected dict-id frame to require a dictionary")
  }
  let decompressed = @lz4.decompress(frame, dict=b"external dictionary")
  assert_eq(decompressed, b"dict-id payload")
}

///|
test "lz4 truncated dict id header" {
  let data : Bytes = b"\x04\x22\x4d\x18\x61\x40\x00"
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else {
    fail("expected error for truncated dict-id header")
  }
}

///|
test "lz4 missing end mark" {
  let compressed = @lz4.compress(b"Hello, World!")
  let truncated = Bytes::makei(compressed.length() - 8, fn(i) { compressed[i] })
  let result = try? @lz4.decompress(truncated)
  guard result is Err(_) else { fail("expected error for missing end mark") }
}

///|
test "lz4 decompress concatenated frames" {
  let combined = @lz4.compress(b"first frame") + @lz4.compress(b"second frame")
  let decompressed = @lz4.decompress(combined)
  assert_eq(decompressed, b"first framesecond frame")
}

///|
test "lz4 rejects trailing bytes after last frame" {
  let compressed = @lz4.compress(b"Hello, World!") + b"\x00"
  let result = try? @lz4.decompress(compressed)
  guard result is Err(_) else {
    fail("expected error for trailing bytes after last LZ4 frame")
  }
}
