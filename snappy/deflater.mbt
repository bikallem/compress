///|
/// Snappy compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new_known_length(data.length())
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
/// Raw Snappy writes the full uncompressed-size varint at the start of the
/// stream, so truly incremental output requires the caller to know that final
/// size up front. `Deflater::new()` falls back to buffered compatibility mode
/// when the size is omitted or negative; use `Deflater::new_known_length()` for
/// incremental output and `Deflater::new_buffered()` when the final size is not
/// known ahead of time.
priv struct DeflaterState {
  state : Encoder
  total_len : Int
  mut seen_len : Int
  mut header_emitted : Bool
  input_buf : @blit.Buffer
  mut history : @blit.Buffer
  mut finished : Bool
}

///|
struct Deflater(DeflaterState)

///|
/// Creates a raw Snappy deflater. Omitting `total_len` keeps the historical
/// buffered mode; pass a non-negative total length or prefer
/// `Deflater::new_known_length()` for true incremental output.
pub fn Deflater::new(total_len? : Int = -1) -> Deflater {
  Deflater({
    state: Encoder::new(),
    total_len,
    seen_len: 0,
    header_emitted: false,
    input_buf: @blit.Buffer::new(),
    history: @blit.Buffer::new(),
    finished: false,
  })
}

///|
/// Creates a raw Snappy deflater that can emit output incrementally because the
/// final uncompressed length is known up front.
pub fn Deflater::new_known_length(total_len : Int) -> Deflater {
  Deflater::new(total_len~)
}

///|
/// Creates a raw Snappy deflater in explicit buffered compatibility mode.
pub fn Deflater::new_buffered() -> Deflater {
  Deflater::new()
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
        s.seen_len = next_len
        encode_incremental_snappy_chunk(s, chunk)
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

///|
fn encode_incremental_snappy_chunk(
  s : DeflaterState,
  chunk : BytesView,
) -> Unit {
  if chunk.length() == 0 {
    return
  }
  let history = s.history.to_bytes()
  let combined = @blit.Buffer::new(size_hint=history.length() + chunk.length())
  if history.length() > 0 {
    combined.write_bytes(history)
  }
  combined.write_bytesview(chunk)
  let combined_bytes = combined.to_bytes()
  s.state.compress_block_window(
    combined_bytes[:],
    0,
    history.length(),
    combined_bytes.length(),
  )
  let keep = if combined_bytes.length() > MAX_BLOCK_SIZE {
    MAX_BLOCK_SIZE
  } else {
    combined_bytes.length()
  }
  let keep_start = combined_bytes.length() - keep
  let next_history = @blit.Buffer::new(size_hint=keep)
  if keep > 0 {
    next_history.write_bytesview(combined_bytes[keep_start:])
  }
  s.history = next_history
}
