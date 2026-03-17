///|
priv enum InflatePhase {
  Reading
  Emit
  Done
  Failed(BrotliError)
}

///|
/// Streaming Brotli decompressor.
struct Inflater {
  input : @buffer.Buffer
  mut phase : InflatePhase
  mut sink : @output_sink.OutputSink?
  mut tail : Bytes
}

///|
pub fn Inflater::new() -> Inflater {
  { input: @buffer.new(), phase: Reading, sink: None, tail: Bytes::default() }
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  if data.length() == 0 {
    return
  }
  self.input.write_bytes(Bytes::makei(data.length(), fn(i) { data[i] }))
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  match self.phase {
    Reading => {
      let result = try? decode_brotli_stream(self.input.to_bytes())
      match result {
        Ok(decoded) => {
          self.tail = decoded.remaining
          match self.sink {
            Some(sink) => {
              sink.write_bytes(decoded.output)
              self.phase = Done
              End
            }
            None =>
              if decoded.output.length() == 0 {
                self.phase = Done
                End
              } else {
                self.phase = Emit
                Data(decoded.output)
              }
          }
        }
        Err(BrotliError::UnexpectedEOF) => Await
        Err(e) => self.fail(e)
      }
    }
    Emit => {
      self.phase = Done
      End
    }
    Done => End
    Failed(e) => Error(e)
  }
}

///|
pub fn Inflater::remaining(self : Inflater) -> Bytes {
  match self.phase {
    Reading => self.input.to_bytes()
    Emit | Done | Failed(_) => self.tail
  }
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
