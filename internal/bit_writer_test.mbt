///|
test "bit_writer basic write" {
  let w = @internal.BitWriter::new()
  // Write 0b10110100 bit by bit, LSB first
  w.write_bits(0U, 1)
  w.write_bits(0U, 1)
  w.write_bits(1U, 1)
  w.write_bits(0U, 1)
  w.write_bits(1U, 1)
  w.write_bits(1U, 1)
  w.write_bits(0U, 1)
  w.write_bits(1U, 1)
  let result = w.to_bytes()
  inspect(result[0], content="b'\\xB4'")
}

///|
test "bit_writer multi-bit" {
  let w = @internal.BitWriter::new()
  // Write 4 bits: 1011 (=11), then 4 bits: 1010 (=10)
  w.write_bits(11U, 4)
  w.write_bits(10U, 4)
  let result = w.to_bytes()
  inspect(result[0], content="b'\\xAB'") // 0xAB
}

///|
test "bit_writer cross-byte" {
  let w = @internal.BitWriter::new()
  // Write 12 bits: 0xFF (255) then pad with 0s
  w.write_bits(255U, 12) // low 12 bits of 255 = 0x0FF
  w.write_bits(0U, 4) // fill remaining
  let result = w.to_bytes()
  inspect(result[0], content="b'\\xFF'")
  inspect(result[1], content="b'\\x00'")
}

///|
test "bit_writer write_byte" {
  let w = @internal.BitWriter::new()
  w.write_byte(b'\xDE')
  w.write_byte(b'\xAD')
  let result = w.to_bytes()
  inspect(result[0], content="b'\\xDE'")
  inspect(result[1], content="b'\\xAD'")
}

///|
test "bit_writer write_bytes" {
  let w = @internal.BitWriter::new()
  let data : Bytes = b"\x01\x02\x03"
  w.write_bytes(data[:])
  let result = w.to_bytes()
  inspect(result.length(), content="3")
  inspect(result[0], content="b'\\x01'")
  inspect(result[2], content="b'\\x03'")
}

///|
test "bit_writer round-trip with bit_reader" {
  let w = @internal.BitWriter::new()
  w.write_bits(7U, 3) // 111
  w.write_bits(0U, 2) // 00
  w.write_bits(5U, 3) // 101
  w.write_bits(15U, 4) // 1111
  w.write_bits(1U, 4) // 0001
  let bytes = w.to_bytes()
  let r = @internal.BitReader::new(bytes)
  inspect(r.read_bits(3), content="7")
  inspect(r.read_bits(2), content="0")
  inspect(r.read_bits(3), content="5")
  inspect(r.read_bits(4), content="15")
  inspect(r.read_bits(4), content="1")
}

///|
test "bit_writer reset" {
  let w = @internal.BitWriter::new()
  w.write_bits(255U, 8)
  w.reset()
  inspect(w.byte_count(), content="0")
  w.write_bits(0U, 8)
  let result = w.to_bytes()
  inspect(result[0], content="b'\\x00'")
}

///|
test "bit_writer write_bits_reverse" {
  let w = @internal.BitWriter::new()
  // Write 5 (0b101) reversed -> 0b101 reversed is 0b101 (palindrome)
  w.write_bits_reverse(5U, 3)
  // Write 6 (0b110) reversed -> 0b011 = 3
  w.write_bits_reverse(6U, 3)
  // Now we have 6 bits: 101 011 => 0b011101 = 0x2D
  w.write_bits(0U, 2) // pad
  let result = w.to_bytes()
  inspect(result[0], content="b'\\x1D'")
}
