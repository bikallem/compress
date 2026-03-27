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
