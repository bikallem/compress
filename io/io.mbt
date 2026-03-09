///|
/// Errors that can occur during stream operations.
pub(all) suberror IoError {
  UnexpectedEod
  Format(String)
  Io(String)
}

///|
///a
pub impl Show for IoError with output(self, logger) {
  match self {
    UnexpectedEod => logger.write_string("IoError: unexpected end of data")
    Format(message) => logger.write_string("IoError: format error: \{message}")
    Io(message) => logger.write_string("IoError: io error: \{message}")
  }
}

///|
/// Pull-based byte stream.
///
/// `read()` returns a `BytesView` into an internal buffer. The returned view
/// is only valid until the next `read()` call (borrow-invalidate pattern).
/// An empty `BytesView` (length 0) signals end of data.
pub(open) trait Reader {
  async read(Self) -> BytesView raise IoError
}

///|
/// Push-based byte stream.
///
/// `write()` accepts a `BytesView` of data to process.
/// An empty `BytesView` (length 0) signals end of data.
pub(open) trait Writer {
  async write(Self, BytesView) -> Unit raise IoError
}
