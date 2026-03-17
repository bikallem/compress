///|
priv enum DeflatePhase {
  Ready
  Failed(BrotliError)
}

///|
/// Streaming Brotli compressor.
struct Deflater {
  level : Int
  mut phase : DeflatePhase
}

///|
pub fn Deflater::new(
  level? : CompressionLevel = DefaultCompression,
) -> Deflater {
  { level: level.to_int(), phase: Ready }
}

///|
pub fn Deflater::encode(self : Deflater, _data : BytesView?) -> Encode {
  match self.phase {
    Failed(e) => Error(e)
    Ready => {
      if self.level < min_quality || self.level > max_quality {
        return self.fail(BrotliError::InvalidQuality(self.level))
      }
      self.fail(
        BrotliError::UnsupportedFeature("Brotli encoder not implemented"),
      )
    }
  }
}

///|
fn Deflater::fail(self : Deflater, e : BrotliError) -> Encode {
  self.phase = Failed(e)
  Error(e)
}
