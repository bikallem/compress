///|
const DEFAULT_SIZE_HINT : Int = 1024

///|
#warnings("-alert_internal")
pub struct BytesReader {
  data : Bytes
  mut offset : Int
  read_buf : @io.ReaderBuffer
}

///|
#warnings("-alert_internal")
pub fn BytesReader::new(data : Bytes) -> BytesReader {
  { data, offset: 0, read_buf: @io.ReaderBuffer::new() }
}

///|
pub impl @io.Reader for BytesReader with _get_internal_buffer(self) {
  self.read_buf
}

///|
pub impl @io.Reader for BytesReader with _direct_read(
  self,
  dst,
  offset~,
  max_len~,
) {
  let remaining = self.data.length() - self.offset
  if remaining <= 0 {
    return 0
  }
  let n = if remaining < max_len { remaining } else { max_len }
  dst.blit_from_bytes(offset, self.data, self.offset, n)
  self.offset += n
  n
}
