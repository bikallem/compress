///|
/// Decompress Brotli-encoded data (RFC 7932).
pub fn decompress(data : Bytes) -> Bytes raise BrotliError {
  let d = Inflater::new()
  d.src(data[:])
  let capacity = (data.length() * 2).max(32768)
  d.enable_direct_output(capacity)
  loop d.decode() {
    Await => raise BrotliError::UnexpectedEOF
    Data(_) => continue d.decode()
    End => d.take_output()
    Error(e) => raise e
  }
}

///|
/// Compress data using Brotli (RFC 7932).
pub fn compress(data : Bytes, quality? : Int = 1) -> Bytes raise BrotliError {
  let e = Deflater::new(quality~)
  let buf = @buffer.new()
  match e.encode(Some(data[:])) {
    Encode::Ok | Encode::End => ()
    Encode::Data(chunk) => buf.write_bytes(chunk)
    Encode::Error(err) => raise err
  }
  match e.encode(None) {
    Encode::Ok | Encode::End => ()
    Encode::Data(chunk) => buf.write_bytes(chunk)
    Encode::Error(err) => raise err
  }
  buf.to_bytes()
}
