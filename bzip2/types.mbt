///|
/// Bzip2Error represents errors during bzip2 decompression.
pub(all) suberror Bzip2Error {
  InvalidHeader(String)
  CorruptData(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  UnexpectedEOF
} derive(Show)

///|
// bzip2 magic bytes: "BZ"
const BZIP2_MAGIC1 : Byte = b'B'

///|
const BZIP2_MAGIC2 : Byte = b'Z'

///|
/// Decoder signals — returned by Inflater::decode().
pub(all) enum Decode {
  /// Need input. Call src(bytes), or finish() if the source reached EOF, then decode() again.
  Await
  /// Produced output. Consume it, then decode() again.
  Data(BytesView)
  /// Stream complete.
  End
  /// Unrecoverable format error.
  Error(Bzip2Error)
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
  Error(Bzip2Error)
} derive(Show)
