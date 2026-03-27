///|
test "lz4 byte packing uses unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc\x11"
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  let expected_hash = ((raw * 0x9E3779B1U) >> 18).reinterpret_as_int() &
    LZ4_HASH_MASK
  assert_eq(lz4_read_u32_le(data[:], 0), raw)
  assert_eq(lz4_hash(data[:], 0), expected_hash)
}

///|
fn lz4_wb_write_u32_le(buf : @blit.Buffer, value : UInt) -> Unit {
  buf.write_byte((value & 0xFFU).to_byte())
  buf.write_byte(((value >> 8) & 0xFFU).to_byte())
  buf.write_byte(((value >> 16) & 0xFFU).to_byte())
  buf.write_byte(((value >> 24) & 0xFFU).to_byte())
}

///|
fn lz4_test_header_with_content_size(size_lo : UInt, size_hi : UInt) -> Bytes {
  let out = @blit.Buffer::new()
  lz4_wb_write_u32_le(out, LZ4_FRAME_MAGIC)
  out.write_byte((0x48).to_byte())
  out.write_byte((4 << 4).to_byte())
  lz4_wb_write_u32_le(out, size_lo)
  lz4_wb_write_u32_le(out, size_hi)
  let header_bytes = out.to_bytes()
  let hc = (@checksum.xxh32(header_bytes[4:]) >> 8) & 0xFFU
  out.write_byte(hc.to_byte())
  out.to_bytes()
}

///|
test "lz4 frame header writes content size with zero upper bytes" {
  let buf = FixedArray::make(32, b'\x00')
  let written = write_frame_header(
    buf,
    0,
    Some(0x12345678),
    FrameOptions::default(),
  )
  assert_eq(written, 15)
  assert_eq(buf[6], 0x78)
  assert_eq(buf[7], 0x56)
  assert_eq(buf[8], 0x34)
  assert_eq(buf[9], 0x12)
  for i in 10..<14 {
    assert_eq(buf[i], b'\x00')
  }
}

///|
test "lz4 parses supported content sizes with unsigned little-endian words" {
  let header = lz4_test_header_with_content_size(0x7FFFFFFFU, 0U)
  let parsed = parse_frame_header(header[:])
  match parsed.content_size {
    Some(size) => assert_eq(size, 0x7FFFFFFF)
    None => fail("expected content size in parsed header")
  }
}

///|
test "lz4 rejects content sizes outside supported Int range" {
  let header = lz4_test_header_with_content_size(0U, 1U)
  let result = try? parse_frame_header(header[:])
  match result {
    Err(Lz4Error::InvalidHeader(msg)) =>
      assert_eq(msg, "content size exceeds supported range")
    Err(err) => fail("expected invalid-header error, got \{err}")
    Ok(_) => fail("expected oversized content size to be rejected")
  }
}
