///|
/// Streaming LZ4 compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new()
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct EncoderState {
  input_buf : @blit.Buffer
  mut finished : Bool
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new() -> Deflater {
  Deflater({ input_buf: @blit.Buffer::new(), finished: false })
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
      s.input_buf.write_bytesview(chunk)
      Ok
    }
    None => {
      let input = s.input_buf.to_bytes()
      let output = compress(input)
      s.finished = true
      if output.length() > 0 {
        Data(output[:])
      } else {
        End
      }
    }
  }
}
