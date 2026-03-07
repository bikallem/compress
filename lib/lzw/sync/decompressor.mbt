///|
/// LzwDecompressor provides sync streaming LZW decompression.
pub struct LzwDecompressor {
  order : @lzw.BitOrder
  lit_width : Int
  buf : @buffer.Buffer
}

///|
pub fn LzwDecompressor::new(
  order : @lzw.BitOrder,
  lit_width : Int,
) -> LzwDecompressor {
  { order, lit_width, buf: @buffer.new() }
}

///|
pub fn LzwDecompressor::update(self : LzwDecompressor, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn LzwDecompressor::finish(
  self : LzwDecompressor,
) -> Bytes raise @lzw.LzwError {
  @lzw.decompress(self.buf.to_bytes(), self.order, self.lit_width)
}
