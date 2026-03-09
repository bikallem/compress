///|
const READ_BUF_SIZE = 65536

///|
/// Buffered byte reader wrapping an async @io.Reader.
/// Amortizes read() calls by reading chunks.
priv struct BufReader {
  src : &@io.Reader
  buf : FixedArray[Byte]
  mut pos : Int
  mut len : Int
}

///|
fn BufReader::new(src : &@io.Reader) -> BufReader {
  { src, buf: FixedArray::make(READ_BUF_SIZE, b'\x00'), pos: 0, len: 0 }
}

///|
/// Reads a single byte, refilling the buffer as needed.
async fn BufReader::read_byte(self : BufReader) -> Byte raise LzwError {
  if self.pos >= self.len {
    let n = self.src.read(self.buf) catch { _ => raise LzwError::UnexpectedEOF }
    if n == 0 {
      raise LzwError::UnexpectedEOF
    }
    self.pos = 0
    self.len = n
  }
  let b = self.buf[self.pos]
  self.pos += 1
  b
}

///|
/// Writes bytes from a Buffer to an async io.Writer, then resets the buffer.
async fn flush_buffer(
  dst : &@io.Writer,
  buf : @buffer.Buffer,
) -> Unit raise LzwError {
  let bytes = buf.to_bytes()
  if bytes.length() > 0 {
    dst.write(bytes) catch {
      _ => raise LzwError::InvalidCode("write error")
    }
    buf.reset()
  }
}
