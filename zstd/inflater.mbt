///|
/// Buffered Zstandard decompressor using signal protocol.
priv struct InflaterState {
  input_buf : @blit.Buffer
  mut finished : Bool
  mut failed : ZstdError?
  mut sink : @blit.Buffer?
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    input_buf: @blit.Buffer::new(),
    finished: false,
    failed: None,
    sink: None,
  })
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  let s = self.0
  if s.finished || s.failed is Some(_) {
    return
  }
  s.input_buf.write_bytesview(data)
}

///|
/// Stub for streaming direct-output mode (to be wired up in convenience API).
pub fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@blit.Buffer::new(size_hint=capacity))
}

///|
/// Stub for retrieving accumulated output (to be wired up in convenience API).
pub fn Inflater::take_output(self : Inflater) -> Bytes {
  match self.0.sink {
    Some(sink) => sink.to_bytes()
    None => Bytes::default()
  }
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  match s.failed {
    Some(e) => return Error(e)
    None => ()
  }
  if s.finished {
    return End
  }
  let data = s.input_buf.to_bytes()
  if data.length() == 0 {
    return Await
  }
  let result = try? decompress(data)
  match result {
    Err(e) =>
      match e {
        UnexpectedEOF => Await
        _ => {
          s.failed = Some(e)
          Error(e)
        }
      }
    Ok(result) => {
      s.finished = true
      match s.sink {
        Some(sink) => {
          sink.write_bytes(result)
          End
        }
        None => Data(result[:])
      }
    }
  }
}
