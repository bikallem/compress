///|
/// BitWriter writes individual bits to a byte buffer, LSB first.
/// Used internally by DEFLATE and LZW encoders.
struct BitWriter {
  buf : @buffer.Buffer
  mut bit_buf : UInt64
  mut bit_count : Int
}

///|
/// Creates a new BitWriter.
pub fn BitWriter::new(size_hint? : Int = 256) -> BitWriter {
  { buf: @buffer.new(size_hint~), bit_buf: 0UL, bit_count: 0 }
}

///|
/// Writes `n` bits (1..=57) to the buffer, LSB first.
pub fn BitWriter::write_bits(self : BitWriter, val : UInt, n : Int) -> Unit {
  self.bit_buf = self.bit_buf | (val.to_uint64() << self.bit_count)
  self.bit_count += n
  self.flush_full_bytes()
}

///|
/// Flushes complete bytes from the bit buffer.
fn BitWriter::flush_full_bytes(self : BitWriter) -> Unit {
  while self.bit_count >= 8 {
    self.buf.write_byte((self.bit_buf & 0xFFUL).to_byte())
    self.bit_buf = self.bit_buf >> 8
    self.bit_count -= 8
  }
}

///|
/// Writes `n` bits with the value in reverse (MSB first in the bit stream).
/// Used for Huffman codes which are stored MSB first.
pub fn BitWriter::write_bits_reverse(
  self : BitWriter,
  val : UInt,
  n : Int,
) -> Unit {
  let mut reversed = 0U
  let mut v = val
  for _ in 0..<n {
    reversed = (reversed << 1) | (v & 1U)
    v = v >> 1
  }
  self.write_bits(reversed, n)
}

///|
/// Writes a full byte.
pub fn BitWriter::write_byte(self : BitWriter, b : Byte) -> Unit {
  self.write_bits(b.to_uint(), 8)
}

///|
/// Writes raw bytes, aligning to byte boundary first.
pub fn BitWriter::write_bytes(self : BitWriter, data : BytesView) -> Unit {
  self.align_to_byte()
  for i in 0..<data.length() {
    self.buf.write_byte(data[i])
  }
}

///|
/// Aligns output to byte boundary by padding with zero bits.
pub fn BitWriter::align_to_byte(self : BitWriter) -> Unit {
  if self.bit_count > 0 {
    self.buf.write_byte((self.bit_buf & 0xFFUL).to_byte())
    self.bit_buf = 0UL
    self.bit_count = 0
  }
}

///|
/// Returns the accumulated bytes, flushing any remaining bits.
pub fn BitWriter::to_bytes(self : BitWriter) -> Bytes {
  self.align_to_byte()
  self.buf.to_bytes()
}

///|
/// Returns the number of bytes written so far (including partial byte).
pub fn BitWriter::byte_count(self : BitWriter) -> Int {
  self.buf.length() + (if self.bit_count > 0 { 1 } else { 0 })
}

///|
/// Resets the writer, clearing all buffered data.
pub fn BitWriter::reset(self : BitWriter) -> Unit {
  self.buf.reset()
  self.bit_buf = 0UL
  self.bit_count = 0
}
