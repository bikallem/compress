///|
/// Streaming bzip2 decompressor using signal protocol.
///
/// Accumulates input and decompresses when the full stream is available.
/// Since bzip2 is block-based (BWT requires complete blocks), partial
/// streaming is not practical.
///
/// Usage:
///   let d = Inflater::new()
///   loop d.decode() {
///     Await => { d.src(chunk); continue d.decode() }
///     Data(out) => { write(out); continue d.decode() }
///     End => break
///     Error(e) => ...
///   }
priv struct Decoder {
  buf : @buffer.Buffer
  mut output : Bytes
  mut output_emitted : Bool
  mut finished : Bool
  mut failed : Bzip2Error?
}

///|
struct Inflater(Decoder)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    buf: @buffer.new(),
    output: Bytes::default(),
    output_emitted: false,
    finished: false,
    failed: None,
  })
}

///|
pub fn Inflater::src(self : Inflater, data : Bytes) -> Unit {
  let s = self.0
  if s.finished || s.failed is Some(_) {
    return
  }
  s.buf.write_bytes(data)
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
  // If we already decompressed, emit the output
  if s.output_emitted {
    s.finished = true
    return End
  }
  if s.output.length() > 0 {
    s.output_emitted = true
    return Data(s.output)
  }
  // Try to decompress accumulated input
  let input = s.buf.to_bytes()
  if input.length() == 0 {
    return Await
  }
  let result = try? decompress(input)
  match result {
    Ok(output) =>
      if output.length() > 0 {
        s.output = output
        s.output_emitted = true
        Data(output)
      } else {
        s.finished = true
        End
      }
    Err(Bzip2Error::UnexpectedEOF) =>
      // Need more data
      Await
    Err(e) => {
      s.failed = Some(e)
      Error(e)
    }
  }
}
