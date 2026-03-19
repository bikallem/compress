///|
/// Streaming Zstandard decompressor using signal protocol.
priv struct InflaterState {
  mut input : BytesView
  mut input_pos : Int
  mut finished : Bool
  mut failed : ZstdError?
  mut sink : @output_sink.OutputSink?
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    input: b""[:],
    input_pos: 0,
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
  s.input = data
  s.input_pos = 0
}

///|
/// Stub for streaming direct-output mode (to be wired up in convenience API).
pub fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@output_sink.OutputSink::new(capacity))
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
  let input = s.input
  if s.input_pos >= input.length() {
    return Await
  }
  let data = Bytes::makei(input.length() - s.input_pos, fn(i) {
    input[s.input_pos + i]
  })
  let result = decompress(data) catch {
    e => {
      let ze = ZstdError::CorruptData(e.to_string())
      s.failed = Some(ze)
      return Error(ze)
    }
  }
  s.finished = true
  match s.sink {
    Some(sink) => {
      sink.write_bytes(result)
      End
    }
    None => Data(result)
  }
}
