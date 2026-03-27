///|
/// Reads raw data from `reader`, compresses it using LZ4 frame format, and writes
/// the compressed stream to `writer`.
pub async fn compress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  options? : @lz4.FrameOptions = { ..@lz4.FrameOptions::default() },
) -> Unit {
  let def = @lz4.Deflater::new(options~)
  let buf = FixedArray::make(32768, b'\x00')
  while true {
    let n = reader.read(buf)
    if n == 0 {
      break
    }
    let chunk = Bytes::makei(n, fn(i) { buf[i] })
    match def.encode(Some(chunk[:])) {
      Data(out) => writer.write(out)
      Ok => ()
      End => return
      Error(e) => raise e
    }
  }
  match def.encode(None) {
    Data(out) => writer.write(out)
    End | Ok => ()
    Error(e) => raise e
  }
}
