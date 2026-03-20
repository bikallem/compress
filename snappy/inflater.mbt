///|
/// Streaming Snappy decompressor using signal protocol.
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
  mut input : BytesView
  mut input_pos : Int
  mut finished : Bool
  mut failed : SnappyError?
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
fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@output_sink.OutputSink::new(capacity))
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
  let input = s.input
  if s.input_pos >= input.length() {
    return Await
  }
  // Parse the complete Snappy stream
  // Read varint for uncompressed length
  let (uncompressed_len, data_start) = read_varint(input, s.input_pos) catch {
    e => {
      let se = SnappyError::CorruptInput(e.to_string())
      s.failed = Some(se)
      return Error(se)
    }
  }
  if uncompressed_len == 0 {
    s.finished = true
    return End
  }
  let dst = FixedArray::make(uncompressed_len, b'\x00')
  let n = decode_block(input, data_start, dst, uncompressed_len) catch {
    e => {
      let se = SnappyError::CorruptInput(e.to_string())
      s.failed = Some(se)
      return Error(se)
    }
  }
  s.finished = true
  match s.sink {
    Some(sink) => {
      sink.write_fixed(dst, 0, n)
      End
    }
    None => {
      let result = Bytes::makei(n, fn(i) { dst[i] })
      Data(result[:])
    }
  }
}
