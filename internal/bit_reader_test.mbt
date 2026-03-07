///|
test "bit_reader basic read" {
  // 0b10110100 = 0xB4
  let r = @internal.BitReader::new(b"\xB4")
  // LSB first: bits are 0,0,1,0,1,1,0,1
  inspect(r.read_bits(1), content="0")
  inspect(r.read_bits(1), content="0")
  inspect(r.read_bits(1), content="1")
  inspect(r.read_bits(1), content="0")
  inspect(r.read_bits(1), content="1")
  inspect(r.read_bits(1), content="1")
  inspect(r.read_bits(1), content="0")
  inspect(r.read_bits(1), content="1")
}

///|
test "bit_reader multi-bit read" {
  // 0xAB = 0b10101011, LSB first
  let r = @internal.BitReader::new(b"\xAB")
  // Read 4 bits: 1011 = 11
  inspect(r.read_bits(4), content="11")
  // Read 4 bits: 1010 = 10
  inspect(r.read_bits(4), content="10")
}

///|
test "bit_reader cross-byte read" {
  // Two bytes: 0xFF 0x00
  let r = @internal.BitReader::new(b"\xFF\x00")
  // Read 12 bits: low 8 from first byte (0xFF) + low 4 from second (0x00)
  inspect(r.read_bits(12), content="255")
  // Remaining 4 bits: high 4 of second byte = 0
  inspect(r.read_bits(4), content="0")
}

///|
test "bit_reader peek and skip" {
  let r = @internal.BitReader::new(b"\xAB")
  inspect(r.peek_bits(4), content="Some(11)")
  // Peek should not consume
  inspect(r.peek_bits(4), content="Some(11)")
  r.skip_bits(4)
  inspect(r.read_bits(4), content="10")
}

///|
test "bit_reader align_to_byte" {
  let r = @internal.BitReader::new(b"\xFF\xAA")
  let _ = r.read_bits(3)
  r.align_to_byte()
  // After align, next read starts at byte boundary
  inspect(r.read_bits(8), content="170") // 0xAA
}

///|
test "bit_reader eof" {
  let r = @internal.BitReader::new(b"")
  inspect(r.is_eof(), content="true")
  inspect(r.bits_remaining(), content="0")
}

///|
test "bit_reader read_byte" {
  let r = @internal.BitReader::new(b"\xDE\xAD")
  inspect(r.read_byte(), content="b'\\xDE'")
  inspect(r.read_byte(), content="b'\\xAD'")
}

///|
test "bit_reader read_bytes" {
  let r = @internal.BitReader::new(b"\x01\x02\x03\x04")
  let bytes = r.read_bytes(3)
  inspect(bytes[0], content="b'\\x01'")
  inspect(bytes[1], content="b'\\x02'")
  inspect(bytes[2], content="b'\\x03'")
  inspect(r.read_byte(), content="b'\\x04'")
}

///|
test "bit_reader bits_remaining" {
  let r = @internal.BitReader::new(b"\xFF\xFF")
  inspect(r.bits_remaining(), content="16")
  let _ = r.read_bits(5)
  inspect(r.bits_remaining(), content="11")
}
