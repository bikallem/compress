///|
/// Reads raw data from `reader`, compresses it using gzip format, and writes
/// the compressed stream to `writer`.
pub async fn compress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : @gzip.Header,
) -> Unit {
  let def = match header {
    Some(h) => @gzip.Deflater::new(level~, header=h)
    None => @gzip.Deflater::new(level~)
  }
  let buf = FixedArray::make(32768, b'\x00')
  while true {
    let n = reader.read(buf)
    if n == 0 {
      break
    }
    let chunk = Bytes::makei(n, fn(i) { buf[i] })
    match def.encode(Some(chunk)) {
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
