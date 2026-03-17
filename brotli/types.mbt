///|
/// Decoder signals — returned by Inflater::decode().
pub(all) enum Decode {
  /// Need input. Call src(bytes) then decode() again.
  Await
  /// Produced output. Consume it, then decode() again.
  Data(Bytes)
  /// Stream complete. Remaining input via Inflater::remaining().
  End
  /// Unrecoverable format error.
  Error(BrotliError)
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
pub(all) suberror BrotliError {
  CorruptInput(String)
  InvalidHeader(String)
  UnexpectedEOF
} derive(Show)

// Brotli format constants (RFC 7932)

///|
const MAX_WINDOW_BITS : Int = 24

///|
const WINDOW_GAP : Int = 16

///|
const NUM_LITERAL_SYMBOLS : Int = 256

///|
const NUM_COMMAND_SYMBOLS : Int = 704

///|
const NUM_BLOCK_LEN_SYMBOLS : Int = 26

///|
const MAX_NUMBER_OF_BLOCK_TYPES : Int = 256

///|
const NUM_DISTANCE_SHORT_CODES : Int = 16

///|
const MAX_NPOSTFIX : Int = 3

///|
const MAX_NDIRECT : Int = 120

///|
const MAX_DISTANCE_BITS : Int = 24

///|
const LITERAL_CONTEXT_BITS : Int = 6

///|
const DISTANCE_CONTEXT_BITS : Int = 2

///|
const HUFFMAN_TABLE_BITS : Int = 8

///|
const HUFFMAN_MAX_CODE_LENGTH : Int = 15

///|
const CODE_LENGTH_CODES : Int = 18

///|
const REPEAT_PREVIOUS_CODE_LENGTH : Int = 16

///|
const REPEAT_ZERO_CODE_LENGTH : Int = 17

///|
const INITIAL_REPEATED_CODE_LENGTH : Int = 8

///|
const RING_BUFFER_WRITE_AHEAD_SLACK : Int = 542

///|
// Code length code order (RFC 7932 section 3.5)
let code_length_code_order : FixedArray[Int] = [
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]

///|
// Static prefix code for the complex code length code lengths
let code_length_prefix_length : FixedArray[Int] = [
  2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4,
]

///|
let code_length_prefix_value : FixedArray[Int] = [
  0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5,
]

///|
// Block length prefix code ranges (26 entries) from RFC 7932 section 9.2
// Each entry: (offset, nbits)
let block_length_offset : FixedArray[Int] = [
  1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305,
  369, 497, 753, 1265, 2289, 4337, 8433, 16625,
]

///|
let block_length_nbits : FixedArray[Int] = [
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12,
  13, 24,
]
