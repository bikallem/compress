///|
/// Streaming bzip2 compressor using signal protocol.
///
/// Buffers input and compresses when encode(None) is called,
/// since bzip2 requires full blocks for BWT.
///
/// Usage:
///   let d = Deflater::new()
///   match d.encode(Some(data)) { Ok => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct DeflaterState {
  level : Int
  buf : @buffer.Buffer
  mut finished : Bool
}

///|
struct Deflater(DeflaterState)

///|
pub fn Deflater::new(level? : Int = 9) -> Deflater raise Bzip2Error {
  guard level >= 1 && level <= 9 else {
    raise Bzip2Error::CorruptData("invalid bzip2 level: must be 1-9")
  }
  Deflater({ level, buf: @buffer.new(), finished: false })
}

///|
pub fn Deflater::encode(self : Deflater, data : Bytes?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(chunk) => {
      s.buf.write_bytes(chunk)
      Ok
    }
    None => {
      let input = s.buf.to_bytes()
      let output = compress(input, level=s.level) catch {
        e => return Error(e)
      }
      s.finished = true
      if output.length() > 0 {
        Data(output)
      } else {
        End
      }
    }
  }
}
