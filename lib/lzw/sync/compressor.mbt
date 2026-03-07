///|
/// LzwCompressor provides sync streaming LZW compression.
pub struct LzwCompressor {
  order : @lzw.BitOrder
  lit_width : Int
  buf : @buffer.Buffer
}

///|
pub fn LzwCompressor::new(
  order : @lzw.BitOrder,
  lit_width : Int,
) -> LzwCompressor {
  { order, lit_width, buf: @buffer.new() }
}

///|
pub fn LzwCompressor::update(self : LzwCompressor, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn LzwCompressor::finish(self : LzwCompressor) -> Bytes raise @lzw.LzwError {
  @lzw.compress(self.buf.to_bytes(), self.order, self.lit_width)
}
