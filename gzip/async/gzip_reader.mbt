///|
/// GzipReader wraps an `@io.Reader` of gzip-compressed data
/// and provides an `@io.Reader` that returns decompressed data.
pub struct GzipReader {
  source : &@io.Reader
  mut decompressed : Bytes
  mut header : @gzip.Header
  mut pos : Int
  mut done : Bool
  reader_buf : @io.ReaderBuffer
}

///|
pub fn GzipReader::new(source : &@io.Reader) -> GzipReader {
  {
    source,
    decompressed: Bytes::default(),
    header: @gzip.Header::default(),
    pos: 0,
    done: false,
    reader_buf: @io.ReaderBuffer::new(),
  }
}

///|
async fn GzipReader::ensure_decompressed(self : GzipReader) -> Unit {
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
  let (data, header) = @gzip.decompress(buf.to_bytes())
  self.decompressed = data
  self.header = header
  self.done = true
}

///|
/// Returns the gzip header after decompression.
pub async fn GzipReader::header(self : GzipReader) -> @gzip.Header {
  self.ensure_decompressed()
  self.header
}

///|
pub async fn GzipReader::_direct_read(
  self : GzipReader,
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
pub fn GzipReader::_get_internal_buffer(self : GzipReader) -> @io.ReaderBuffer {
  self.reader_buf
}

///|
pub impl @io.Reader for GzipReader with _direct_read(
  self,
  buf,
  offset~,
  max_len~,
) {
  self._direct_read(buf, offset~, max_len~)
}

///|
pub impl @io.Reader for GzipReader with _get_internal_buffer(self) {
  self._get_internal_buffer()
}
