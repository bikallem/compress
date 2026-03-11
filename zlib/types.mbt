///|
/// ZlibError represents errors during zlib compression/decompression.
pub suberror ZlibError {
  InvalidHeader(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  NeedDictionary(UInt)
  DeflateError(String)
  UnexpectedEOF
} derive(Show)

///|
/// Decoder signals — returned by Inflater::decode().
pub(all) enum Decode {
  /// Need input. Call src(bytes) then decode() again.
  Await
  /// Produced output. Consume it, then decode() again.
  Data(Bytes)
  /// Stream complete.
  End
  /// Unrecoverable error.
  Error(ZlibError)
} derive(Show)

///|
/// Encoder signals — returned by Deflater::encode().
pub(all) enum Encode {
  /// Input consumed. Call encode(Some(more)) or encode(None) to finish.
  Ok
  /// Produced output. Consume it, then call encode() again with same arg.
  Data(Bytes)
  /// Final output flushed. Encoding complete.
  End
  /// Unrecoverable error.
  Error(ZlibError)
} derive(Show)

///|
/// CMF byte: compression method (lower 4 bits) and compression info (upper 4 bits).
/// For deflate: method = 8, info = log2(window_size) - 8 (max 7 = 32K window).
const ZLIB_DEFLATE_METHOD : Int = 8

///|
/// Default window size exponent for deflate (32KB = 2^15, so CINFO = 7).
const ZLIB_DEFAULT_CINFO : Int = 7
