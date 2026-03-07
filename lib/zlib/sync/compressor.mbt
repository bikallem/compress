///|
/// ZlibCompressor provides sync streaming zlib compression.
pub struct ZlibCompressor {
  level : @flate.CompressionLevel
  buf : @buffer.Buffer
}

///|
pub fn ZlibCompressor::new(
  level? : @flate.CompressionLevel = DefaultCompression,
) -> ZlibCompressor {
  { level, buf: @buffer.new() }
}

///|
pub fn ZlibCompressor::update(self : ZlibCompressor, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn ZlibCompressor::finish(
  self : ZlibCompressor,
) -> Bytes raise @zlib.ZlibError {
  @zlib.compress(self.buf.to_bytes(), level=self.level)
}
