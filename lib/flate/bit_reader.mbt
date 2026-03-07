///|
/// BitReader bundles all bit-reading state into a single mutable struct,
/// eliminating Ref[T] heap indirection on every access.
priv struct BitReader {
  data : Bytes
  mut buf : UInt64
  mut count : Int
  mut pos : Int
}

///|
fn BitReader::new(data : Bytes) -> BitReader {
  { data, buf: 0UL, count: 0, pos: 0 }
}

///|
/// Fill the bit buffer with as many bytes as possible (up to 56 bits).
fn BitReader::fill(self : BitReader) -> Unit {
  let data_len = self.data.length()
  while self.count <= 56 && self.pos < data_len {
    self.buf = self.buf | (self.data[self.pos].to_uint64() << self.count)
    self.count += 8
    self.pos += 1
  }
}

///|
/// Ensure at least n bits are available in the buffer.
fn BitReader::ensure(self : BitReader, n : Int) -> Unit raise CompressError {
  while self.count < n {
    if self.pos >= self.data.length() {
      raise CompressError::UnexpectedEOF
    }
    self.buf = self.buf | (self.data[self.pos].to_uint64() << self.count)
    self.count += 8
    self.pos += 1
  }
}

///|
/// Read n bits from the buffer.
fn BitReader::read(self : BitReader, n : Int) -> Int raise CompressError {
  self.ensure(n)
  let mask = (1UL << n) - 1UL
  let val = (self.buf & mask).to_int()
  self.buf = self.buf >> n
  self.count -= n
  val
}

///|
/// Peek at the low n bits without consuming them.
fn BitReader::peek(self : BitReader, n : Int) -> Int {
  (self.buf & ((1UL << n) - 1UL)).to_int()
}

///|
/// Consume n bits from the buffer (after a peek).
fn BitReader::consume(self : BitReader, n : Int) -> Unit {
  self.buf = self.buf >> n
  self.count -= n
}
