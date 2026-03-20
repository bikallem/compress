///|
/// Streaming Brotli decompressor using signal protocol.
priv struct InflaterState {
  mut input : BytesView
  mut input_pos : Int
  mut finished : Bool
  mut failed : BrotliError?
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
/// Enable zero-copy direct output mode for one-shot decompression.
pub fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@output_sink.OutputSink::new(capacity))
}

///|
/// Retrieve accumulated output after decompression completes.
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
    input.unsafe_get(s.input_pos + i)
  })
  let result = decompress(data) catch {
    e => {
      s.failed = Some(e)
      return Error(e)
    }
  }
  s.finished = true
  match s.sink {
    Some(sink) => {
      sink.write_bytes(result)
      End
    }
    None => Data(result[:])
  }
}
