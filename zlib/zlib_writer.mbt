///|
/// ZlibStreamWriter compresses data using zlib format and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// Compression happens on eod (empty write).
pub struct ZlibStreamWriter {
  priv dest : &@stream.Writer
  priv level : @flate.CompressionLevel
  priv dict : Bytes
  priv slice_length : Int
  priv buf : @buffer.Buffer
  priv mut closed : Bool
}

///|
pub fn ZlibStreamWriter::new(
  dest : &@stream.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
  slice_length? : Int = 65536,
) -> ZlibStreamWriter {
  { dest, level, dict, slice_length, buf: @buffer.new(), closed: false }
}

///|
pub impl @stream.Writer for ZlibStreamWriter with write(self, data) {
  if data.is_empty() {
    if not(self.closed) {
      self.closed = true
      let input = self.buf.to_bytes()
      let compressed = compress_with_dict(input, self.dict, level=self.level) catch {
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
