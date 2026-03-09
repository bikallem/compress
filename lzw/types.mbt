///|
/// BitOrder specifies the bit ordering in an LZW data stream.
pub(all) enum BitOrder {
  /// Least Significant Bits first, as used in GIF.
  LSB
  /// Most Significant Bits first, as used in TIFF and PDF.
  MSB
} derive(Eq, Show)

///|
pub suberror LzwError {
  InvalidLitWidth(Int)
  InvalidCode(String)
  UnexpectedEOF
  Io(String)
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
