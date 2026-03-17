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
