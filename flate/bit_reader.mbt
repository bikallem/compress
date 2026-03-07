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
/// Returns any unconsumed bytes remaining in the bit buffer and input.
fn BitReader::remaining_bytes(self : BitReader) -> Bytes {
  let discard = self.count % 8
  let aligned_buf = self.buf >> discard
  let aligned_count = self.count - discard
  let num_bytes = aligned_count / 8
  let remaining_input = self.data.length() - self.pos
  let total = num_bytes + remaining_input
  if total == 0 {
    return Bytes::default()
  }
  let result = FixedArray::make(total, b'\x00')
  let mut b = aligned_buf
  for i in 0..<num_bytes {
    result[i] = (b & 0xFFUL).to_byte()
    b = b >> 8
  }
  for i in 0..<remaining_input {
    result[num_bytes + i] = self.data[self.pos + i]
  }
  result.unsafe_reinterpret_as_bytes()
}
