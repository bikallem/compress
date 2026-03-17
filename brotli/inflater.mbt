///|
priv enum InflatePhase {
  Ready
  Failed(BrotliError)
}

///|
/// Streaming Brotli decompressor.
struct Inflater {
  mut phase : InflatePhase
  mut input : BytesView
  mut sink : @output_sink.OutputSink?
}

///|
pub fn Inflater::new() -> Inflater {
  { phase: Ready, input: b""[:], sink: None }
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  self.input = data
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  match self.phase {
    Ready =>
      self.fail(
        BrotliError::UnsupportedFeature("Brotli decoder not implemented"),
      )
    Failed(e) => Error(e)
  }
}

///|
pub fn Inflater::remaining(self : Inflater) -> Bytes {
  Bytes::makei(self.input.length(), fn(i) { self.input[i] })
}

///|
fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.sink = Some(@output_sink.OutputSink::new(capacity))
}

///|
fn Inflater::take_output(self : Inflater) -> Bytes {
  match self.sink {
    Some(sink) => sink.to_bytes()
    None => Bytes::default()
  }
}

///|
fn Inflater::fail(self : Inflater, e : BrotliError) -> Decode {
  self.phase = Failed(e)
  Error(e)
}
