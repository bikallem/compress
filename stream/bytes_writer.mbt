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
pub impl Writer for BytesWriter with write(self, data_chunk) {
  if data_chunk.is_empty() {
    return
  }
  let buf_len = self.buf.length()
  let chunk_len = data_chunk.length()
  let need = self.data_len + chunk_len
  if need > buf_len {
    let new_cap = if need > buf_len * 2 { need } else { buf_len * 2 }
    let new_buf = @blit.make_uninit(new_cap)
    @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.data_len)
    self.buf = new_buf
  }
  self.buf.blit_from_bytesview(self.data_len, data_chunk)
  self.data_len += chunk_len
}
