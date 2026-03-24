///|
/// Reads raw data from `reader`, compresses it using DEFLATE, and writes
/// the compressed stream to `writer`.
pub async fn compress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Unit {
  let def = @flate.Deflater::new(level~)
  let buf = FixedArray::make(32768, b'\x00')
  // Feed input chunks
  while true {
    let n = reader.read(buf)
    if n == 0 {
      break
    }
    match def.encode(Some(buf.unsafe_reinterpret_as_bytes()[:n])) {
      Data(out) => writer.write(out)
      Ok => ()
      End => return
      Error(e) => raise e
    }
  }
  // Finalize
  match def.encode(None) {
    Data(out) => writer.write(out)
    End | Ok => ()
    Error(e) => raise e
  }
}
