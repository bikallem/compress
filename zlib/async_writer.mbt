///|
/// ZlibWriter wraps an `@io.Writer` and compresses data written to it
/// using zlib format, writing compressed output to the underlying writer on close.
pub struct ZlibWriter {
  dest : &@io.Writer
  level : @flate.CompressionLevel
  buf : @buffer.Buffer
  mut closed : Bool
}

///|
pub fn ZlibWriter::new(
  dest : &@io.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> ZlibWriter {
  { dest, level, buf: @buffer.new(), closed: false }
}

///|
pub async fn ZlibWriter::write(self : ZlibWriter, data : &@io.Data) -> Unit {
  let bytes = @flate.extract_data_bytes(data)
  for i in 0..<bytes.length() {
    self.buf.write_byte(bytes[i])
  }
}

///|
pub fn ZlibWriter::write_once(
  self : ZlibWriter,
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
pub async fn ZlibWriter::write_reader(
  self : ZlibWriter,
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
pub async fn ZlibWriter::close(self : ZlibWriter) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let compressed = compress(self.buf.to_bytes(), level=self.level)
  self.dest.write(compressed)
}

///|
pub impl @io.Writer for ZlibWriter with write(self, data) {
  self.write(data)
}

///|
pub impl @io.Writer for ZlibWriter with write_once(self, bytes, offset~, len~) {
  self.write_once(bytes, offset~, len~)
}

///|
pub impl @io.Writer for ZlibWriter with write_reader(self, reader) {
  self.write_reader(reader)
}
