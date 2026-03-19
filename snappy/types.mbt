///|
/// Snappy compression error type.
pub(all) suberror SnappyError {
  CorruptInput(String)
  UnexpectedEOF
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
  Error(SnappyError)
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
  /// Unrecoverable format error.
  Error(SnappyError)
} derive(Show)

///|
/// Snappy tag types (encoded in the lower 2 bits of the tag byte).
const TAG_LITERAL : Int = 0x00

///|
const TAG_COPY1 : Int = 0x01

///|
const TAG_COPY2 : Int = 0x02

///|
let _TAG_COPY4 : Int = 0x03

///|
/// Maximum block size for Snappy encoding.
const MAX_BLOCK_SIZE : Int = 65536

///|
/// Hash table size for compression (must be power of 2).
const HASH_TABLE_SIZE : Int = 1 << 14

///|
const HASH_TABLE_MASK : Int = HASH_TABLE_SIZE - 1
