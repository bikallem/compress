///|
/// Snappy compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new(total_len=data.length())
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
/// Pass `total_len=-1` to keep the old buffered compatibility mode for callers
/// that do not know the final uncompressed size up front.
priv struct DeflaterState {
  state : Encoder
  total_len : Int
  mut seen_len : Int
  mut header_emitted : Bool
  input_buf : @blit.Buffer
  mut finished : Bool
}

///|
struct Deflater(DeflaterState)

///|
pub fn Deflater::new(total_len? : Int = -1) -> Deflater {
  Deflater({
    state: Encoder::new(),
    total_len,
    seen_len: 0,
    header_emitted: false,
    input_buf: @blit.Buffer::new(),
    finished: false,
  })
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
      if s.total_len >= 0 {
        if !s.header_emitted {
          s.state.emit_varint(s.total_len)
          s.header_emitted = true
        }
        let next_len = s.seen_len + chunk.length()
        guard next_len <= s.total_len else {
          return Error(
            CorruptInput("snappy input exceeds declared total length"),
          )
        }
        let mut offset = 0
        while offset < chunk.length() {
          let end = if offset + MAX_BLOCK_SIZE < chunk.length() {
            offset + MAX_BLOCK_SIZE
          } else {
            chunk.length()
          }
          s.state.compress_block(chunk, offset, end)
          offset = end
        }
        s.seen_len = next_len
        let out = s.state.take_output()
        if out.length() > 0 {
          Data(out[:])
        } else {
          Ok
        }
      } else {
        s.input_buf.write_bytesview(chunk)
        Ok
      }
    }
    None => {
      s.finished = true
      if s.total_len >= 0 {
        if !s.header_emitted {
          s.state.emit_varint(s.total_len)
          s.header_emitted = true
        }
        guard s.seen_len == s.total_len else {
          return Error(
            CorruptInput("snappy input length does not match declared total"),
          )
        }
        let out = s.state.take_output()
        if out.length() > 0 {
          Data(out[:])
        } else {
          End
        }
      } else {
        let input = s.input_buf.to_bytes()
        s.state.write(input[:])
        let output = s.state.close()
        if output.length() > 0 {
          Data(output[:])
        } else {
          End
        }
      }
    }
  }
}
