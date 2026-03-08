///|
/// Pull from reader, push to writer, chunk by chunk until eod.
pub fn pipe(reader : &Reader, writer : &Writer) -> Unit raise StreamError {
  while true {
    let chunk = reader.read()
    writer.write(chunk)
    if chunk.is_empty() {
      break
    }
  }
}

///|
/// Drain reader into `Bytes`.
pub fn read_all(reader : &Reader) -> Bytes raise StreamError {
  let buf = @buffer.new()
  while true {
    let chunk = reader.read()
    if chunk.is_empty() {
      break
    }
    buf.write_bytesview(chunk)
  }
  buf.to_bytes()
}
