///|
/// InflateReader wraps an `@io.Reader` of DEFLATE-compressed data
/// and provides an `@io.Reader` that returns decompressed data.
pub struct InflateReader {
  source : &@io.Reader
  dict : Bytes
  mut decompressed : Bytes
  mut pos : Int
  mut done : Bool
  reader_buf : @io.ReaderBuffer
}

///|
pub fn InflateReader::new(
  source : &@io.Reader,
  dict? : Bytes = Bytes::default(),
) -> InflateReader {
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
async fn InflateReader::ensure_decompressed(self : InflateReader) -> Unit {
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
    @flate.decompress_with_dict(compressed, self.dict)
  } else {
    @flate.decompress(compressed)
  }
  self.done = true
}

///|
pub async fn InflateReader::_direct_read(
  self : InflateReader,
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
pub fn InflateReader::_get_internal_buffer(
  self : InflateReader,
) -> @io.ReaderBuffer {
  self.reader_buf
}

///|
pub impl @io.Reader for InflateReader with _direct_read(
  self,
  buf,
  offset~,
  max_len~,
) {
  self._direct_read(buf, offset~, max_len~)
}

///|
pub impl @io.Reader for InflateReader with _get_internal_buffer(self) {
  self._get_internal_buffer()
}
