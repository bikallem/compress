///|
/// Streaming LZW decompressor using signal protocol.
///
/// Usage:
///   let d = Inflater::new(LSB, 8)
///   loop d.decode() {
///     Await => { d.src(chunk); continue d.decode() }
///     Data(out) => { write(out); continue d.decode() }
///     End => break
///     Error(e) => ...
///   }
priv struct InflaterState {
  order : BitOrder
  lit_width : Int
  // LZW dictionary
  clear : Int
  eof_code : Int
  suffix : FixedArray[Byte]
  prefix : FixedArray[Int]
  decode_buf : FixedArray[Byte] // temp buffer for decoding strings
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut last : Int
  // Bit reader
  mut bits : UInt
  mut n_bits : Int
  // Input
  mut input : BytesView
  mut input_pos : Int
  // Output accumulator — FixedArray avoids Buffer overhead
  out_buf : FixedArray[Byte]
  mut out_pos : Int
  mut finished : Bool
  mut failed : LzwError?
  mut sink : @output_sink.OutputSink? // None = streaming, Some = direct output
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new(
  order : BitOrder,
  lit_width : Int,
) -> Inflater raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  let clear = 1 << lit_width
  let eof_code = clear + 1
  let width = lit_width + 1
  Inflater({
    order,
    lit_width,
    clear,
    eof_code,
    suffix: FixedArray::make(1 << MAX_WIDTH, b'\x00'),
    prefix: FixedArray::make(1 << MAX_WIDTH, 0),
    decode_buf: FixedArray::make(2 * (1 << MAX_WIDTH), b'\x00'),
    width,
    hi: eof_code,
    overflow: 1 << width,
    last: DECODER_INVALID_CODE,
    bits: 0U,
    n_bits: 0,
    input: b""[:],
    input_pos: 0,
    out_buf: FixedArray::make(32768, b'\x00'),
    out_pos: 0,
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
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  match s.failed {
    Some(e) => return Error(e)
    None => ()
  }
  if s.finished {
    return End
  }
  // Emit any buffered output first
  if s.out_pos > 0 {
    let out = flush_output(s)
    if out.length() > 0 {
      return Data(out)
    }
  }
  match s.order {
    LSB => decode_lsb(s)
    MSB => decode_msb(s)
  }
}

///|
/// Flush output buffer. In direct mode, drains to sink and returns empty Bytes.
/// In streaming mode, allocates and returns a new Bytes.
fn flush_output(s : InflaterState) -> Bytes {
  let len = s.out_pos
  if len == 0 {
    return Bytes::default()
  }
  match s.sink {
    Some(sink) => {
      sink.write_fixed(s.out_buf, 0, len)
      s.out_pos = 0
      Bytes::default()
    }
    None => {
      let result = @blit.make_uninit(len)
      @blit.blit_fixed_array(result, 0, s.out_buf, 0, len)
      s.out_pos = 0
      result.unsafe_reinterpret_as_bytes()
    }
  }
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
/// Result of processing a single LZW code.
priv enum CodeResult {
  /// Clear code — reset dictionary, continue loop.
  Clear
  /// EOF code — stream complete.
  Finished
  /// Invalid code encountered.
  Invalid(Int)
  /// Code processed normally.
  Ok
}

///|
/// Processes a single LZW code, updating dictionary and writing output.
/// Shared by both LSB and MSB decode loops.
fn process_code(s : InflaterState, code : Int) -> CodeResult {
  let clear = s.clear
  let out_buf = s.out_buf
  if code < clear {
    // SAFETY: out_buf is sized to MAX_WIDTH * hist.length(); out_pos < out_buf.length()
    // because process_code is called in a loop that flushes when out_pos approaches capacity.
    out_buf.unsafe_set(s.out_pos, code.to_byte())
    s.out_pos += 1
    if s.last != DECODER_INVALID_CODE {
      // SAFETY: s.hi < s.overflow <= 1 << MAX_WIDTH = 4096 = suffix/prefix array length
      s.suffix.unsafe_set(s.hi, code.to_byte())
      s.prefix.unsafe_set(s.hi, s.last)
    }
  } else if code == clear {
    s.width = 1 + s.lit_width
    s.hi = s.eof_code
    s.overflow = 1 << s.width
    s.last = DECODER_INVALID_CODE
    return Clear
  } else if code == s.eof_code {
    return Finished
  } else if code <= s.hi {
    let decode_buf = s.decode_buf
    let suffix = s.suffix
    let prefix = s.prefix
    let buf_len = decode_buf.length()
    let mut c = code
    let mut i = buf_len - 1
    if code == s.hi && s.last != DECODER_INVALID_CODE {
      // SAFETY: c walks the prefix chain which always terminates at a literal < clear.
      // prefix[c] was set when c was added to the dictionary, so c is always a valid index.
      c = s.last
      while c >= clear {
        c = prefix.unsafe_get(c)
      }
      decode_buf.unsafe_set(i, c.to_byte())
      i -= 1
      c = s.last
    }
    // SAFETY: c walks prefix chain; clear <= c <= s.hi < 4096 = array length.
    // i decrements from buf_len-1; chain length bounded by dictionary size.
    while c >= clear {
      decode_buf.unsafe_set(i, suffix.unsafe_get(c))
      i -= 1
      c = prefix.unsafe_get(c)
    }
    decode_buf.unsafe_set(i, c.to_byte())
    let decoded_len = buf_len - i
    // Bulk copy from decode_buf to output buffer
    @blit.blit_fixed_array(out_buf, s.out_pos, decode_buf, i, decoded_len)
    s.out_pos += decoded_len
    if s.last != DECODER_INVALID_CODE {
      suffix.unsafe_set(s.hi, c.to_byte())
      prefix.unsafe_set(s.hi, s.last)
    }
  } else {
    return Invalid(code)
  }
  s.last = code
  s.hi += 1
  if s.hi >= s.overflow {
    if s.hi > s.overflow {
      return Invalid(s.hi)
    }
    if s.width == MAX_WIDTH {
      s.last = DECODER_INVALID_CODE
      s.hi -= 1
    } else {
      s.width += 1
      s.overflow = 1 << s.width
    }
  }
  Ok
}

///|
/// Saves bit reader state and returns buffered output or Await.
fn save_and_yield(
  s : InflaterState,
  bits : UInt,
  n_bits : Int,
  pos : Int,
) -> Decode {
  s.bits = bits
  s.n_bits = n_bits
  s.input_pos = pos
  if s.out_pos > 0 {
    let out = flush_output(s)
    if out.length() > 0 {
      return Data(out)
    }
  }
  Await
}

///|
/// Saves state, marks finished, returns buffered output or End.
fn save_and_end(
  s : InflaterState,
  bits : UInt,
  n_bits : Int,
  pos : Int,
) -> Decode {
  s.bits = bits
  s.n_bits = n_bits
  s.input_pos = pos
  s.finished = true
  if s.out_pos > 0 {
    let out = flush_output(s)
    if out.length() > 0 {
      return Data(out)
    }
  }
  End
}

///|
/// Saves state and returns an error.
fn save_and_fail(
  s : InflaterState,
  bits : UInt,
  n_bits : Int,
  pos : Int,
  code : Int,
) -> Decode {
  s.bits = bits
  s.n_bits = n_bits
  s.input_pos = pos
  let e = LzwError::InvalidCode("lzw: invalid code \{code}")
  s.failed = Some(e)
  Error(e)
}

///|
fn decode_lsb(s : InflaterState) -> Decode {
  let input = s.input
  let input_len = input.length()
  let mut bits = s.bits
  let mut n_bits = s.n_bits
  let mut pos = s.input_pos
  let out_buf_len = s.out_buf.length()
  while true {
    while n_bits < s.width {
      if pos >= input_len {
        return save_and_yield(s, bits, n_bits, pos)
      }
      bits = bits | (input[pos].to_uint() << n_bits)
      n_bits += 8
      pos += 1
    }
    let width = s.width
    let code = (bits & ((1U << width) - 1U)).reinterpret_as_int()
    bits = bits >> width
    n_bits -= width
    match process_code(s, code) {
      Clear => continue
      Finished => return save_and_end(s, bits, n_bits, pos)
      Invalid(c) => return save_and_fail(s, bits, n_bits, pos, c)
      Ok =>
        if s.out_pos > out_buf_len - 4096 {
          match s.sink {
            Some(_) =>
              // Direct mode: flush to sink and continue decoding
              ignore(flush_output(s))
            None =>
              // Streaming mode: yield output to caller
              return save_and_yield(s, bits, n_bits, pos)
          }
        }
    }
  }
  End
}

///|
fn decode_msb(s : InflaterState) -> Decode {
  let input = s.input
  let input_len = input.length()
  let mut bits = s.bits
  let mut n_bits = s.n_bits
  let mut pos = s.input_pos
  let out_buf_len = s.out_buf.length()
  while true {
    while n_bits < s.width {
      if pos >= input_len {
        return save_and_yield(s, bits, n_bits, pos)
      }
      bits = bits | (input[pos].to_uint() << (24 - n_bits))
      n_bits += 8
      pos += 1
    }
    let width = s.width
    let code = (bits >> (32 - width)).reinterpret_as_int()
    bits = bits << width
    n_bits -= width
    match process_code(s, code) {
      Clear => continue
      Finished => return save_and_end(s, bits, n_bits, pos)
      Invalid(c) => return save_and_fail(s, bits, n_bits, pos, c)
      Ok =>
        if s.out_pos > out_buf_len - 4096 {
          match s.sink {
            Some(_) => ignore(flush_output(s))
            None => return save_and_yield(s, bits, n_bits, pos)
          }
        }
    }
  }
  End
}
