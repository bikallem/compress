///|
test "snappy hash uses unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc\x11"
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  let expected = ((raw * 0x1E35A7BDU) >> 18).reinterpret_as_int() &
    HASH_TABLE_MASK
  assert_eq(snappy_u32_le(data[:], 0), raw)
  assert_eq(snappy_hash(data[:], 0), expected)
}

///|
test "snappy 32-bit literal lengths use unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc"
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  assert_eq(snappy_read_u32_le(data, 0), raw.reinterpret_as_int())
}
