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

///|
test "brotli identity dictionary matches common words" {
  let (length, distance) = find_identity_dictionary_match(
    b"function"[:],
    0,
    8,
    0,
  )
  assert_eq(length, 8)
  assert_true(distance > 0)
}

///|
fn brotli_split_fixture() -> Bytes {
  let buf = @blit.Buffer::new()
  for i in 0..<128 {
    buf.write_bytes(
      b"function return value status code request header response payload\n",
    )
    for j in 0..<256 {
      buf.write_byte(((i * 17 + j * 31) % 251).to_byte())
    }
    buf.write_bytes(
      b"The quick brown fox jumps over the lazy dog. This log segment is highly compressible.\n",
    )
  }
  buf.to_bytes()
}

///|
test "brotli split candidate can beat a single metablock" {
  let data = brotli_split_fixture()
  let split = compress_lz77_split(data[:], data.length(), 11, 16384)
  let wbits = optimal_wbits(data.length())
  let cmds = lz77_find_matches_chain(data[:], data.length(), 11)
  let single = encode_compressed_metablock(
    data[:],
    data.length(),
    cmds,
    11,
    wbits,
  )
  assert_eq(decompress(split), data)
  assert_eq(decompress(single), data)
  assert_true(split.length() <= single.length())
}
