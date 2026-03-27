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
priv enum InflatePhase {
  ReadLength
  Body
  Done
}

///|
priv enum StepResult {
  NeedMore
  Step(Int, Int)
  Error(SnappyError)
}

///|
fn snappy_read_u16_le(data : Bytes, pos : Int) -> Int {
  (data[pos].to_uint() | (data[pos + 1].to_uint() << 8)).reinterpret_as_int()
}

///|
fn snappy_read_u24_le(data : Bytes, pos : Int) -> Int {
  (data[pos].to_uint() |
  (data[pos + 1].to_uint() << 8) |
  (data[pos + 2].to_uint() << 16)).reinterpret_as_int()
}

///|
fn snappy_read_u32_le(data : Bytes, pos : Int) -> Int {
  (data[pos].to_uint() |
  (data[pos + 1].to_uint() << 8) |
  (data[pos + 2].to_uint() << 16) |
  (data[pos + 3].to_uint() << 24)).reinterpret_as_int()
}

///|
priv struct InflaterState {
  mut input_buf : @blit.Buffer
  mut input_pos : Int
  mut phase : InflatePhase
  mut expected_len : Int
  mut output : FixedArray[Byte]?
  mut dst_pos : Int
  mut emitted_len : Int
  mut len_value : Int
  mut len_shift : Int
  mut failed : SnappyError?
  mut sink : @blit.Buffer?
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    input_buf: @blit.Buffer::new(),
    input_pos: 0,
    phase: ReadLength,
    expected_len: 0,
    output: None,
    dst_pos: 0,
    emitted_len: 0,
    len_value: 0,
    len_shift: 0,
    failed: None,
    sink: None,
  })
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  let s = self.0
  if s.phase is Done || s.failed is Some(_) {
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
  if s.phase is Done {
    return End
  }
  for ;; {
    let input = s.input_buf.to_bytes()
    match s.phase {
      ReadLength => {
        while s.input_pos < input.length() {
          let b = input[s.input_pos].to_int()
          s.input_pos += 1
          s.len_value = s.len_value | ((b & 0x7F) << s.len_shift)
          if (b & 0x80) == 0 {
            s.expected_len = s.len_value
            s.output = Some(FixedArray::make(s.expected_len, b'\x00'))
            s.phase = Body
            s.len_value = 0
            s.len_shift = 0
            compact_snappy_input(s)
            break
          }
          s.len_shift += 7
          if s.len_shift >= 35 {
            let err = SnappyError::CorruptInput("varint too long")
            s.failed = Some(err)
            return Error(err)
          }
        }
        if s.phase is ReadLength {
          compact_snappy_input(s)
          return Await
        }
        if s.expected_len == 0 {
          let remaining = s.input_buf.to_bytes()
          if s.input_pos < remaining.length() {
            let err = SnappyError::CorruptInput(
              "trailing bytes after end of stream",
            )
            s.failed = Some(err)
            return Error(err)
          }
          s.phase = Done
          return End
        }
      }
      Body => {
        let out = match s.output {
          Some(out) => out
          None => {
            let err = SnappyError::CorruptInput("missing output buffer")
            s.failed = Some(err)
            return Error(err)
          }
        }
        let mut need_more = false
        while s.dst_pos < s.expected_len {
          match
            decode_snappy_step(
              input,
              s.input_pos,
              out,
              s.dst_pos,
              s.expected_len,
            ) {
            NeedMore => {
              need_more = true
              break
            }
            Step(next_input_pos, next_dst_pos) => {
              s.input_pos = next_input_pos
              s.dst_pos = next_dst_pos
            }
            Error(err) => {
              s.failed = Some(err)
              return Error(err)
            }
          }
        }
        compact_snappy_input(s)
        let complete = s.dst_pos == s.expected_len
        if complete && s.input_pos < s.input_buf.to_bytes().length() {
          let err = SnappyError::CorruptInput(
            "trailing bytes after end of stream",
          )
          s.failed = Some(err)
          return Error(err)
        }
        if s.dst_pos > s.emitted_len {
          if complete {
            s.phase = Done
          }
          return emit_snappy_delta(s, complete)
        }
        if complete {
          s.phase = Done
          return End
        }
        if need_more {
          return Await
        }
      }
      Done => return End
    }
  }
}

///|
fn emit_snappy_delta(s : InflaterState, complete : Bool) -> Decode {
  let out = match s.output {
    Some(out) => out
    None => return if complete { End } else { Await }
  }
  let len = s.dst_pos - s.emitted_len
  match s.sink {
    Some(sink) => {
      sink.write_fixed(out, s.emitted_len, len)
      s.emitted_len = s.dst_pos
      if complete {
        End
      } else {
        Await
      }
    }
    None => {
      let result = @blit.make_uninit(len)
      @blit.blit_fixed_array(result, 0, out, s.emitted_len, len)
      s.emitted_len = s.dst_pos
      Data(result.unsafe_reinterpret_as_bytes()[:])
    }
  }
}

///|
fn decode_snappy_step(
  input : Bytes,
  input_pos_ : Int,
  output : FixedArray[Byte],
  dst_pos : Int,
  expected_len : Int,
) -> StepResult {
  if input_pos_ >= input.length() {
    return NeedMore
  }
  let mut input_pos = input_pos_
  let tag = input[input_pos].to_int()
  let tag_type = tag & 0x03
  if tag_type == TAG_LITERAL {
    input_pos += 1
    let mut lit_len = (tag >> 2) + 1
    if lit_len == 61 {
      if input_pos >= input.length() {
        return NeedMore
      }
      lit_len = input[input_pos].to_int() + 1
      input_pos += 1
    } else if lit_len == 62 {
      if input_pos + 1 >= input.length() {
        return NeedMore
      }
      lit_len = snappy_read_u16_le(input, input_pos)
      lit_len += 1
      input_pos += 2
    } else if lit_len == 63 {
      if input_pos + 2 >= input.length() {
        return NeedMore
      }
      lit_len = snappy_read_u24_le(input, input_pos)
      lit_len += 1
      input_pos += 3
    } else if lit_len == 64 {
      if input_pos + 3 >= input.length() {
        return NeedMore
      }
      lit_len = snappy_read_u32_le(input, input_pos)
      lit_len += 1
      input_pos += 4
    }
    if input_pos + lit_len > input.length() {
      return NeedMore
    }
    if dst_pos + lit_len > expected_len {
      return Error(
        SnappyError::CorruptInput("literal extends past end of output"),
      )
    }
    for i in 0..<lit_len {
      output.unsafe_set(dst_pos + i, input[input_pos + i])
    }
    return Step(input_pos + lit_len, dst_pos + lit_len)
  }
  if tag_type == TAG_COPY1 {
    if input_pos + 1 >= input.length() {
      return NeedMore
    }
    let length = ((tag >> 2) & 0x07) + 4
    let offset = (tag >> 5 << 8) | input[input_pos + 1].to_int()
    return apply_snappy_copy(
      output,
      dst_pos,
      expected_len,
      offset,
      length,
      input_pos + 2,
    )
  }
  if tag_type == TAG_COPY2 {
    if input_pos + 2 >= input.length() {
      return NeedMore
    }
    let length = (tag >> 2) + 1
    let offset = snappy_read_u16_le(input, input_pos + 1)
    return apply_snappy_copy(
      output,
      dst_pos,
      expected_len,
      offset,
      length,
      input_pos + 3,
    )
  }
  if input_pos + 4 >= input.length() {
    return NeedMore
  }
  let length = (tag >> 2) + 1
  let offset = snappy_read_u32_le(input, input_pos + 1)
  apply_snappy_copy(
    output,
    dst_pos,
    expected_len,
    offset,
    length,
    input_pos + 5,
  )
}

///|
fn apply_snappy_copy(
  output : FixedArray[Byte],
  dst_pos : Int,
  expected_len : Int,
  offset : Int,
  length : Int,
  next_input_pos : Int,
) -> StepResult {
  if offset <= 0 || offset > dst_pos {
    return Error(SnappyError::CorruptInput("invalid copy offset \{offset}"))
  }
  if dst_pos + length > expected_len {
    return Error(SnappyError::CorruptInput("copy extends past end of output"))
  }
  let copy_start = dst_pos - offset
  for i in 0..<length {
    output.unsafe_set(dst_pos + i, output.unsafe_get(copy_start + i % offset))
  }
  Step(next_input_pos, dst_pos + length)
}

///|
fn compact_snappy_input(s : InflaterState) -> Unit {
  let input = s.input_buf.to_bytes()
  if s.input_pos == 0 {
    return
  }
  if s.input_pos < input.length() / 2 && s.input_pos < 65536 {
    return
  }
  let remaining = input.length() - s.input_pos
  let next = @blit.Buffer::new(size_hint=remaining)
  if remaining > 0 {
    next.write_bytesview(input[s.input_pos:])
  }
  s.input_buf = next
  s.input_pos = 0
}
