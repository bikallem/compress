///|
pub struct BytesWriter {
  mut buf : FixedArray[Byte]
  mut data_len : Int
}

///|
pub fn BytesWriter::new(size_hint? : Int = DEFAULT_SIZE_HINT) -> BytesWriter {
  let capacity = if size_hint <= 0 { DEFAULT_SIZE_HINT } else { size_hint }
  { buf: FixedArray::make(capacity, b'\x00'), data_len: 0 }
}

///|
pub fn BytesWriter::content(self : BytesWriter) -> Bytes {
  Bytes::from_array(self.buf[:self.data_len])
}

///|
fn BytesWriter::ensure_capacity(self : BytesWriter, len : Int) -> Unit {
  let need = self.data_len + len
  let current = self.buf.length()
  if need > current {
    let new_cap = if need > current * 2 { need } else { current * 2 }
    let new_buf = @blit.make_uninit(new_cap)
    @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.data_len)
    self.buf = new_buf
  }
}

///|
pub impl @io.Writer for BytesWriter with write_once(self, buf, offset~, len~) {
  if len == 0 {
    return 0
  }
  self.ensure_capacity(len)
  self.buf.blit_from_bytes(self.data_len, buf, offset, len)
  self.data_len += len
  len
}
