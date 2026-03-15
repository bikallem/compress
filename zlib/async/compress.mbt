///|
/// Reads raw data from `reader`, compresses it using zlib format, and writes
/// the compressed stream to `writer`.
pub async fn compress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  dict? : Bytes,
) -> Unit {
  let def = match dict {
    Some(d) => @zlib.Deflater::new(level~, dict=d)
    None => @zlib.Deflater::new(level~)
  }
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
