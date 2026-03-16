///|
/// Streaming LZW compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new(LSB, 8)
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct DeflaterState {
  state : Encoder
  mut finished : Bool
}

///|
struct Deflater(DeflaterState)

///|
pub fn Deflater::new(
  order : BitOrder,
  lit_width : Int,
) -> Deflater raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  Deflater({ state: Encoder::new(order, lit_width), finished: false })
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
      s.state.write(chunk)
      let output = s.state.take_output()
      if output.length() > 0 {
        Data(output)
      } else {
        Ok
      }
    }
    None => {
      let output = s.state.close()
      s.finished = true
      if output.length() > 0 {
        Data(output)
      } else {
        End
      }
    }
  }
}
