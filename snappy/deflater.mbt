///|
/// Streaming Snappy compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new()
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct DeflaterState {
  state : Encoder
  input_buf : @buffer.Buffer
  mut finished : Bool
}

///|
struct Deflater(DeflaterState)

///|
pub fn Deflater::new() -> Deflater {
  Deflater({ state: Encoder::new(), input_buf: @buffer.new(), finished: false })
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
      // Buffer input — Snappy needs the full data for varint header
      for x in chunk {
        s.input_buf.write_byte(x)
      }
      Ok
    }
    None => {
      let input = s.input_buf.to_bytes()
      s.state.write(input[:])
      let output = s.state.close()
      s.finished = true
      if output.length() > 0 {
        Data(output[:])
      } else {
        End
      }
    }
  }
}
