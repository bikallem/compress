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
/// CMF byte: compression method (lower 4 bits) and compression info (upper 4 bits).
/// For deflate: method = 8, info = log2(window_size) - 8 (max 7 = 32K window).
const ZLIB_DEFLATE_METHOD : Int = 8

///|
/// Default window size exponent for deflate (32KB = 2^15, so CINFO = 7).
const ZLIB_DEFAULT_CINFO : Int = 7
