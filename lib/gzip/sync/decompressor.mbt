///|
/// GzipDecompressor provides sync streaming gzip decompression.
pub struct GzipDecompressor {
  buf : @buffer.Buffer
}

///|
pub fn GzipDecompressor::new() -> GzipDecompressor {
  { buf: @buffer.new() }
}

///|
pub fn GzipDecompressor::update(self : GzipDecompressor, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn GzipDecompressor::finish(
  self : GzipDecompressor,
) -> (Bytes, @gzip.Header) raise @gzip.GzipError {
  @gzip.decompress(self.buf.to_bytes())
}
