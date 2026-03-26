///|
/// Reads bzip2-compressed data from `reader`, decompresses it, and writes
/// the decompressed stream to `writer`.
pub async fn decompress(reader : &@io.Reader, writer : &@io.Writer) -> Unit {
  let inf = @bzip2.Inflater::new()
  let buf = FixedArray::make(32768, b'\x00')
  loop inf.decode() {
    Await => {
      let n = reader.read(buf)
      if n == 0 {
        inf.finish()
        continue inf.decode()
      }
      let chunk = Bytes::makei(n, fn(i) { buf[i] })
      inf.src(chunk[:])
      continue inf.decode()
    }
    Data(out) => {
      writer.write(out)
      continue inf.decode()
    }
    End => ()
    Error(e) => raise e
  }
}
