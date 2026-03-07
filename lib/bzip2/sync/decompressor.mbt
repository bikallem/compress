///|
/// Bzip2Decompressor provides sync streaming bzip2 decompression.
pub struct Bzip2Decompressor {
  buf : @buffer.Buffer
}

///|
pub fn Bzip2Decompressor::new() -> Bzip2Decompressor {
  { buf: @buffer.new() }
}

///|
pub fn Bzip2Decompressor::update(
  self : Bzip2Decompressor,
  chunk : Bytes,
) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn Bzip2Decompressor::finish(
  self : Bzip2Decompressor,
) -> Bytes raise @bzip2.Bzip2Error {
  @bzip2.decompress(self.buf.to_bytes())
}
