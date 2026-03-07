///|
/// Bzip2Error represents errors during bzip2 decompression.
pub suberror Bzip2Error {
  InvalidHeader(String)
  CorruptData(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  UnexpectedEOF
} derive(Show)

///|
// bzip2 magic bytes: "BZ"
const BZIP2_MAGIC1 : Byte = b'B'

///|
const BZIP2_MAGIC2 : Byte = b'Z'
