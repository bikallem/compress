///|
/// Internal bit reader for bzip2 decompression.
/// Reads bits MSB-first (big-endian) from a Bytes buffer.
priv struct Bzip2BitReader {
  data : Bytes
  mut pos : Int
  mut bit_buf : UInt
  mut bits_left : Int
}

///|
fn Bzip2BitReader::new(data : Bytes) -> Bzip2BitReader {
  { data, pos: 0, bit_buf: 0U, bits_left: 0 }
}

///|
fn Bzip2BitReader::next_byte(self : Bzip2BitReader) -> Byte raise Bzip2Error {
  if self.pos >= self.data.length() {
    raise Bzip2Error::UnexpectedEOF
  }
  let b = self.data[self.pos]
  self.pos += 1
  b
}

///|
fn Bzip2BitReader::read_bits(
  self : Bzip2BitReader,
  n : Int,
) -> UInt raise Bzip2Error {
  while self.bits_left < n {
    let b = self.next_byte()
    self.bit_buf = (self.bit_buf << 8) | b.to_uint()
    self.bits_left += 8
  }
  self.bits_left -= n
  let result = (self.bit_buf >> self.bits_left) & ((1U << n) - 1U)
  result
}

///|
fn Bzip2BitReader::read_bit(self : Bzip2BitReader) -> Bool raise Bzip2Error {
  self.read_bits(1) != 0U
}
