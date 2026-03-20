///|
/// Brotli compression error type.
pub(all) suberror BrotliError {
  InvalidHeader(String)
  CorruptData(String)
  InvalidDistance(String)
  WindowTooLarge
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
  Error(BrotliError)
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
  Error(BrotliError)
} derive(Show)

///|
/// Compression level for Brotli (0-11).
pub(all) enum CompressionLevel {
  Level(Int)
  Default
  Best
} derive(Eq, Show)

///|
fn compression_level_to_int(level : CompressionLevel) -> Int {
  match level {
    Level(n) => if n < 0 { 0 } else if n > 11 { 11 } else { n }
    Default => 6
    Best => 11
  }
}

///|
/// Hash table size for compression.
const BROTLI_HASH_SIZE : Int = 1 << 14

///|
/// Maximum backward reference distance (window size for WBITS=22).
const MAX_BACKWARD_DISTANCE : Int = 1 << 22

///|
/// Maximum LZ77 match length. Brotli copy code 23 supports up to
/// 2118 + 2^24 - 1 = 16,779,333 bytes. We use the full range so that
/// highly repetitive data can be covered by a single copy command.
const MAX_MATCH_LENGTH : Int = 16779333

///|
/// Minimum LZ77 match length.
const MIN_MATCH_LENGTH : Int = 4

///|
/// Number of literal contexts per block type (2^LITERAL_CONTEXT_BITS).
const NUM_LITERAL_CONTEXTS : Int = 64

///|
/// Insert-and-copy length code prefix lengths (Table in RFC 7932 section 5).
/// For simplicity, we define the baselines and extra bits for insert lengths.
let _insert_baselines : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a.unsafe_set(0, 0)
  a.unsafe_set(1, 1)
  a.unsafe_set(2, 2)
  a.unsafe_set(3, 3)
  a.unsafe_set(4, 4)
  a.unsafe_set(5, 5)
  a.unsafe_set(6, 6)
  a.unsafe_set(7, 8)
  a.unsafe_set(8, 10)
  a.unsafe_set(9, 14)
  a.unsafe_set(10, 18)
  a.unsafe_set(11, 26)
  a.unsafe_set(12, 34)
  a.unsafe_set(13, 50)
  a.unsafe_set(14, 66)
  a.unsafe_set(15, 98)
  a.unsafe_set(16, 130)
  a.unsafe_set(17, 194)
  a.unsafe_set(18, 322)
  a.unsafe_set(19, 578)
  a.unsafe_set(20, 1090)
  a.unsafe_set(21, 2114)
  a.unsafe_set(22, 6210)
  a.unsafe_set(23, 22594)
  a
}

///|
let _insert_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a.unsafe_set(0, 0)
  a.unsafe_set(1, 0)
  a.unsafe_set(2, 0)
  a.unsafe_set(3, 0)
  a.unsafe_set(4, 0)
  a.unsafe_set(5, 0)
  a.unsafe_set(6, 1)
  a.unsafe_set(7, 1)
  a.unsafe_set(8, 2)
  a.unsafe_set(9, 2)
  a.unsafe_set(10, 3)
  a.unsafe_set(11, 3)
  a.unsafe_set(12, 4)
  a.unsafe_set(13, 4)
  a.unsafe_set(14, 5)
  a.unsafe_set(15, 5)
  a.unsafe_set(16, 6)
  a.unsafe_set(17, 7)
  a.unsafe_set(18, 8)
  a.unsafe_set(19, 9)
  a.unsafe_set(20, 10)
  a.unsafe_set(21, 12)
  a.unsafe_set(22, 14)
  a.unsafe_set(23, 24)
  a
}

///|
let _copy_baselines : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a.unsafe_set(0, 2)
  a.unsafe_set(1, 3)
  a.unsafe_set(2, 4)
  a.unsafe_set(3, 5)
  a.unsafe_set(4, 6)
  a.unsafe_set(5, 7)
  a.unsafe_set(6, 8)
  a.unsafe_set(7, 9)
  a.unsafe_set(8, 10)
  a.unsafe_set(9, 12)
  a.unsafe_set(10, 14)
  a.unsafe_set(11, 18)
  a.unsafe_set(12, 22)
  a.unsafe_set(13, 30)
  a.unsafe_set(14, 38)
  a.unsafe_set(15, 54)
  a.unsafe_set(16, 70)
  a.unsafe_set(17, 102)
  a.unsafe_set(18, 134)
  a.unsafe_set(19, 198)
  a.unsafe_set(20, 326)
  a.unsafe_set(21, 582)
  a.unsafe_set(22, 1094)
  a.unsafe_set(23, 2118)
  a
}

///|
let _copy_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a.unsafe_set(0, 0)
  a.unsafe_set(1, 0)
  a.unsafe_set(2, 0)
  a.unsafe_set(3, 0)
  a.unsafe_set(4, 0)
  a.unsafe_set(5, 0)
  a.unsafe_set(6, 0)
  a.unsafe_set(7, 0)
  a.unsafe_set(8, 1)
  a.unsafe_set(9, 1)
  a.unsafe_set(10, 2)
  a.unsafe_set(11, 2)
  a.unsafe_set(12, 3)
  a.unsafe_set(13, 3)
  a.unsafe_set(14, 4)
  a.unsafe_set(15, 4)
  a.unsafe_set(16, 5)
  a.unsafe_set(17, 5)
  a.unsafe_set(18, 6)
  a.unsafe_set(19, 7)
  a.unsafe_set(20, 8)
  a.unsafe_set(21, 9)
  a.unsafe_set(22, 10)
  a.unsafe_set(23, 24)
  a
}
