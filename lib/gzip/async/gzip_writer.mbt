///|
/// GzipWriter wraps an `@io.Writer` and compresses data written to it
/// using gzip format, writing compressed output to the underlying writer on close.
pub struct GzipWriter {
  dest : &@io.Writer
  level : @flate.CompressionLevel
  header : @gzip.Header
  buf : @buffer.Buffer
  mut closed : Bool
}

///|
pub fn GzipWriter::new(
  dest : &@io.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : @gzip.Header = { ..@gzip.Header::default() },
) -> GzipWriter {
  { dest, level, header, buf: @buffer.new(), closed: false }
}

///|
pub async fn GzipWriter::write(self : GzipWriter, data : &@io.Data) -> Unit {
  let bytes = extract_data_bytes(data)
  for i in 0..<bytes.length() {
    self.buf.write_byte(bytes[i])
  }
}

///|
pub async fn GzipWriter::write_once(
  self : GzipWriter,
  bytes : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  for i in 0..<len {
    self.buf.write_byte(bytes[offset + i])
  }
  len
}

///|
pub async fn GzipWriter::write_reader(
  self : GzipWriter,
  reader : &@io.Reader,
) -> Unit {
  while true {
    let chunk = reader.read_some()
    guard chunk is Some(bytes) else { break }
    for i in 0..<bytes.length() {
      self.buf.write_byte(bytes[i])
    }
  }
}

///|
pub async fn GzipWriter::close(self : GzipWriter) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let compressed = @gzip.compress(
    self.buf.to_bytes(),
    level=self.level,
    header=self.header,
  )
  self.dest.write(compressed)
}

///|
pub impl @io.Writer for GzipWriter with write(self, data) {
  self.write(data)
}

///|
pub impl @io.Writer for GzipWriter with write_once(self, bytes, offset~, len~) {
  self.write_once(bytes, offset~, len~)
}

///|
pub impl @io.Writer for GzipWriter with write_reader(self, reader) {
  self.write_reader(reader)
}
