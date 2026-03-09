///|
/// Errors that can occur during I/O operations.
pub(all) suberror IoError {
  UnexpectedEod
  Io(String)
}

///|
///a
pub impl Show for IoError with output(self, logger) {
  match self {
    UnexpectedEod => logger.write_string("IoError: unexpected end of data")
    Io(message) => logger.write_string("IoError: io error: \{message}")
  }
}

///|
/// Pull-based byte Reader.
///
/// `read()` returns a `BytesView` into an internal buffer. The returned view
/// is only valid until the next `read()` call (borrow-invalidate pattern).
/// An empty `BytesView` (length 0) signals end of data.
pub(open) trait Reader {
  async read(Self) -> BytesView raise IoError
  async read_byte(Self) -> Byte raise IoError
}

///|
/// Push-based byte Writer.
///
/// `write()` accepts a `BytesView` of data to process.
/// An empty `BytesView` (length 0) signals end of data.
pub(open) trait Writer {
  async write(Self, BytesView) -> Unit raise IoError
  async write_byte(Self, Byte) -> Unit raise IoError
}
