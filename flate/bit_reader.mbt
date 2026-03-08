///|
/// BitReader bundles all bit-reading state into a single mutable struct.
/// Pulls bytes incrementally from a `@stream.Reader` instead of requiring
/// the full input in memory.
priv struct BitReader {
  reader : &@stream.Reader
  mut chunk : BytesView
  mut chunk_pos : Int
  mut buf : UInt64
  mut count : Int
  mut eof : Bool
}

///|
fn BitReader::new(reader : &@stream.Reader) -> BitReader {
  { reader, chunk: b""[:], chunk_pos: 0, buf: 0UL, count: 0, eof: false }
}

///|
/// Fetch the next byte from the stream. Refills chunk when exhausted.
fn BitReader::next_byte(self : BitReader) -> Byte raise CompressError {
  if self.chunk_pos < self.chunk.length() {
    let b = self.chunk[self.chunk_pos]
    self.chunk_pos += 1
    return b
  }
  // Need a new chunk
  if self.eof {
    raise CompressError::UnexpectedEOF
  }
  let c = self.reader.read() catch {
    e => raise CompressError::CorruptInput(e.to_string())
  }
  if c.is_empty() {
    self.eof = true
    raise CompressError::UnexpectedEOF
  }
  self.chunk = c
  self.chunk_pos = 1
  c[0]
}

///|
/// Fill the bit buffer with as many bytes as possible (up to 56 bits).
fn BitReader::fill(self : BitReader) -> Unit {
  // Fast path: consume bytes from current chunk without per-byte branching
  let mut buf = self.buf
  let mut count = self.count
  let chunk = self.chunk
  let chunk_len = chunk.length()
  let mut cp = self.chunk_pos
  while count <= 56 && cp < chunk_len {
    buf = buf | (chunk[cp].to_uint64() << count)
    count += 8
    cp += 1
  }
  self.chunk_pos = cp
  // Slow path: if we still need more bits and haven't hit EOF, fetch new chunks
  while count <= 56 && not(self.eof) {
    let c = self.reader.read() catch { _ => break }
    if c.is_empty() {
      self.eof = true
      break
    }
    self.chunk = c
    self.chunk_pos = 0
    let clen = c.length()
    let mut i = 0
    while count <= 56 && i < clen {
      buf = buf | (c[i].to_uint64() << count)
      count += 8
      i += 1
    }
    self.chunk_pos = i
  }
  self.buf = buf
  self.count = count
}

///|
/// Ensure at least n bits are available in the buffer.
fn BitReader::ensure(self : BitReader, n : Int) -> Unit raise CompressError {
  let mut buf = self.buf
  let mut count = self.count
  // Fast path: drain current chunk
  let chunk = self.chunk
  let chunk_len = chunk.length()
  let mut cp = self.chunk_pos
  while count < n && cp < chunk_len {
    buf = buf | (chunk[cp].to_uint64() << count)
    count += 8
    cp += 1
  }
  self.chunk_pos = cp
  self.buf = buf
  self.count = count
  // Slow path: fetch more from reader
  while self.count < n {
    let b = self.next_byte()
    self.buf = self.buf | (b.to_uint64() << self.count)
    self.count += 8
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
/// Returns a BytesView of up to `max_len` bytes from the stream.
/// Does NOT copy — returns a view into the current chunk.
/// Call repeatedly until all bytes consumed.
fn BitReader::next_chunk(
  self : BitReader,
  max_len : Int,
) -> BytesView raise CompressError {
  if self.chunk_pos >= self.chunk.length() {
    if self.eof {
      raise CompressError::UnexpectedEOF
    }
    let c = self.reader.read() catch {
      e => raise CompressError::CorruptInput(e.to_string())
    }
    if c.is_empty() {
      self.eof = true
      raise CompressError::UnexpectedEOF
    }
    self.chunk = c
    self.chunk_pos = 0
  }
  let avail = self.chunk.length() - self.chunk_pos
  let n = if avail < max_len { avail } else { max_len }
  let view = self.chunk[self.chunk_pos:self.chunk_pos + n]
  self.chunk_pos += n
  view
}

///|
/// Returns any unconsumed bytes remaining in the bit buffer and current chunk.
fn BitReader::remaining_bytes(self : BitReader) -> Bytes {
  let discard = self.count % 8
  let aligned_buf = self.buf >> discard
  let aligned_count = self.count - discard
  let num_bytes = aligned_count / 8
  let remaining_chunk = self.chunk.length() - self.chunk_pos
  let total = num_bytes + remaining_chunk
  if total == 0 {
    return Bytes::default()
  }
  let result = FixedArray::make(total, b'\x00')
  let mut b = aligned_buf
  for i in 0..<num_bytes {
    result[i] = (b & 0xFFUL).to_byte()
    b = b >> 8
  }
  for i in 0..<remaining_chunk {
    result[num_bytes + i] = self.chunk[self.chunk_pos + i]
  }
  result.unsafe_reinterpret_as_bytes()
}
