///|
/// Collects output into a growable `FixedArray[Byte]`. Extract result with `to_bytes()`.
struct BytesWriter {
  mut buf : FixedArray[Byte]
  mut len : Int
}

///|
pub fn BytesWriter::new(size_hint? : Int = DEFAULT_SLICE_LENGTH) -> BytesWriter {
  { buf: FixedArray::make(size_hint, b'\x00'), len: 0 }
}

///|
pub fn BytesWriter::to_bytes(self : BytesWriter) -> Bytes {
  self.buf.unsafe_reinterpret_as_bytes()[:self.len].to_bytes()
}

///|
pub impl Writer for BytesWriter with write(self, data) {
  if data.is_empty() {
    return
  }
  let need = self.len + data.length()
  if need > self.buf.length() {
    let new_cap = if need > self.buf.length() * 2 {
      need
    } else {
      self.buf.length() * 2
    }
    let new_buf = FixedArray::make(new_cap, b'\x00')
    @blit.blit_bytes(new_buf, 0, self.buf, 0, self.len)
    self.buf = new_buf
  }
  for i in 0..<data.length() {
    self.buf[self.len + i] = data[i]
  }
  self.len += data.length()
}
