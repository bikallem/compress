///|
/// BitReader reads individual bits from a byte stream, LSB first.
/// Used internally by DEFLATE, LZW, and bzip2 decoders.
struct BitReader {
  data : Bytes
  mut pos : Int
  mut bit_buf : UInt64
  mut bit_count : Int
}

///|
/// Creates a new BitReader from a byte buffer.
pub fn BitReader::new(data : Bytes) -> BitReader {
  { data, pos: 0, bit_buf: 0UL, bit_count: 0 }
}

///|
/// Ensures at least `n` bits are available in the bit buffer.
/// Returns false if not enough data remains.
fn BitReader::fill(self : BitReader, n : Int) -> Bool {
  while self.bit_count < n {
    if self.pos >= self.data.length() {
      return false
    }
    let b = self.data[self.pos].to_uint64()
    self.bit_buf = self.bit_buf | (b << self.bit_count)
    self.bit_count += 8
    self.pos += 1
  }
  true
}

///|
/// Reads `n` bits (1..=57) from the stream, LSB first.
/// Raises if not enough data.
pub fn BitReader::read_bits(self : BitReader, n : Int) -> UInt raise {
  guard self.fill(n) else { fail("unexpected end of input") }
  let mask = (1UL << n) - 1UL
  let val = self.bit_buf & mask
  self.bit_buf = self.bit_buf >> n
  self.bit_count -= n
  val.to_uint()
}

///|
/// Peeks at `n` bits without consuming them.
pub fn BitReader::peek_bits(self : BitReader, n : Int) -> UInt? {
  if not(self.fill(n)) {
    return None
  }
  let mask = (1UL << n) - 1UL
  Some((self.bit_buf & mask).to_uint())
}

///|
/// Discards `n` bits from the buffer.
pub fn BitReader::skip_bits(self : BitReader, n : Int) -> Unit {
  self.bit_buf = self.bit_buf >> n
  self.bit_count -= n
}

///|
/// Aligns to the next byte boundary by discarding remaining bits in the
/// current byte.
pub fn BitReader::align_to_byte(self : BitReader) -> Unit {
  let discard = self.bit_count % 8
  if discard > 0 {
    self.bit_buf = self.bit_buf >> discard
    self.bit_count -= discard
  }
}

///|
/// Returns the number of bits remaining available without consuming.
pub fn BitReader::bits_remaining(self : BitReader) -> Int {
  self.bit_count + (self.data.length() - self.pos) * 8
}

///|
/// Returns whether the reader has reached end of input (no bits left).
pub fn BitReader::is_eof(self : BitReader) -> Bool {
  self.bit_count == 0 && self.pos >= self.data.length()
}

///|
/// Reads a single byte, aligning to byte boundary first.
pub fn BitReader::read_byte(self : BitReader) -> Byte raise {
  self.align_to_byte()
  if self.bit_count >= 8 {
    let b = (self.bit_buf & 0xFFUL).to_byte()
    self.bit_buf = self.bit_buf >> 8
    self.bit_count -= 8
    b
  } else if self.pos < self.data.length() {
    let b = self.data[self.pos]
    self.pos += 1
    b
  } else {
    fail("unexpected end of input")
  }
}

///|
/// Reads `n` bytes into a new Bytes, aligning to byte boundary first.
pub fn BitReader::read_bytes(self : BitReader, n : Int) -> Bytes raise {
  self.align_to_byte()
  let buf = @buffer.new(size_hint=n)
  for _ in 0..<n {
    buf.write_byte(self.read_byte())
  }
  buf.to_bytes()
}
