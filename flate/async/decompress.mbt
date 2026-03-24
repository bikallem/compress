///|
/// Reads DEFLATE-compressed data from `reader`, decompresses it, and writes
/// the decompressed stream to `writer`.
pub async fn decompress(
  reader : &@io.Reader,
  writer : &@io.Writer,
  dict? : Bytes,
) -> Unit {
  let inf = match dict {
    Some(d) => @flate.Inflater::new(dict=d)
    None => @flate.Inflater::new()
  }
  let buf = FixedArray::make(32768, b'\x00')
  loop inf.decode() {
    Await => {
      let n = reader.read(buf)
      if n == 0 {
        raise @flate.CompressError::UnexpectedEOF
      }
      inf.src(buf.unsafe_reinterpret_as_bytes()[:n])
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
