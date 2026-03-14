///|
/// Reads LZW-compressed data from `reader`, decompresses it, and writes
/// the decompressed stream to `writer`.
pub async fn decompress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> Unit {
  let inf = @lzw.Inflater::new(order, lit_width)
  let buf = FixedArray::make(32768, b'\x00')
  loop inf.decode() {
    Await => {
      let n = reader.read(buf)
      if n == 0 {
        raise @lzw.LzwError::UnexpectedEOF
      }
      let chunk = Bytes::makei(n, fn(i) { buf[i] })
      inf.src(chunk)
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
