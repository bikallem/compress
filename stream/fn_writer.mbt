///|
/// Writes via a callback.
struct FnWriter {
  write_fn : (BytesView) -> Unit raise StreamError
}

///|
pub fn FnWriter::new(
  write_fn : (BytesView) -> Unit raise StreamError,
) -> FnWriter {
  { write_fn, }
}

///|
pub impl Writer for FnWriter with write(self, data) {
  (self.write_fn)(data)
}
