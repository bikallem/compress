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

///|
// Block magic: 0x314159265359 (pi digits)
let block_magic : Array[Byte] = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59]

///|
// End of stream magic: 0x177245385090 (sqrt(pi) digits)
let eos_magic : Array[Byte] = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90]

///|
const MAX_BLOCK_SIZE : Int = 900000
