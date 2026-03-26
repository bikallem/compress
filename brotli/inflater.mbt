///|
/// Incremental Brotli decompressor using signal protocol.
priv struct InflaterState {
  mut input_buf : @blit.Buffer
  mut br : BitReader?
  mut header_parsed : Bool
  mut max_backward : Int
  dist_rb : FixedArray[Int]
  mut dist_rb_idx : Int
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
    br: None,
    header_parsed: false,
    max_backward: 0,
    dist_rb: init_distance_ring_buffer(),
    dist_rb_idx: 0,
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
  if !ensure_brotli_header(s) {
    match s.failed {
      Some(e) => return Error(e)
      None => return Await
    }
  }
  for ;; {
    let input = s.input_buf.to_bytes()
    let base_br = match s.br {
      Some(br) => sync_brotli_reader(br, input)
      None => return Await
    }
    let trial_br = clone_brotli_reader(base_br)
    let trial_dist_rb = clone_distance_ring_buffer(s.dist_rb)
    let dist_rb_ref = Ref::new(s.dist_rb_idx)
    let scratch = @blit.Buffer::new(size_hint=4096)
    let result : Result[Bool, BrotliError] = try? decode_next_metablock(
      trial_br,
      scratch,
      s.max_backward,
      trial_dist_rb,
      dist_rb_ref,
    )
    match result {
      Err(BrotliError::UnexpectedEOF) => {
        s.br = Some(base_br)
        return Await
      }
      Err(e) => {
        s.failed = Some(e)
        return Error(e)
      }
      Ok(done) => {
        if done && !trial_br.is_at_logical_end() {
          let err = BrotliError::CorruptData(
            "trailing bytes after end of brotli stream",
          )
          s.failed = Some(err)
          return Error(err)
        }
        s.br = Some(trial_br)
        copy_distance_ring_buffer(s.dist_rb, trial_dist_rb)
        s.dist_rb_idx = dist_rb_ref.val
        compact_brotli_input(s)
        let out = scratch.to_bytes()
        if out.length() > 0 {
          if done {
            s.finished = true
          }
          match s.sink {
            Some(sink) => {
              sink.write_bytes(out)
              if done {
                return End
              }
              return Await
            }
            None => return Data(out[:])
          }
        }
        if done {
          s.finished = true
          return End
        }
      }
    }
  }
}

///|
fn ensure_brotli_header(s : InflaterState) -> Bool {
  if s.header_parsed {
    return true
  }
  let input = s.input_buf.to_bytes()
  if input.length() == 0 {
    return false
  }
  let br = BitReader::new(input[:])
  let result : Result[Int, BrotliError] = try? decode_wbits(br)
  match result {
    Ok(wbits) => {
      s.max_backward = 1 << wbits
      s.header_parsed = true
      s.br = Some(br)
      compact_brotli_input(s)
      true
    }
    Err(BrotliError::UnexpectedEOF) => false
    Err(e) => {
      s.failed = Some(e)
      false
    }
  }
}

///|
fn clone_brotli_reader(br : BitReader) -> BitReader {
  { data: br.data, byte_pos: br.byte_pos, bits: br.bits, n_bits: br.n_bits }
}

///|
fn sync_brotli_reader(br : BitReader, input : Bytes) -> BitReader {
  { data: input[:], byte_pos: br.byte_pos, bits: br.bits, n_bits: br.n_bits }
}

///|
fn clone_distance_ring_buffer(src : FixedArray[Int]) -> FixedArray[Int] {
  let dst = FixedArray::make(4, 0)
  for i in 0..<4 {
    dst.unsafe_set(i, src.unsafe_get(i))
  }
  dst
}

///|
fn copy_distance_ring_buffer(
  dst : FixedArray[Int],
  src : FixedArray[Int],
) -> Unit {
  for i in 0..<4 {
    dst.unsafe_set(i, src.unsafe_get(i))
  }
}

///|
fn compact_brotli_input(s : InflaterState) -> Unit {
  match s.br {
    None => ()
    Some(raw_br) => {
      let input = s.input_buf.to_bytes()
      let br = sync_brotli_reader(raw_br, input)
      if br.byte_pos == 0 ||
        (br.byte_pos < input.length() / 2 && br.byte_pos < 65536) {
        s.br = Some(br)
        return
      }
      let remaining = input.length() - br.byte_pos
      let next = @blit.Buffer::new(size_hint=remaining)
      if remaining > 0 {
        next.write_bytesview(input[br.byte_pos:])
      }
      s.input_buf = next
      let compacted = s.input_buf.to_bytes()
      s.br = Some({
        data: compacted[:],
        byte_pos: 0,
        bits: br.bits,
        n_bits: br.n_bits,
      })
    }
  }
}
