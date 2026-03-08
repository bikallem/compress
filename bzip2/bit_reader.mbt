///|
/// Internal bit reader for bzip2 decompression.
/// Reads bits MSB-first (big-endian), pulling bytes incrementally
/// from a `@stream.Reader`.
priv struct Bzip2BitReader {
  reader : &@stream.Reader
  mut chunk : BytesView
  mut chunk_pos : Int
  mut bit_buf : UInt
  mut bits_left : Int
  mut eof : Bool
}

///|
fn Bzip2BitReader::new(reader : &@stream.Reader) -> Bzip2BitReader {
  { reader, chunk: b""[:], chunk_pos: 0, bit_buf: 0U, bits_left: 0, eof: false }
}

///|
fn Bzip2BitReader::next_byte(self : Bzip2BitReader) -> Byte raise Bzip2Error {
  if self.chunk_pos < self.chunk.length() {
    let b = self.chunk[self.chunk_pos]
    self.chunk_pos += 1
    return b
  }
  if self.eof {
    raise Bzip2Error::UnexpectedEOF
  }
  let c = self.reader.read() catch {
    e => raise Bzip2Error::CorruptData(e.to_string())
  }
  if c.is_empty() {
    self.eof = true
    raise Bzip2Error::UnexpectedEOF
  }
  self.chunk = c
  self.chunk_pos = 1
  c[0]
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
