///|
/// Reads a single byte from an async io.Reader.
/// Raises LzwError::UnexpectedEOF on end of stream.
async fn read_byte(src : &@io.Reader) -> Byte raise LzwError {
  let buf : FixedArray[Byte] = [0]
  let n = src.read(buf, max_len=1) catch { _ => raise LzwError::UnexpectedEOF }
  if n == 0 {
    raise LzwError::UnexpectedEOF
  }
  buf[0]
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
