///|
/// AsyncBitReader reads bits from an `@io.Reader` incrementally.
/// Unlike BitReader which operates on a Bytes buffer, this reads
/// bytes on demand from the source reader.
priv struct AsyncBitReader {
  source : &@io.Reader
  mut buf : UInt64
  mut count : Int
  mut eof : Bool
  read_buf : FixedArray[Byte]
}

///|
fn AsyncBitReader::new(source : &@io.Reader) -> AsyncBitReader {
  {
    source,
    buf: 0UL,
    count: 0,
    eof: false,
    read_buf: FixedArray::make(8, b'\x00'),
  }
}

///|
/// Fill the bit buffer with as many bytes as possible (up to 56 bits).
async fn AsyncBitReader::fill(self : AsyncBitReader) -> Unit {
  while self.count <= 56 && not(self.eof) {
    let max_bytes = (56 - self.count) / 8
    if max_bytes <= 0 {
      return
    }
    let n = self.source.read(self.read_buf, offset=0, max_len=max_bytes)
    if n == 0 {
      self.eof = true
      return
    }
    for i in 0..<n {
      self.buf = self.buf | (self.read_buf[i].to_uint64() << self.count)
      self.count += 8
    }
  }
}

///|
/// Ensure at least n bits are available in the buffer.
async fn AsyncBitReader::ensure(self : AsyncBitReader, n : Int) -> Unit {
  while self.count < n {
    if self.eof {
      raise CompressError::UnexpectedEOF
    }
    let bytes_read = self.source.read(self.read_buf, offset=0, max_len=1)
    if bytes_read == 0 {
      self.eof = true
      raise CompressError::UnexpectedEOF
    }
    self.buf = self.buf | (self.read_buf[0].to_uint64() << self.count)
    self.count += 8
  }
}

///|
/// Read n bits from the buffer.
async fn AsyncBitReader::read(self : AsyncBitReader, n : Int) -> Int {
  self.ensure(n)
  let mask = (1UL << n) - 1UL
  let val = (self.buf & mask).to_int()
  self.buf = self.buf >> n
  self.count -= n
  val
}

///|
/// Returns any unconsumed bytes remaining in the bit buffer.
/// Useful for wrapper formats (zlib, gzip) that need to read a footer
/// after the DEFLATE stream ends.
fn AsyncBitReader::remaining_bytes(self : AsyncBitReader) -> Bytes {
  // Discard partial byte bits (align to byte boundary)
  let discard = self.count % 8
  let aligned_buf = self.buf >> discard
  let aligned_count = self.count - discard
  let num_bytes = aligned_count / 8
  if num_bytes == 0 {
    return Bytes::default()
  }
  let result = FixedArray::make(num_bytes, b'\x00')
  let mut b = aligned_buf
  for i in 0..<num_bytes {
    result[i] = (b & 0xFFUL).to_byte()
    b = b >> 8
  }
  result.unsafe_reinterpret_as_bytes()
}
