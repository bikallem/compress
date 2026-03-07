///|
/// Deflater provides sync streaming DEFLATE compression.
/// Feed chunks via `update()`, get final output via `finish()`.
pub struct Deflater {
  level : @flate.CompressionLevel
  dict : Bytes
  buf : @buffer.Buffer
}

///|
/// Creates a new Deflater with the given compression level.
pub fn Deflater::new(
  level? : @flate.CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
) -> Deflater {
  { level, dict, buf: @buffer.new() }
}

///|
/// Appends a chunk of data to be compressed.
pub fn Deflater::update(self : Deflater, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
/// Finishes compression and returns the DEFLATE-compressed output.
pub fn Deflater::finish(self : Deflater) -> Bytes raise @flate.CompressError {
  let data = self.buf.to_bytes()
  if self.dict.length() > 0 {
    @flate.compress_with_dict(data, self.dict, level=self.level)
  } else {
    @flate.compress(data, level=self.level)
  }
}
