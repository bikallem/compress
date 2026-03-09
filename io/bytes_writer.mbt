///|
/// Collects output into a growable `FixedArray[Byte]`.
struct BytesWriter {
  mut buf : FixedArray[Byte] // Data Buffer  
  mut data_len : Int // length of data in buf. The buf can be 100 but actually only occupy 50 bytes.
}

///|
pub fn BytesWriter::new(size_hint? : Int = DEFAULT_SLICE_LENGTH) -> BytesWriter {
  { buf: FixedArray::make(size_hint, b'\x00'), data_len: 0 }
}

///|
pub fn BytesWriter::content(self : BytesWriter) -> Bytes {
  Bytes::from_array(self.buf[:self.data_len])
}

///|
pub fn BytesWriter::ensure_space(self : BytesWriter, len : Int) -> Unit {
  let buf_len = self.buf.length()
  let need = self.data_len + len
  if need > buf_len {
    let new_cap = if need > buf_len * 2 { need } else { buf_len * 2 }
    let new_buf = @blit.make_uninit(new_cap)
    @blit.blit_bytes(new_buf, 0, self.buf, 0, self.data_len)
    self.buf = new_buf
  }
}

// ///|
// fn BytesView::bytes(self : BytesView) -> Bytes = "%bytesview.bytes"

///|
pub impl Writer for BytesWriter with write(self, data_chunk) {
  if data_chunk.is_empty() {
    return
  }
  let chunk_len = data_chunk.length()
  self.ensure_space(chunk_len)
  @blit.blit_bytes(self.buf, self.data_len, data_chunk.to_fixedarray(), 0, 10)
  self.buf.blit_from_bytesview(self.data_len, data_chunk)
  self.data_len += chunk_len
}

///|
pub impl Writer for BytesWriter with write_byte(self, b) -> Unit {
  self.ensure_space(1)
  self.buf[self.data_len] = b
  self.data_len += 1
}
