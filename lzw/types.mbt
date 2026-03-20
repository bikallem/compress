///|
/// BitOrder specifies the bit ordering in an LZW data stream.
pub(all) enum BitOrder {
  /// Least Significant Bits first, as used in GIF.
  LSB
  /// Most Significant Bits first, as used in TIFF and PDF.
  MSB
} derive(Eq, Show)

///|
pub(all) suberror LzwError {
  InvalidLitWidth(Int)
  InvalidCode(String)
  UnexpectedEOF
} derive(Show)

///|
const MAX_WIDTH : Int = 12

///|
const DECODER_INVALID_CODE : Int = 0xffff

///|
const MAX_CODE : Int = (1 << 12) - 1

///|
const INVALID_CODE : Int = -1

///|
const TABLE_SIZE : Int = 4 * (1 << 12)

///|
const TABLE_MASK : Int = TABLE_SIZE - 1

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
  Error(LzwError)
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
  Error(LzwError)
} derive(Show)
