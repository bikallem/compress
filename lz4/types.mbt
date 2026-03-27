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
/// Maximum uncompressed block size for LZ4 frames.
pub(all) enum BlockMaxSize {
  Size64KB
  Size256KB
  Size1MB
  Size4MB
} derive(Show, Eq)

///|
/// Encoder options for LZ4 frames.
pub(all) struct FrameOptions {
  block_independence : Bool
  block_checksum : Bool
  content_checksum : Bool
  dict_id : UInt
  block_max_size : BlockMaxSize
} derive(Show, Eq)

///|
pub fn FrameOptions::default() -> FrameOptions {
  {
    block_independence: true,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0U,
    block_max_size: Size64KB,
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
fn block_max_size_id(size : BlockMaxSize) -> Int {
  match size {
    Size64KB => 4
    Size256KB => 5
    Size1MB => 6
    Size4MB => 7
  }
}

///|
fn block_max_size_bytes(size : BlockMaxSize) -> Int {
  max_block_sizes[block_max_size_id(size)]
}

///|
fn lz4_read_u32_le(data : BytesView, pos : Int) -> UInt {
  data.unsafe_get(pos).to_uint() |
  (data.unsafe_get(pos + 1).to_uint() << 8) |
  (data.unsafe_get(pos + 2).to_uint() << 16) |
  (data.unsafe_get(pos + 3).to_uint() << 24)
}

///|
fn lz4_read_u64_le(data : BytesView, pos : Int) -> UInt64 {
  data.unsafe_get(pos).to_uint().to_uint64() |
  (data.unsafe_get(pos + 1).to_uint().to_uint64() << 8) |
  (data.unsafe_get(pos + 2).to_uint().to_uint64() << 16) |
  (data.unsafe_get(pos + 3).to_uint().to_uint64() << 24) |
  (data.unsafe_get(pos + 4).to_uint().to_uint64() << 32) |
  (data.unsafe_get(pos + 5).to_uint().to_uint64() << 40) |
  (data.unsafe_get(pos + 6).to_uint().to_uint64() << 48) |
  (data.unsafe_get(pos + 7).to_uint().to_uint64() << 56)
}

///|
fn lz4_read_content_size(data : BytesView, pos : Int) -> Int raise Lz4Error {
  let raw = lz4_read_u64_le(data, pos)
  let size = raw.to_int()
  guard size >= 0 && size.reinterpret_as_uint().to_uint64() == raw else {
    raise Lz4Error::InvalidHeader("content size exceeds supported range")
  }
  size
}

///|
fn lz4_dictionary_prefix(dict : Bytes) -> Bytes {
  let keep = if dict.length() > 65535 { 65535 } else { dict.length() }
  Bytes::makei(keep, fn(i) { dict[dict.length() - keep + i] })
}

///|
fn normalize_lz4_frame_options(
  dict_prefix : Bytes,
  options : FrameOptions,
) -> FrameOptions {
  let dict_id = if dict_prefix.length() == 0 {
    0U
  } else if options.dict_id != 0U {
    options.dict_id
  } else {
    let derived = @checksum.xxh32(dict_prefix[:])
    if derived == 0U {
      1U
    } else {
      derived
    }
  }
  {
    block_independence: options.block_independence,
    block_checksum: options.block_checksum,
    content_checksum: options.content_checksum,
    dict_id,
    block_max_size: options.block_max_size,
  }
}
