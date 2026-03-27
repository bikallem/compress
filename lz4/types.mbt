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
/// External dictionary metadata for LZ4 frame decode.
///
/// When `dict_id` is omitted or zero, the library derives a deterministic
/// nonzero identifier from the 64KB dictionary prefix so raw-byte callers can
/// still validate frames that advertise a dictionary id.
pub(all) struct Dictionary {
  data : Bytes
  dict_id : UInt
} derive(Show, Eq)

///|
pub fn Dictionary::new(data : Bytes, dict_id? : UInt = 0U) -> Dictionary {
  let prefix = if data.length() > 0 { lz4_dictionary_prefix(data) } else { b"" }
  let normalized_id = if prefix.length() == 0 {
    0U
  } else if dict_id != 0U {
    dict_id
  } else {
    lz4_derived_dictionary_id(prefix)
  }
  { data, dict_id: normalized_id }
}

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
/// Base magic for skippable LZ4 frames.
const LZ4_SKIPPABLE_MAGIC_BASE : UInt = 0x184D2A50_U

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
fn lz4_is_skippable_magic(magic : UInt) -> Bool {
  magic >= LZ4_SKIPPABLE_MAGIC_BASE && magic <= LZ4_SKIPPABLE_MAGIC_BASE + 0x0FU
}

///|
fn lz4_skippable_frame_length(
  data : BytesView,
  pos : Int,
) -> Int raise Lz4Error {
  guard pos + 8 <= data.length() else { raise Lz4Error::UnexpectedEOF }
  let magic = lz4_read_u32_le(data, pos)
  guard lz4_is_skippable_magic(magic) else {
    raise Lz4Error::InvalidHeader("invalid skippable frame magic")
  }
  let size = lz4_read_u32_le(data, pos + 4).to_uint64()
  let total = size + 8UL
  let total_len = total.to_int()
  guard total_len >= 8 && total_len.reinterpret_as_uint().to_uint64() == total else {
    raise Lz4Error::InvalidHeader("skippable frame exceeds supported range")
  }
  guard total_len <= data.length() - pos else { raise Lz4Error::UnexpectedEOF }
  total_len
}

///|
fn lz4_dictionary_prefix(dict : Bytes) -> Bytes {
  let keep = if dict.length() > 65535 { 65535 } else { dict.length() }
  Bytes::makei(keep, fn(i) { dict[dict.length() - keep + i] })
}

///|
fn lz4_derived_dictionary_id(dict_prefix : Bytes) -> UInt {
  let derived = @checksum.xxh32(dict_prefix[:])
  if derived == 0U {
    1U
  } else {
    derived
  }
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
    lz4_derived_dictionary_id(dict_prefix)
  }
  {
    block_independence: options.block_independence,
    block_checksum: options.block_checksum,
    content_checksum: options.content_checksum,
    dict_id,
    block_max_size: options.block_max_size,
  }
}
