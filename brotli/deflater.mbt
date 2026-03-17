///|
priv enum DeflatePhase {
  Ready
  Finished
  Failed(BrotliError)
}

///|
/// Streaming Brotli compressor.
struct Deflater {
  level : Int
  input : @buffer.Buffer
  mut phase : DeflatePhase
}

///|
pub fn Deflater::new(
  level? : CompressionLevel = DefaultCompression,
) -> Deflater {
  { level: level.to_int(), input: @buffer.new(), phase: Ready }
}

///|
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  if self.level < min_quality || self.level > max_quality {
    return self.fail(BrotliError::InvalidQuality(self.level))
  }
  match self.phase {
    Failed(e) => Error(e)
    Finished => End
    Ready =>
      match data {
        Some(chunk) => {
          self.input.write_bytes(
            Bytes::makei(chunk.length(), fn(i) { chunk[i] }),
          )
          Ok
        }
        None => {
          let result = if self.level == 0 {
            try? trivial_compress(self.input.to_bytes())
          } else {
            try? compress_literal_only(self.input.to_bytes())
          }
          match result {
            Ok(output) => {
              self.phase = Finished
              if output.length() == 0 {
                End
              } else {
                Data(output)
              }
            }
            Err(e) => self.fail(e)
          }
        }
      }
  }
}

///|
fn Deflater::fail(self : Deflater, e : BrotliError) -> Encode {
  self.phase = Failed(e)
  Error(e)
}
