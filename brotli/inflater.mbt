///|
/// Incremental Brotli decompressor using signal protocol.
priv struct InflaterState {
  input_buf : @blit.Buffer
  mut emitted_len : Int
  mut finished : Bool
  mut failed : BrotliError?
  mut sink : @blit.Buffer?
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    input_buf: @blit.Buffer::new(),
    emitted_len: 0,
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
/// Enable direct output accumulation for streaming decompression.
pub fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@blit.Buffer::new(size_hint=capacity))
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
  let data = s.input_buf.to_bytes()
  if data.length() == 0 {
    return Await
  }
  let scratch = @blit.Buffer::new(size_hint=(data.length() * 4).max(256))
  let complete = brotli_decompress_prefix(data, scratch) catch {
    e => {
      s.failed = Some(e)
      return Error(e)
    }
  }
  let output = scratch.to_bytes()
  if output.length() > s.emitted_len {
    let delta = output[s.emitted_len:]
    s.emitted_len = output.length()
    if complete {
      s.finished = true
    }
    match s.sink {
      Some(sink) => {
        sink.write_bytesview(delta)
        if complete {
          End
        } else {
          Await
        }
      }
      None => Data(delta)
    }
  } else if complete {
    s.finished = true
    End
  } else {
    Await
  }
}
