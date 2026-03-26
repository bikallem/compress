///|
/// LZ4 compression error type.
pub(all) suberror Lz4Error {
  InvalidHeader(String)
  CorruptData(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  ContentSizeMismatch
  UnexpectedEOF
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
  Error(Lz4Error)
} derive(Show)

///|
/// Decoder signals — returned by Inflater::decode().
pub(all) enum Decode {
  /// Need input. Call src(bytes) then decode() again.
  Await
  /// Produced output. Consume it, then decode() again.
  Data(BytesView)
  /// Stream complete.
  End
  /// Unrecoverable format error.
  Error(Lz4Error)
} derive(Show)

///|
/// Encoder options for LZ4 frames.
pub(all) struct FrameOptions {
  block_independence : Bool
  block_checksum : Bool
  content_checksum : Bool
  dict_id : UInt
} derive(Show, Eq)

///|
pub fn FrameOptions::default() -> FrameOptions {
  {
    block_independence: true,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0U,
  }
}

///|
/// LZ4 frame magic number.
const LZ4_FRAME_MAGIC : UInt = 0x184D2204_U

///|
/// Minimum match length in LZ4.
const MIN_MATCH : Int = 4

///|
/// Hash table size for compression (power of 2).
const LZ4_HASH_SIZE : Int = 1 << 14

///|
const LZ4_HASH_MASK : Int = LZ4_HASH_SIZE - 1

///|
/// Maximum block sizes by index (from frame descriptor BD byte).
/// Index 4=64KB, 5=256KB, 6=1MB, 7=4MB
let max_block_sizes : FixedArray[Int] = [
  0, 0, 0, 0, 65536, 262144, 1048576, 4194304,
]

///|
/// Default max block size index (4 = 64KB).
const DEFAULT_BLOCK_MAX_SIZE_ID : Int = 4
