///|
/// LzwStreamWriter compresses data using LZW and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// Compression happens on eod (empty write).
pub struct LzwStreamWriter {
  priv dest : &@stream.Writer
  priv order : BitOrder
  priv lit_width : Int
  priv slice_length : Int
  priv buf : @buffer.Buffer
  priv mut closed : Bool
}

///|
pub fn LzwStreamWriter::new(
  dest : &@stream.Writer,
  order : BitOrder,
  lit_width : Int,
  slice_length? : Int = 65536,
) -> LzwStreamWriter {
  { dest, order, lit_width, slice_length, buf: @buffer.new(), closed: false }
}

///|
pub impl @stream.Writer for LzwStreamWriter with write(self, data) {
  if data.is_empty() {
    if not(self.closed) {
      self.closed = true
      let input = self.buf.to_bytes()
      let compressed = compress(input, self.order, self.lit_width) catch {
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
  for i in 0..<data.length() {
    self.buf.write_byte(data[i])
  }
}
