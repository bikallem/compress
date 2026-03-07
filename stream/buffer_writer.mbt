///|
/// Collects output into a `Buffer`. Extract result with `to_bytes()`.
struct BufferWriter {
  buf : @buffer.Buffer
}

///|
pub fn BufferWriter::new(
  size_hint? : Int = DEFAULT_SLICE_LENGTH,
) -> BufferWriter {
  { buf: @buffer.new(size_hint~) }
}

///|
pub fn BufferWriter::to_bytes(self : BufferWriter) -> Bytes {
  self.buf.to_bytes()
}

///|
pub impl Writer for BufferWriter with write(self, data) {
  if data.is_empty() {
    return
  }
  for i in 0..<data.length() {
    self.buf.write_byte(data[i])
  }
}
