///|
/// DeflateWriter compresses data using DEFLATE and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// Compression happens on eod (empty write). Currently buffers input
/// internally; compressed output is pushed to dest in bounded chunks.
pub struct DeflateWriter {
  priv dest : &@stream.Writer
  priv level : CompressionLevel
  priv dict : Bytes
  priv slice_length : Int
  priv buf : @buffer.Buffer
  priv mut closed : Bool
}

///|
pub fn DeflateWriter::new(
  dest : &@stream.Writer,
  level? : CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
  slice_length? : Int = 65536,
) -> DeflateWriter {
  { dest, level, dict, slice_length, buf: @buffer.new(), closed: false }
}

///|
pub impl @stream.Writer for DeflateWriter with write(self, data) {
  if data.is_empty() {
    // eod: compress buffered data and push to dest
    if not(self.closed) {
      self.closed = true
      let input = self.buf.to_bytes()
      let compressed = try {
        if self.dict.length() > 0 {
          compress_with_dict(input, self.dict, level=self.level)
        } else {
          compress(input, level=self.level)
        }
      } catch {
        e => raise @stream.StreamError::Format(e.to_string())
      }
      // Push compressed output in bounded chunks
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
      // Forward eod to dest
      self.dest.write(b""[:])
    }
    return
  }
  self.buf.write_bytesview(data)
}
