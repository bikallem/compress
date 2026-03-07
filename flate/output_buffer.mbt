///|
/// Fast chunked output buffer for decompression.
/// Collects output in fixed-size chunks to avoid grow-copy overhead.
/// Only concatenates once at to_bytes().
priv struct OutputBuffer {
  chunks : Array[FixedArray[Byte]]
  mut current : FixedArray[Byte]
  mut pos : Int // position within current chunk
  mut total : Int // total bytes written across all chunks
}

///|
fn OutputBuffer::new(size_hint : Int) -> OutputBuffer {
  let chunk_size = if size_hint > 32768 { size_hint } else { 32768 }
  {
    chunks: [],
    current: FixedArray::make(chunk_size, b'\x00'),
    pos: 0,
    total: 0,
  }
}

///|
/// Start a new chunk, saving the current one.
fn OutputBuffer::new_chunk(self : OutputBuffer) -> Unit {
  self.chunks.push(self.current)
  let next_size = self.current.length()
  self.current = FixedArray::make(next_size, b'\x00')
  self.pos = 0
}

///|
/// Write a contiguous slice from a FixedArray[Byte].
fn OutputBuffer::write_fixed(
  self : OutputBuffer,
  src : FixedArray[Byte],
  start : Int,
  len : Int,
) -> Unit {
  let avail = self.current.length() - self.pos
  if len <= avail {
    blit_bytes(self.current, self.pos, src, start, len)
    self.pos += len
    self.total += len
  } else {
    let mut remaining = len
    let mut src_pos = start
    if avail > 0 {
      blit_bytes(self.current, self.pos, src, src_pos, avail)
      self.pos += avail
      self.total += avail
      remaining -= avail
      src_pos += avail
    }
    while remaining > 0 {
      self.new_chunk()
      let n = if remaining < self.current.length() {
        remaining
      } else {
        self.current.length()
      }
      blit_bytes(self.current, 0, src, src_pos, n)
      self.pos = n
      self.total += n
      remaining -= n
      src_pos += n
    }
  }
}

///|
/// Convert to final Bytes output — single concatenation.
fn OutputBuffer::to_bytes(self : OutputBuffer) -> Bytes {
  if self.chunks.length() == 0 {
    if self.pos == self.current.length() {
      return self.current.unsafe_reinterpret_as_bytes()
    }
    let result = FixedArray::make(self.pos, b'\x00')
    blit_bytes(result, 0, self.current, 0, self.pos)
    return result.unsafe_reinterpret_as_bytes()
  }
  let result = FixedArray::make(self.total, b'\x00')
  let mut offset = 0
  for chunk in self.chunks {
    let chunk_len = chunk.length()
    blit_bytes(result, offset, chunk, 0, chunk_len)
    offset += chunk_len
  }
  if self.pos > 0 {
    blit_bytes(result, offset, self.current, 0, self.pos)
  }
  result.unsafe_reinterpret_as_bytes()
}
