///|
/// GzipCompressor provides sync streaming gzip compression.
pub struct GzipCompressor {
  level : @flate.CompressionLevel
  header : @gzip.Header
  buf : @buffer.Buffer
}

///|
pub fn GzipCompressor::new(
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : @gzip.Header = { ..@gzip.Header::default() },
) -> GzipCompressor {
  { level, header, buf: @buffer.new() }
}

///|
pub fn GzipCompressor::update(self : GzipCompressor, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn GzipCompressor::finish(
  self : GzipCompressor,
) -> Bytes raise @gzip.GzipError {
  @gzip.compress(self.buf.to_bytes(), level=self.level, header=self.header)
}
