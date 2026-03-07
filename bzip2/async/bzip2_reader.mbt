///|
/// Bzip2Reader wraps an `@io.Reader` of bzip2-compressed data
/// and provides an `@io.Reader` that returns decompressed data.
pub struct Bzip2Reader {
  source : &@io.Reader
  mut decompressed : Bytes
  mut pos : Int
  mut done : Bool
  reader_buf : @io.ReaderBuffer
}

///|
pub fn Bzip2Reader::new(source : &@io.Reader) -> Bzip2Reader {
  {
    source,
    decompressed: Bytes::default(),
    pos: 0,
    done: false,
    reader_buf: @io.ReaderBuffer::new(),
  }
}

///|
async fn Bzip2Reader::ensure_decompressed(self : Bzip2Reader) -> Unit {
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
  self.decompressed = @bzip2.decompress(buf.to_bytes())
  self.done = true
}

///|
pub async fn Bzip2Reader::_direct_read(
  self : Bzip2Reader,
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
pub fn Bzip2Reader::_get_internal_buffer(
  self : Bzip2Reader,
) -> @io.ReaderBuffer {
  self.reader_buf
}

///|
pub impl @io.Reader for Bzip2Reader with _direct_read(
  self,
  buf,
  offset~,
  max_len~,
) {
  self._direct_read(buf, offset~, max_len~)
}

///|
pub impl @io.Reader for Bzip2Reader with _get_internal_buffer(self) {
  self._get_internal_buffer()
}
