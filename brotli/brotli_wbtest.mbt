///|
test "brotli hash uses unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc\x11"
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  let mixed = (raw & 0xFFFFFFU) ^ (((raw >> 16) & 0xFFU) * 0x1e35a7bdU)
  let expected = mixed.reinterpret_as_int() & (BROTLI_HASH_SIZE - 1)
  assert_eq(brotli_hash4(data[:], 0), expected)
}
