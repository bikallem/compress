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
  let data = self.data
  let data_len = data.length()
  let mut pos = self.pos
  let mut buf = self.buf
  let mut count = self.count
  // Safety: pos < data_len checked before each access
  while count <= 56 && pos < data_len {
    buf = buf | (data.unsafe_get(pos).to_uint64() << count)
    count += 8
    pos += 1
  }
  self.buf = buf
  self.count = count
  self.pos = pos
}

///|
/// Ensure at least n bits are available in the buffer.
fn BitReader::ensure(self : BitReader, n : Int) -> Unit raise CompressError {
  let data = self.data
  let data_len = data.length()
  let mut pos = self.pos
  let mut buf = self.buf
  let mut count = self.count
  while count < n {
    if pos >= data_len {
      raise CompressError::UnexpectedEOF
    }
    // Safety: pos < data_len checked above
    buf = buf | (data.unsafe_get(pos).to_uint64() << count)
    count += 8
    pos += 1
  }
  self.buf = buf
  self.count = count
  self.pos = pos
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
