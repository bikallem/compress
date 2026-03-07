///|
/// LzwReader wraps an `@io.Reader` of LZW-compressed data
/// and provides an `@io.Reader` that returns decompressed data.
pub struct LzwReader {
  source : &@io.Reader
  order : @lzw.BitOrder
  lit_width : Int
  mut decompressed : Bytes
  mut pos : Int
  mut done : Bool
  reader_buf : @io.ReaderBuffer
}

///|
pub fn LzwReader::new(
  source : &@io.Reader,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> LzwReader {
  {
    source,
    order,
    lit_width,
    decompressed: Bytes::default(),
    pos: 0,
    done: false,
    reader_buf: @io.ReaderBuffer::new(),
  }
}

///|
async fn LzwReader::ensure_decompressed(self : LzwReader) -> Unit {
  if self.done {
    return
  }
  let buf = @buffer.new()
  while true {
    let chunk = self.source.read_some()
    guard chunk is Some(data) else { break }
    for i in 0..<data.length() {
      buf.write_byte(data[i])
    }
  }
  self.decompressed = @lzw.decompress(
    buf.to_bytes(),
    self.order,
    self.lit_width,
  )
  self.done = true
}

///|
pub async fn LzwReader::_direct_read(
  self : LzwReader,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  self.ensure_decompressed()
  let remaining = self.decompressed.length() - self.pos
  if remaining <= 0 {
    return 0
  }
  let to_read = if max_len < remaining { max_len } else { remaining }
  for i in 0..<to_read {
    buf[offset + i] = self.decompressed[self.pos + i]
  }
  self.pos += to_read
  to_read
}

///|
pub fn LzwReader::_get_internal_buffer(self : LzwReader) -> @io.ReaderBuffer {
  self.reader_buf
}

///|
pub impl @io.Reader for LzwReader with _direct_read(
  self,
  buf,
  offset~,
  max_len~,
) {
  self._direct_read(buf, offset~, max_len~)
}

///|
pub impl @io.Reader for LzwReader with _get_internal_buffer(self) {
  self._get_internal_buffer()
}
