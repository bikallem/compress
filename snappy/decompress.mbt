///|
/// Decompresses Snappy-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise SnappyError {
  let inf = Inflater::new()
  inf.src(data[:])
  let capacity = (data.length() * 2).max(256)
  inf.enable_direct_output(capacity)
  loop inf.decode() {
    Await => raise SnappyError::UnexpectedEOF
    Data(_) => continue inf.decode()
    End => inf.take_output()
    Error(e) => raise e
  }
}
