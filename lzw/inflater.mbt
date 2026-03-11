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
  mut input : Bytes
  mut input_pos : Int
  // Output accumulator
  out_buf : @buffer.Buffer
  mut finished : Bool
  mut failed : LzwError?
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
    input: Bytes::default(),
    input_pos: 0,
    out_buf: @buffer.new(),
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
  if s.out_buf.length() > 0 {
    let out = s.out_buf.to_bytes()
    s.out_buf.reset()
    return Data(out)
  }
  match s.order {
    LSB => decode_lsb(s)
    MSB => decode_msb(s)
  }
}

///|
fn decode_lsb(s : InflaterState) -> Decode {
  let suffix = s.suffix
  let prefix = s.prefix
  let decode_buf = s.decode_buf
  let clear = s.clear
  let input = s.input
  let input_len = input.length()
  let mut bits = s.bits
  let mut n_bits = s.n_bits
  let mut pos = s.input_pos
  let out_buf = s.out_buf
  while true {
    // Read enough bits for a code (LSB)
    while n_bits < s.width {
      if pos >= input_len {
        // Save state and return
        s.bits = bits
        s.n_bits = n_bits
        s.input_pos = pos
        if out_buf.length() > 0 {
          let out = out_buf.to_bytes()
          out_buf.reset()
          return Data(out)
        }
        return Await
      }
      bits = bits | (input[pos].to_uint() << n_bits)
      n_bits += 8
      pos += 1
    }
    let mask = (1U << s.width) - 1U
    let code = (bits & mask).reinterpret_as_int()
    bits = bits >> s.width
    n_bits -= s.width
    // Process the code
    if code < clear {
      // Literal
      out_buf.write_byte(code.to_byte())
      if s.last != DECODER_INVALID_CODE {
        suffix.unsafe_set(s.hi, code.to_byte())
        prefix.unsafe_set(s.hi, s.last)
      }
    } else if code == clear {
      // Clear code — reset dictionary
      s.width = 1 + s.lit_width
      s.hi = s.eof_code
      s.overflow = 1 << s.width
      s.last = DECODER_INVALID_CODE
      continue
    } else if code == s.eof_code {
      // End of stream
      s.bits = bits
      s.n_bits = n_bits
      s.input_pos = pos
      s.finished = true
      if out_buf.length() > 0 {
        let out = out_buf.to_bytes()
        out_buf.reset()
        return Data(out)
      }
      return End
    } else if code <= s.hi {
      // Dictionary code
      let buf_len = decode_buf.length()
      let mut c = code
      let mut i = buf_len - 1
      if code == s.hi && s.last != DECODER_INVALID_CODE {
        c = s.last
        while c >= clear {
          c = prefix.unsafe_get(c)
        }
        decode_buf.unsafe_set(i, c.to_byte())
        i -= 1
        c = s.last
      }
      while c >= clear {
        decode_buf.unsafe_set(i, suffix.unsafe_get(c))
        i -= 1
        c = prefix.unsafe_get(c)
      }
      decode_buf.unsafe_set(i, c.to_byte())
      let decoded_len = buf_len - i
      // Write decoded bytes to output
      for j in 0..<decoded_len {
        out_buf.write_byte(decode_buf[i + j])
      }
      if s.last != DECODER_INVALID_CODE {
        suffix.unsafe_set(s.hi, c.to_byte())
        prefix.unsafe_set(s.hi, s.last)
      }
    } else {
      s.bits = bits
      s.n_bits = n_bits
      s.input_pos = pos
      let e = LzwError::InvalidCode("lzw: invalid code \{code}")
      s.failed = Some(e)
      return Error(e)
    }
    s.last = code
    s.hi += 1
    if s.hi >= s.overflow {
      if s.hi > s.overflow {
        abort("unreachable")
      }
      if s.width == MAX_WIDTH {
        s.last = DECODER_INVALID_CODE
        s.hi -= 1
      } else {
        s.width += 1
        s.overflow = 1 << s.width
      }
    }
  }
  // unreachable
  End
}

///|
fn decode_msb(s : InflaterState) -> Decode {
  let suffix = s.suffix
  let prefix = s.prefix
  let decode_buf = s.decode_buf
  let clear = s.clear
  let input = s.input
  let input_len = input.length()
  let mut bits = s.bits
  let mut n_bits = s.n_bits
  let mut pos = s.input_pos
  let out_buf = s.out_buf
  while true {
    // Read enough bits for a code (MSB)
    while n_bits < s.width {
      if pos >= input_len {
        s.bits = bits
        s.n_bits = n_bits
        s.input_pos = pos
        if out_buf.length() > 0 {
          let out = out_buf.to_bytes()
          out_buf.reset()
          return Data(out)
        }
        return Await
      }
      bits = bits | (input[pos].to_uint() << (24 - n_bits))
      n_bits += 8
      pos += 1
    }
    let code = (bits >> (32 - s.width)).reinterpret_as_int()
    bits = bits << s.width
    n_bits -= s.width
    // Process the code (same logic as LSB)
    if code < clear {
      out_buf.write_byte(code.to_byte())
      if s.last != DECODER_INVALID_CODE {
        suffix.unsafe_set(s.hi, code.to_byte())
        prefix.unsafe_set(s.hi, s.last)
      }
    } else if code == clear {
      s.width = 1 + s.lit_width
      s.hi = s.eof_code
      s.overflow = 1 << s.width
      s.last = DECODER_INVALID_CODE
      continue
    } else if code == s.eof_code {
      s.bits = bits
      s.n_bits = n_bits
      s.input_pos = pos
      s.finished = true
      if out_buf.length() > 0 {
        let out = out_buf.to_bytes()
        out_buf.reset()
        return Data(out)
      }
      return End
    } else if code <= s.hi {
      let buf_len = decode_buf.length()
      let mut c = code
      let mut i = buf_len - 1
      if code == s.hi && s.last != DECODER_INVALID_CODE {
        c = s.last
        while c >= clear {
          c = prefix.unsafe_get(c)
        }
        decode_buf.unsafe_set(i, c.to_byte())
        i -= 1
        c = s.last
      }
      while c >= clear {
        decode_buf.unsafe_set(i, suffix.unsafe_get(c))
        i -= 1
        c = prefix.unsafe_get(c)
      }
      decode_buf.unsafe_set(i, c.to_byte())
      let decoded_len = buf_len - i
      for j in 0..<decoded_len {
        out_buf.write_byte(decode_buf[i + j])
      }
      if s.last != DECODER_INVALID_CODE {
        suffix.unsafe_set(s.hi, c.to_byte())
        prefix.unsafe_set(s.hi, s.last)
      }
    } else {
      s.bits = bits
      s.n_bits = n_bits
      s.input_pos = pos
      let e = LzwError::InvalidCode("lzw: invalid code \{code}")
      s.failed = Some(e)
      return Error(e)
    }
    s.last = code
    s.hi += 1
    if s.hi >= s.overflow {
      if s.hi > s.overflow {
        abort("unreachable")
      }
      if s.width == MAX_WIDTH {
        s.last = DECODER_INVALID_CODE
        s.hi -= 1
      } else {
        s.width += 1
        s.overflow = 1 << s.width
      }
    }
  }
  End
}
