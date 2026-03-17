///|
/// Reads raw data from `reader`, compresses it with Brotli, and writes the
/// encoded stream to `writer`.
pub async fn compress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  level? : @brotli.CompressionLevel = DefaultCompression,
) -> Unit {
  let deflater = @brotli.Deflater::new(level~)
  let buf = FixedArray::make(32768, b'\x00')
  while true {
    let n = reader.read(buf)
    if n == 0 {
      break
    }
    let chunk = Bytes::makei(n, fn(i) { buf[i] })
    match deflater.encode(Some(chunk[:])) {
      Data(out) => writer.write(out)
      Ok => ()
      End => return
      Error(e) => raise e
    }
  }
  match deflater.encode(None) {
    Data(out) => writer.write(out)
    End | Ok => ()
    Error(e) => raise e
  }
}
