///|
/// Reads Brotli data from `reader`, decompresses it, and writes raw bytes to
/// `writer`.
pub async fn decompress(reader : &@io.Reader, writer : &@io.Writer) -> Unit {
  let inflater = @brotli.Inflater::new()
  let buf = FixedArray::make(32768, b'\x00')
  while true {
    match inflater.decode() {
      Await => {
        let n = reader.read(buf)
        if n == 0 {
          raise @brotli.BrotliError::UnexpectedEOF
        }
        inflater.src(Bytes::makei(n, fn(i) { buf[i] })[:])
      }
      Data(out) => writer.write(out)
      End => return
      Error(e) => raise e
    }
  }
}
