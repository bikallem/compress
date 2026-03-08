///|
/// GzipStreamWriter compresses data using gzip format and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// Compression happens on eod (empty write).
pub struct GzipStreamWriter {
  priv dest : &@stream.Writer
  priv level : @flate.CompressionLevel
  priv header : Header
  priv slice_length : Int
  priv buf : @buffer.Buffer
  priv mut closed : Bool
}

///|
pub fn GzipStreamWriter::new(
  dest : &@stream.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : Header = { ..Header::default() },
  slice_length? : Int = 65536,
) -> GzipStreamWriter {
  { dest, level, header, slice_length, buf: @buffer.new(), closed: false }
}

///|
pub impl @stream.Writer for GzipStreamWriter with write(self, data) {
  if data.is_empty() {
    if not(self.closed) {
      self.closed = true
      let input = self.buf.to_bytes()
      let compressed = compress(input, level=self.level, header=self.header) catch {
        e => raise @stream.StreamError::Format(e.to_string())
      }
      let mut offset = 0
      while offset < compressed.length() {
        let avail = compressed.length() - offset
        let n = if avail < self.slice_length {
          avail
        } else {
          self.slice_length
        }
        self.dest.write(compressed[offset:offset + n])
        offset += n
      }
      self.dest.write(b""[:])
    }
    return
  }
  self.buf.write_bytesview(data)
}
