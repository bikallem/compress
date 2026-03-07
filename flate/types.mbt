///|
/// CompressionLevel controls the speed/size tradeoff for DEFLATE compression.
pub(all) enum CompressionLevel {
  NoCompression
  BestSpeed
  Level(Int)
  BestCompression
  DefaultCompression
  HuffmanOnly
} derive(Eq, Show)

///|
fn CompressionLevel::to_int(self : CompressionLevel) -> Int {
  match self {
    NoCompression => 0
    BestSpeed => 1
    Level(n) => n
    BestCompression => 9
    DefaultCompression => 6
    HuffmanOnly => -2
  }
}

///|
pub suberror CompressError {
  CorruptInput(String)
  InvalidLevel(Int)
  UnexpectedEOF
} derive(Show)

///|
// DEFLATE constants from RFC 1951
const MAX_MATCH_LENGTH : Int = 258

///|
const MIN_MATCH_LENGTH : Int = 3

///|
const MAX_MATCH_OFFSET : Int = 32768

///|
const MAX_CODE_LEN : Int = 16

///|
const END_BLOCK_MARKER : Int = 256

///|
const NUM_CODES : Int = 19

///|
// Length code base values (RFC 1951 section 3.2.5)
let length_base : ReadOnlyArray[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : ReadOnlyArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
// Distance code base values (RFC 1951 section 3.2.5)
let dist_base : ReadOnlyArray[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : ReadOnlyArray[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
// Code length code order for dynamic Huffman blocks (RFC 1951 section 3.2.7)
let code_order : ReadOnlyArray[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]
