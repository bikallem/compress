///|
/// GzipError represents errors during gzip compression/decompression.
pub suberror GzipError {
  InvalidHeader(String)
  ChecksumMismatch(expected~ : UInt, got~ : UInt)
  SizeMismatch(expected~ : UInt, got~ : UInt)
  DeflateError(String)
  UnexpectedEOF
} derive(Show)

///|
/// Header contains gzip file header metadata.
pub(all) struct Header {
  name : String
  comment : String
  extra : Bytes
  mod_time : UInt
  os : Byte
} derive(Show, Eq)

///|
/// Creates a default gzip header.
pub fn Header::default() -> Header {
  { name: "", comment: "", extra: Bytes::default(), mod_time: 0U, os: b'\xFF' }
}

///|
// gzip magic bytes
const GZIP_MAGIC1 : Byte = 0x1F

///|
const GZIP_MAGIC2 : Byte = 0x8B

///|
// Compression method: deflate = 8
const GZIP_DEFLATE : Byte = 8

///|
const GZIP_FHCRC : Int = 2

///|
const GZIP_FEXTRA : Int = 4

///|
const GZIP_FNAME : Int = 8

///|
const GZIP_FCOMMENT : Int = 16
