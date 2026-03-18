///|
/// Growable byte buffer for zero-copy decompression output.
/// Decoded bytes accumulate here instead of being allocated as intermediate
/// Bytes objects, eliminating per-flush allocation overhead.
pub struct OutputSink {
  mut buf : FixedArray[Byte]
  mut pos : Int
}

///|
pub fn OutputSink::new(capacity : Int) -> OutputSink {
  { buf: @blit.make_uninit(capacity), pos: 0 }
}

///|
pub fn OutputSink::ensure_capacity(self : OutputSink, additional : Int) -> Unit {
  let required = self.pos + additional
  if required > self.buf.length() {
    let mut new_cap = self.buf.length() * 2
    if new_cap < required {
      new_cap = required
    }
    let new_buf = @blit.make_uninit(new_cap)
    @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.pos)
    self.buf = new_buf
  }
}

///|
/// Write bytes from a FixedArray region into the sink.
pub fn OutputSink::write_fixed(
  self : OutputSink,
  src : FixedArray[Byte],
  offset : Int,
  len : Int,
) -> Unit {
  self.ensure_capacity(len)
  @blit.blit_fixed_array(self.buf, self.pos, src, offset, len)
  self.pos += len
}

///|
/// Write all bytes from a Bytes value into the sink.
pub fn OutputSink::write_bytes(self : OutputSink, src : Bytes) -> Unit {
  let len = src.length()
  self.ensure_capacity(len)
  @blit.blit_bytes(self.buf, self.pos, src, 0, len)
  self.pos += len
}

///|
/// Write a single byte.
pub fn OutputSink::write_byte(self : OutputSink, b : Byte) -> Unit {
  self.ensure_capacity(1)
  self.buf[self.pos] = b
  self.pos += 1
}

///|
/// Get a byte at absolute position in the output.
pub fn OutputSink::get_byte(self : OutputSink, pos : Int) -> Byte {
  self.buf[pos]
}

///|
/// Copy `len` bytes from position `src_pos` in the output buffer to the
/// current write position. Handles overlapping regions correctly (when
/// distance < len, the pattern repeats). This replaces per-byte
/// get_byte + write_byte loops in the decoder's copy path.
pub fn OutputSink::copy_from_self(
  self : OutputSink,
  src_pos : Int,
  len : Int,
) -> Unit {
  self.ensure_capacity(len)
  let buf = self.buf
  let mut dst = self.pos
  let distance = dst - src_pos
  if distance >= len {
    // Non-overlapping: use bulk blit
    @blit.blit_fixed_array(buf, dst, buf, src_pos, len)
    self.pos += len
  } else {
    // Overlapping: byte-by-byte (pattern repeats)
    let mut src = src_pos
    for _ in 0..<len {
      buf[dst] = buf[src]
      dst += 1
      src += 1
    }
    self.pos = dst
  }
}

///|
/// Write a single byte without capacity check (caller must ensure capacity).
pub fn OutputSink::write_byte_unchecked(self : OutputSink, b : Byte) -> Unit {
  self.buf[self.pos] = b
  self.pos += 1
}

///|
/// Current number of bytes written.
pub fn OutputSink::length(self : OutputSink) -> Int {
  self.pos
}

///|
/// Produce the final Bytes result. Single allocation.
pub fn OutputSink::to_bytes(self : OutputSink) -> Bytes {
  let result = @blit.make_uninit(self.pos)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.pos)
  result.unsafe_reinterpret_as_bytes()
}
