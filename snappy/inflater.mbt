///|
/// Buffered Snappy decompressor using signal protocol.
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
  // Parse the complete Snappy stream
  // Read varint for uncompressed length
  let read_len_result = try? read_varint(input[:], 0)
  let (uncompressed_len, data_start) = match read_len_result {
    Ok(v) => v
    Err(e) =>
      match e {
        UnexpectedEOF => return Await
        _ => {
          s.failed = Some(e)
          return Error(e)
        }
      }
  }
  if uncompressed_len == 0 {
    if data_start != input.length() {
      let err = CorruptInput("trailing bytes after end of stream")
      s.failed = Some(err)
      return Error(err)
    }
    s.finished = true
    return End
  }
  let dst = FixedArray::make(uncompressed_len, b'\x00')
  let decode_result = try? decode_block(
    input[:],
    data_start,
    dst,
    uncompressed_len,
  )
  let n = match decode_result {
    Ok(v) => v
    Err(e) =>
      match e {
        UnexpectedEOF => return Await
        _ => {
          s.failed = Some(e)
          return Error(e)
        }
      }
  }
  s.finished = true
  match s.sink {
    Some(sink) => {
      sink.write_fixed(dst, 0, n)
      End
    }
    None => {
      let result = Bytes::makei(n, fn(i) { dst.unsafe_get(i) })
      Data(result[:])
    }
  }
}
