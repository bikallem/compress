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
/// Produce the final Bytes result. Single allocation.
pub fn OutputSink::to_bytes(self : OutputSink) -> Bytes {
  let result = @blit.make_uninit(self.pos)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.pos)
  result.unsafe_reinterpret_as_bytes()
}
