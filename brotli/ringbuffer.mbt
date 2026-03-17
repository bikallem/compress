///|
/// Ring buffer for Brotli decompression.
/// Uses "canny allocation" — starts small, grows as needed.
priv struct BrotliRingBuffer {
  mut buf : FixedArray[Byte]
  mut size : Int // current buffer size (power of 2)
  mut mask : Int // size - 1
  mut pos : Int // write position (not wrapped)
  window_bits : Int // maximum window size = 1 << window_bits
  mut rd_pos : Int // read position for flushing
}

///|
fn BrotliRingBuffer::new(window_bits : Int) -> BrotliRingBuffer {
  // Start with minimum size, grow as needed
  let initial_size = 1024
  {
    buf: FixedArray::make(initial_size + RING_BUFFER_WRITE_AHEAD_SLACK, b'\x00'),
    size: initial_size,
    mask: initial_size - 1,
    pos: 0,
    window_bits,
    rd_pos: 0,
  }
}

///|
/// Ensure the ring buffer is large enough for the given output.
fn BrotliRingBuffer::ensure_size(
  self : BrotliRingBuffer,
  needed : Int,
) -> Unit {
  let max_size = 1 << self.window_bits
  if self.size >= max_size {
    return
  }
  let mut new_size = self.size
  let min_size = if self.pos + needed > new_size {
    self.pos + needed
  } else {
    new_size
  }
  while new_size < min_size && new_size < max_size {
    new_size = new_size << 1
  }
  if new_size > max_size {
    new_size = max_size
  }
  if new_size == self.size {
    return
  }
  let new_buf = FixedArray::make(
    new_size + RING_BUFFER_WRITE_AHEAD_SLACK,
    b'\x00',
  )
  // Copy existing data
  let copy_len = if self.pos < self.size { self.pos } else { self.size }
  @blit.blit_fixed_array(new_buf, 0, self.buf, 0, copy_len)
  self.buf = new_buf
  self.size = new_size
  self.mask = new_size - 1
}

///|
fn BrotliRingBuffer::write_byte(self : BrotliRingBuffer, b : Byte) -> Unit {
  self.buf[self.pos & self.mask] = b
  // Also write to slack area if near end of buffer
  if (self.pos & self.mask) < RING_BUFFER_WRITE_AHEAD_SLACK {
    self.buf[self.size + (self.pos & self.mask)] = b
  }
  self.pos += 1
}

///|
/// Copy from ring buffer history (backward reference).
fn BrotliRingBuffer::write_copy(
  self : BrotliRingBuffer,
  dist : Int,
  length : Int,
) -> Unit {
  let mut remaining = length
  let mut dst = self.pos
  while remaining > 0 {
    let src = (dst - dist) & self.mask
    let dst_idx = dst & self.mask
    self.buf[dst_idx] = self.buf[src]
    if dst_idx < RING_BUFFER_WRITE_AHEAD_SLACK {
      self.buf[self.size + dst_idx] = self.buf[src]
    }
    dst += 1
    remaining -= 1
  }
  self.pos = dst
}

///|
/// Copy dictionary word into ring buffer.
fn BrotliRingBuffer::write_dict(
  self : BrotliRingBuffer,
  data : FixedArray[Byte],
  offset : Int,
  length : Int,
) -> Unit {
  for i in 0..<length {
    let dst_idx = (self.pos + i) & self.mask
    self.buf[dst_idx] = data[offset + i]
    if dst_idx < RING_BUFFER_WRITE_AHEAD_SLACK {
      self.buf[self.size + dst_idx] = data[offset + i]
    }
  }
  self.pos += length
}

///|
/// Get the byte at position relative to current write pos.
fn BrotliRingBuffer::get_byte(self : BrotliRingBuffer, offset : Int) -> Byte {
  self.buf[(self.pos + offset) & self.mask]
}

///|
/// Get the two bytes before current write position (for context computation).
fn BrotliRingBuffer::prev_bytes(self : BrotliRingBuffer) -> (Byte, Byte) {
  let p1 = self.buf[(self.pos - 1) & self.mask]
  let p2 = self.buf[(self.pos - 2) & self.mask]
  (p1, p2)
}

///|
/// Flush output since last flush as Bytes.
fn BrotliRingBuffer::flush(self : BrotliRingBuffer) -> Bytes {
  if self.pos <= self.rd_pos {
    return Bytes::default()
  }
  // Handle wrap-around
  let max_size = 1 << self.window_bits
  if self.pos > max_size {
    // Wrapped: we need to flush up to max_size, then wrap
    let len = self.pos - self.rd_pos
    let result = @blit.make_uninit(len)
    let mut dst = 0
    let mut src = self.rd_pos
    while dst < len {
      result[dst] = self.buf[src & self.mask]
      dst += 1
      src += 1
    }
    self.rd_pos = self.pos
    return result.unsafe_reinterpret_as_bytes()
  }
  let len = self.pos - self.rd_pos
  let result = @blit.make_uninit(len)
  @blit.blit_fixed_array(result, 0, self.buf, self.rd_pos, len)
  self.rd_pos = self.pos
  result.unsafe_reinterpret_as_bytes()
}

///|
fn BrotliRingBuffer::flush_to(
  self : BrotliRingBuffer,
  sink : @output_sink.OutputSink,
) -> Unit {
  if self.pos <= self.rd_pos {
    return
  }
  let len = self.pos - self.rd_pos
  if self.pos <= self.size {
    // No wrap
    sink.write_fixed(self.buf, self.rd_pos, len)
  } else {
    // Wrapped - need byte-by-byte copy
    let mut src = self.rd_pos
    let temp = @blit.make_uninit(len)
    for i in 0..<len {
      temp[i] = self.buf[src & self.mask]
      src += 1
    }
    sink.write_fixed(temp, 0, len)
  }
  self.rd_pos = self.pos
}

///|
/// Maximum backward distance based on data written so far.
fn BrotliRingBuffer::max_distance(self : BrotliRingBuffer) -> Int {
  let max_window = (1 << self.window_bits) - WINDOW_GAP
  if self.pos < max_window {
    self.pos
  } else {
    max_window
  }
}
