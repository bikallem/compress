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
} derive(Show)

///|
let max_width : Int = 12

///|
let decoder_invalid_code : Int = 0xffff

///|
let max_code : Int = (1 << 12) - 1

///|
let invalid_code : Int = -1

///|
let table_size : Int = 4 * (1 << 12)

///|
let table_mask : Int = table_size - 1
