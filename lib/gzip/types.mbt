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
let gzip_magic1 : Byte = 0x1F

///|
let gzip_magic2 : Byte = 0x8B

///|
// Compression method: deflate = 8
let gzip_deflate : Byte = 8

///|
// Header flags
let gzip_ftext : Int = 1

///|
let gzip_fhcrc : Int = 2

///|
let gzip_fextra : Int = 4

///|
let gzip_fname : Int = 8

///|
let gzip_fcomment : Int = 16
