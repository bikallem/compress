///|
/// LzwWriter wraps an `@io.Writer` and compresses data written to it
/// using LZW, writing compressed output to the underlying writer on close.
pub struct LzwWriter {
  dest : &@io.Writer
  order : @lzw.BitOrder
  lit_width : Int
  buf : @buffer.Buffer
  mut closed : Bool
}

///|
pub fn LzwWriter::new(
  dest : &@io.Writer,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> LzwWriter {
  { dest, order, lit_width, buf: @buffer.new(), closed: false }
}

///|
pub async fn LzwWriter::write(self : LzwWriter, data : &@io.Data) -> Unit {
  let bytes = extract_data_bytes(data)
  for i in 0..<bytes.length() {
    self.buf.write_byte(bytes[i])
  }
}

///|
pub async fn LzwWriter::write_once(
  self : LzwWriter,
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
pub async fn LzwWriter::write_reader(
  self : LzwWriter,
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
pub async fn LzwWriter::close(self : LzwWriter) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let compressed = @lzw.compress(
    self.buf.to_bytes(),
    self.order,
    self.lit_width,
  )
  self.dest.write(compressed)
}

///|
pub impl @io.Writer for LzwWriter with write(self, data) {
  self.write(data)
}

///|
pub impl @io.Writer for LzwWriter with write_once(self, bytes, offset~, len~) {
  self.write_once(bytes, offset~, len~)
}

///|
pub impl @io.Writer for LzwWriter with write_reader(self, reader) {
  self.write_reader(reader)
}
