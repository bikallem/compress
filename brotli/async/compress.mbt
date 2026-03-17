///|
/// Reads data from `reader`, compresses it with Brotli, and writes
/// the compressed stream to `writer`.
pub async fn compress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  quality? : Int = 1,
) -> Unit {
  let def = @brotli.Deflater::new(quality~)
  let buf = FixedArray::make(32768, b'\x00')
  // Read and compress chunks
  while true {
    let n = reader.read(buf)
    if n == 0 {
      break
    }
    let chunk = Bytes::makei(n, fn(i) { buf[i] })
    match def.encode(Some(chunk[:])) {
      Ok => ()
      End => break
      Data(out) => writer.write(out)
      Error(e) => raise e
    }
  }
  // Finalize
  match def.encode(None) {
    Ok | End => ()
    Data(out) => writer.write(out)
    Error(e) => raise e
  }
}
