///|
/// Zstandard compression error type.
pub(all) suberror ZstdError {
  InvalidHeader(String)
  CorruptData(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  WindowTooLarge(String)
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
  Error(ZstdError)
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
  Error(ZstdError)
} derive(Show)

///|
/// Compression level for Zstandard.
pub(all) enum CompressionLevel {
  Fast
  Default
  Best
  Level(Int)
} derive(Eq, Show)

///|
/// Zstandard frame magic number.
const ZSTD_MAGIC : UInt = 0xFD2FB528_U

///|
/// Block types in Zstandard.
const BLOCK_TYPE_RAW : Int = 0

///|
const BLOCK_TYPE_RLE : Int = 1

///|
const BLOCK_TYPE_COMPRESSED : Int = 2

///|
/// Maximum window size we support (8 MB).
const MAX_WINDOW_SIZE : Int = 8388608

///|
/// Maximum block size (128 KB).
const MAX_BLOCK_SIZE : Int = 131072

///|
/// Hash table size for compression.
const ZSTD_HASH_SIZE : Int = 1 << 14

///|
const ZSTD_HASH_MASK : Int = ZSTD_HASH_SIZE - 1

///|
/// Minimum match length for zstd.
const ZSTD_MIN_MATCH : Int = 3
