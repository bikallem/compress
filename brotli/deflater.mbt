///|
/// Streaming Brotli compressor using signal protocol.
priv struct EncoderState {
  level : CompressionLevel
  input_buf : @buffer.Buffer
  mut finished : Bool
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new(level? : CompressionLevel = Default) -> Deflater {
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
      for x in chunk {
        s.input_buf.write_byte(x)
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
