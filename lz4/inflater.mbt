///|
/// Incremental LZ4 decompressor using signal protocol.
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
/// Call `finish()` once the upstream source reaches EOF so the inflater can
/// distinguish a real end-of-input from an exact frame boundary.
priv struct InflaterState {
  input_buf : @blit.Buffer
  mut emitted_len : Int
  mut input_finished : Bool
  mut finished : Bool
  mut failed : Lz4Error?
  mut sink : @blit.Buffer?
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    input_buf: @blit.Buffer::new(),
    emitted_len: 0,
    input_finished: false,
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
  if data.length() > 0 {
    s.input_finished = false
  }
  s.input_buf.write_bytesview(data)
}

///|
pub fn Inflater::finish(self : Inflater) -> Unit {
  self.0.input_finished = true
}

///|
pub fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@blit.Buffer::new(size_hint=capacity))
}

///|
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
    return if s.input_finished { Error(UnexpectedEOF) } else { Await }
  }
  let scratch = @blit.Buffer::new(size_hint=(data.length() * 2).max(65536))
  let complete = try? decompress_prefix_into(data, scratch)
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
    match s.sink {
      Some(sink) => {
        sink.write_bytesview(delta)
        if complete && s.input_finished {
          s.finished = true
          End
        } else {
          Await
        }
      }
      None => {
        if complete && s.input_finished {
          s.finished = true
        }
        Data(delta)
      }
    }
  } else if complete {
    if s.input_finished {
      s.finished = true
      End
    } else {
      Await
    }
  } else if s.input_finished {
    let err = UnexpectedEOF
    s.failed = Some(err)
    Error(err)
  } else {
    Await
  }
}
