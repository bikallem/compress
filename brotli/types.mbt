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
  Data(Bytes)
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
  Data(Bytes)
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
/// Maximum LZ77 match length. Brotli supports up to ~16M via copy code 23,
/// but we cap at a practical limit that covers common repetitive data well.
const MAX_MATCH_LENGTH : Int = 65536

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
  a[0] = 0
  a[1] = 1
  a[2] = 2
  a[3] = 3
  a[4] = 4
  a[5] = 5
  a[6] = 6
  a[7] = 8
  a[8] = 10
  a[9] = 14
  a[10] = 18
  a[11] = 26
  a[12] = 34
  a[13] = 50
  a[14] = 66
  a[15] = 98
  a[16] = 130
  a[17] = 194
  a[18] = 322
  a[19] = 578
  a[20] = 1090
  a[21] = 2114
  a[22] = 6210
  a[23] = 22594
  a
}

///|
let _insert_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a[0] = 0
  a[1] = 0
  a[2] = 0
  a[3] = 0
  a[4] = 0
  a[5] = 0
  a[6] = 1
  a[7] = 1
  a[8] = 2
  a[9] = 2
  a[10] = 3
  a[11] = 3
  a[12] = 4
  a[13] = 4
  a[14] = 5
  a[15] = 5
  a[16] = 6
  a[17] = 7
  a[18] = 8
  a[19] = 9
  a[20] = 10
  a[21] = 12
  a[22] = 14
  a[23] = 24
  a
}

///|
let _copy_baselines : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a[0] = 2
  a[1] = 3
  a[2] = 4
  a[3] = 5
  a[4] = 6
  a[5] = 7
  a[6] = 8
  a[7] = 9
  a[8] = 10
  a[9] = 12
  a[10] = 14
  a[11] = 18
  a[12] = 22
  a[13] = 30
  a[14] = 38
  a[15] = 54
  a[16] = 70
  a[17] = 102
  a[18] = 134
  a[19] = 198
  a[20] = 326
  a[21] = 582
  a[22] = 1094
  a[23] = 2118
  a
}

///|
let _copy_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(24, 0)
  a[0] = 0
  a[1] = 0
  a[2] = 0
  a[3] = 0
  a[4] = 0
  a[5] = 0
  a[6] = 0
  a[7] = 0
  a[8] = 1
  a[9] = 1
  a[10] = 2
  a[11] = 2
  a[12] = 3
  a[13] = 3
  a[14] = 4
  a[15] = 4
  a[16] = 5
  a[17] = 5
  a[18] = 6
  a[19] = 7
  a[20] = 8
  a[21] = 9
  a[22] = 10
  a[23] = 24
  a
}
