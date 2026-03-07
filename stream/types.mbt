///|
/// Errors that can occur during stream operations.
pub(all) suberror StreamError {
  UnexpectedEod
  Format(String)
  Io(String)
}

///|
pub impl Show for StreamError with output(self, logger) {
  match self {
    UnexpectedEod => logger.write_string("StreamError: unexpected end of data")
    Format(message) =>
      logger.write_string("StreamError: format error: \{message}")
    Io(message) => logger.write_string("StreamError: io error: \{message}")
  }
}

///|
/// Pull-based byte stream.
///
/// `read()` returns a `BytesView` into an internal buffer. The returned view
/// is only valid until the next `read()` call (borrow-invalidate pattern).
/// An empty `BytesView` (length 0) signals end of data.
pub(open) trait Reader {
  read(Self) -> BytesView raise StreamError
}

///|
/// Push-based byte stream.
///
/// `write()` accepts a `BytesView` of data to process.
/// An empty `BytesView` (length 0) signals end of data.
pub(open) trait Writer {
  write(Self, BytesView) -> Unit raise StreamError
}
