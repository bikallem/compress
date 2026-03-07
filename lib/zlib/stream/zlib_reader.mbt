///|
/// ZlibReader wraps an `@io.Reader` of zlib-compressed data
/// and provides an `@io.Reader` that returns decompressed data.
pub struct ZlibReader {
  source : &@io.Reader
  dict : Bytes
  mut decompressed : Bytes
  mut pos : Int
  mut done : Bool
  reader_buf : @io.ReaderBuffer
}

///|
pub fn ZlibReader::new(
  source : &@io.Reader,
  dict? : Bytes = Bytes::default(),
) -> ZlibReader {
  {
    source,
    dict,
    decompressed: Bytes::default(),
    pos: 0,
    done: false,
    reader_buf: @io.ReaderBuffer::new(),
  }
}

///|
async fn ZlibReader::ensure_decompressed(self : ZlibReader) -> Unit {
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
  let compressed = buf.to_bytes()
  self.decompressed = if self.dict.length() > 0 {
    @zlib.decompress_with_dict(compressed, self.dict)
  } else {
    @zlib.decompress(compressed)
  }
  self.done = true
}

///|
pub async fn ZlibReader::_direct_read(
  self : ZlibReader,
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
pub fn ZlibReader::_get_internal_buffer(self : ZlibReader) -> @io.ReaderBuffer {
  self.reader_buf
}

///|
pub impl @io.Reader for ZlibReader with _direct_read(
  self,
  buf,
  offset~,
  max_len~,
) {
  self._direct_read(buf, offset~, max_len~)
}

///|
pub impl @io.Reader for ZlibReader with _get_internal_buffer(self) {
  self._get_internal_buffer()
}
