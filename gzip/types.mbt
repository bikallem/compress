///|
/// GzipError represents errors during gzip compression/decompression.
pub(all) suberror GzipError {
  InvalidHeader(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  SizeMismatch(expected~ : UInt, got~ : UInt)
  DeflateError(String)
  UnexpectedEOF
} derive(Show)

///|
/// Header contains gzip file header metadata.
pub(all) struct Header {
  name : String
  comment : String
  extra : Bytes
  mod_time : UInt
  os : Byte
} derive(Show, Eq)

///|
/// Creates a default gzip header.
pub fn Header::default() -> Header {
  { name: "", comment: "", extra: Bytes::default(), mod_time: 0U, os: b'\xFF' }
}

///|
/// Decoder signals — returned by Inflater::decode().
pub(all) enum Decode {
  /// Need input. Call src(bytes) then decode() again.
  Await
  /// Produced output. Consume it, then decode() again.
  Data(BytesView)
  /// Stream complete.
  End
  /// Unrecoverable error.
  Error(GzipError)
} derive(Show)

///|
/// Encoder signals — returned by Deflater::encode().
pub(all) enum Encode {
  /// Input consumed. Call encode(Some(more)) or encode(None) to finish.
  Ok
  /// Produced output. Consume it, then call encode() again with same arg.
  Data(BytesView)
  /// Final output flushed. Encoding complete.
  End
  /// Unrecoverable error.
  Error(GzipError)
} derive(Show)

///|
// gzip magic bytes
const GZIP_MAGIC1 : Byte = 0x1F

///|
const GZIP_MAGIC2 : Byte = 0x8B

///|
// Compression method: deflate = 8
const GZIP_DEFLATE : Byte = 8

///|
const GZIP_FHCRC : Int = 2

///|
const GZIP_FEXTRA : Int = 4

///|
const GZIP_FNAME : Int = 8

///|
const GZIP_FCOMMENT : Int = 16
