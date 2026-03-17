///|
test "brotli inverse move-to-front transform" {
  let transformed = FixedArray::make(4, b'\x00')
  transformed[1] = b'\x01'
  transformed[2] = b'\x01'
  transformed[3] = b'\x01'
  inverse_move_to_front_in_place(transformed, transformed.length())
  assert_eq(transformed.unsafe_reinterpret_as_bytes(), b"\x00\x01\x00\x01")
}

///|
test "brotli literal context helper" {
  assert_eq(literal_context_id(LSB6, b'\xff', b'\x00'), 63)
  assert_eq(literal_context_id(MSB6, b'\xff', b'\x00'), 63)
}

///|
test "brotli context map decoding handles zero-rle" {
  let writer = BitWriter::new()
  writer.write_bits(1U, 5) // RLEMAX = 1
  write_simple_prefix(writer, 4, [0, 1, 2, 3], tree_select=1)

  let lengths = FixedArray::make(4, 0)
  lengths[0] = 1
  lengths[1] = 2
  lengths[2] = 3
  lengths[3] = 3

  write_symbol_with_lengths(writer, lengths, 1)
  writer.write_bits(1U, 1) // repeat zero 3 times
  write_symbol_with_lengths(writer, lengths, 2)
  write_symbol_with_lengths(writer, lengths, 0)
  write_symbol_with_lengths(writer, lengths, 3)
  writer.write_bits(0U, 1) // no IMTF
  let encoded = writer.finish()

  let reader = BitReader::new()
  reader.set_input(encoded[:])
  let decoded = decode_context_map(reader, 6, 3)
  assert_eq(decoded, b"\x00\x00\x00\x01\x00\x02")
}

///|
test "brotli distance history resolves short codes" {
  let history = DistanceHistory::new()
  assert_eq(history.resolve_short_code(0), 4)
  assert_eq(history.resolve_short_code(1), 11)
  assert_eq(history.resolve_short_code(4), 3)
  history.push(20)
  assert_eq(history.resolve_short_code(0), 20)
  assert_eq(history.resolve_short_code(1), 4)
}
