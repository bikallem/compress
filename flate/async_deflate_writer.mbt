///|
/// DeflateWriter wraps an `@io.Writer` and compresses data written to it
/// using DEFLATE, writing compressed output to the underlying writer on close.
pub struct DeflateWriter {
  dest : &@io.Writer
  level : CompressionLevel
  dict : Bytes
  buf : @buffer.Buffer
  mut closed : Bool
}

///|
pub fn DeflateWriter::new(
  dest : &@io.Writer,
  level? : CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
) -> DeflateWriter {
  { dest, level, dict, buf: @buffer.new(), closed: false }
}

///|
pub async fn DeflateWriter::write(
  self : DeflateWriter,
  data : &@io.Data,
) -> Unit {
  let bytes = extract_data_bytes(data)
  for i in 0..<bytes.length() {
    self.buf.write_byte(bytes[i])
  }
}

///|
pub fn DeflateWriter::write_once(
  self : DeflateWriter,
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
pub async fn DeflateWriter::write_reader(
  self : DeflateWriter,
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
/// Compresses all buffered data and writes to the underlying writer.
pub async fn DeflateWriter::close(self : DeflateWriter) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let data = self.buf.to_bytes()
  let compressed = if self.dict.length() > 0 {
    compress_with_dict(data, self.dict, level=self.level)
  } else {
    compress(data, level=self.level)
  }
  self.dest.write(compressed)
}

///|
pub impl @io.Writer for DeflateWriter with write(self, data) {
  self.write(data)
}

///|
pub impl @io.Writer for DeflateWriter with write_once(
  self,
  bytes,
  offset~,
  len~,
) {
  self.write_once(bytes, offset~, len~)
}

///|
pub impl @io.Writer for DeflateWriter with write_reader(self, reader) {
  self.write_reader(reader)
}

///|
pub async fn extract_data_bytes(data : &@io.Data) -> Bytes {
  let buf = @buffer.new()
  let (r, w) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      defer w.close()
      w.write(data)
    })
    while true {
      let chunk = r.read_some()
      guard chunk is Some(bytes) else { break }
      for i in 0..<bytes.length() {
        buf.write_byte(bytes[i])
      }
    }
  })
  buf.to_bytes()
}
