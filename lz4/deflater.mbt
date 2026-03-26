///|
/// Incremental LZ4 compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new()
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct EncoderState {
  mut finished : Bool
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new() -> Deflater {
  Deflater({ finished: false })
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
      let out = compress(chunk.to_bytes())
      if out.length() > 0 {
        Data(out[:])
      } else {
        Ok
      }
    }
    None => {
      s.finished = true
      End
    }
  }
}
