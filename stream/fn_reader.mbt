///|
/// Reads via a fill callback. Owns a reusable `FixedArray[Byte]` buffer.
/// The callback fills the buffer and returns the number of bytes written.
/// Returns 0 to signal end of data.
struct FnReader {
  buf : FixedArray[Byte]
  fill : (FixedArray[Byte]) -> Int raise StreamError
}

///|
pub fn FnReader::new(
  slice_length? : Int = DEFAULT_SLICE_LENGTH,
  fill : (FixedArray[Byte]) -> Int raise StreamError,
) -> FnReader {
  { buf: FixedArray::make(slice_length, b'\x00'), fill }
}

///|
pub impl Reader for FnReader with read(self) {
  let n = (self.fill)(self.buf)
  if n == 0 {
    return b""[:]
  }
  self.buf.unsafe_reinterpret_as_bytes()[0:n]
}
