///|
/// Incremental Snappy decompressor using signal protocol.
///
/// Usage:
///   let d = Inflater::new()
///   d.src(data)
///   loop d.decode() {
///     Await => { d.src(chunk); continue d.decode() }
///     Data(out) => { write(out); continue d.decode() }
///     End => break
///     Error(e) => ...
///   }
priv struct InflaterState {
  input_buf : @blit.Buffer
  mut emitted_len : Int
  mut finished : Bool
  mut failed : SnappyError?
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
fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@blit.Buffer::new(size_hint=capacity))
}

///|
fn Inflater::take_output(self : Inflater) -> Bytes {
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
  let input = s.input_buf.to_bytes()
  if input.length() == 0 {
    return Await
  }
  let scratch = @blit.Buffer::new(size_hint=(input.length() * 2).max(256))
  let complete = try? snappy_decompress_prefix(input, scratch)
  let complete = match complete {
    Ok(v) => v
    Err(e) => {
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
