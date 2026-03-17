///|
test "brotli bit reader and writer round trip" {
  let writer = BitWriter::new()
  writer.write_bits(0b101U, 3)
  writer.write_bits(0b11U, 2)
  writer.write_bits(0b11110000U, 8)
  let encoded = writer.finish()

  let reader = BitReader::new()
  reader.set_input(encoded[:])
  assert_eq(reader.read(3), Some(0b101))
  assert_eq(reader.read(2), Some(0b11))
  assert_eq(reader.read(8), Some(0b11110000))
  assert_eq(reader.read(3), Some(0))
  assert_eq(reader.read(1), None)
}

///|
test "brotli bit reader remaining bytes after alignment" {
  let writer = BitWriter::new()
  writer.write_bits(1U, 1)
  writer.align_to_byte()
  writer.write_bytes(b"AB"[:])
  let encoded = writer.finish()
  assert_eq(encoded, b"\x01AB")

  let reader = BitReader::new()
  reader.set_input(encoded[:])
  assert_eq(reader.read(1), Some(1))
  reader.align_to_byte()
  assert_eq(reader.remaining_bytes(), b"AB")
}
