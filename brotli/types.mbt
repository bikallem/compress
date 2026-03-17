///|
/// Decoder signals returned by `Inflater::decode()`.
pub(all) enum Decode {
  Await
  Data(Bytes)
  End
  Error(BrotliError)
} derive(Show)

///|
/// Encoder signals returned by `Deflater::encode()`.
pub(all) enum Encode {
  Ok
  Data(Bytes)
  End
  Error(BrotliError)
} derive(Show)

///|
/// Brotli compression quality.
pub(all) enum CompressionLevel {
  NoCompression
  BestSpeed
  Level(Int)
  BestCompression
  DefaultCompression
} derive(Eq, Show)

///|
fn CompressionLevel::to_int(self : CompressionLevel) -> Int {
  match self {
    NoCompression => 0
    BestSpeed => 1
    Level(n) => n
    BestCompression => 11
    DefaultCompression => 11
  }
}

///|
pub(all) suberror BrotliError {
  CorruptInput(String)
  InvalidQuality(Int)
  UnexpectedEOF
  UnsupportedFeature(String)
} derive(Show)

///|
let min_quality : Int = 0

///|
let max_quality : Int = 11
