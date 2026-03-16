///|
/// Streaming Brotli compressor using signal protocol.
priv struct EncoderState {
  level : CompressionLevel
  input_buf : @buffer.T
  mut finished : Bool
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new(
  level? : CompressionLevel = Default,
) -> Deflater {
  Deflater({ level, input_buf: @buffer.new(), finished: false })
}

///|
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(chunk) => {
      if chunk.length() == 0 {
        return Ok
      }
      for i in 0..<chunk.length() {
        s.input_buf.write_byte(chunk[i])
      }
      Ok
    }
    None => {
      let input = s.input_buf.to_bytes()
      let output = compress(input, level=s.level)
      s.finished = true
      if output.length() > 0 {
        Data(output)
      } else {
        End
      }
    }
  }
}
