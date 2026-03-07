///|
/// Decompresses LZW-encoded data.
/// `order` specifies the bit packing order (LSB for GIF, MSB for TIFF/PDF).
/// `lit_width` is the literal code width in bits (typically 8, range [2, 8]).
pub fn decompress(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  match order {
    LSB => decompress_lsb(data, lit_width)
    MSB => decompress_msb(data, lit_width)
  }
}

///|
/// Internal LZW decompression state machine.
priv struct LzwDecompressState {
  lit_width : Int
  clear : Int
  eof : Int
  suffix : FixedArray[Byte]
  prefix : FixedArray[Int]
  output : FixedArray[Byte]
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut last : Int
  mut o : Int
  // Bit reading state (initial values; locals used in hot loop)
  bits : UInt
  n_bits : Int
  pos : Int
}

///|
fn LzwDecompressState::new(lit_width : Int) -> LzwDecompressState {
  let clear = 1 << lit_width
  let eof = clear + 1
  let width = lit_width + 1
  {
    lit_width,
    clear,
    eof,
    suffix: FixedArray::make(1 << MAX_WIDTH, b'\x00'),
    prefix: FixedArray::make(1 << MAX_WIDTH, 0),
    output: FixedArray::make(2 * (1 << MAX_WIDTH), b'\x00'),
    width,
    hi: eof,
    overflow: 1 << width,
    last: DECODER_INVALID_CODE,
    o: 0,
    bits: 0U,
    n_bits: 0,
    pos: 0,
  }
}

///|
/// Flush output buffer to result.
fn LzwDecompressState::flush(
  self : LzwDecompressState,
  result : @buffer.Buffer,
) -> Unit {
  if self.o > 0 {
    let bytes = self.output.unsafe_reinterpret_as_bytes()
    result.write_bytesview(bytes[0:self.o])
  }
  self.o = 0
}

///|
/// Process a decoded code and update dictionary.
fn LzwDecompressState::process_code(
  self : LzwDecompressState,
  code : Int,
  result : @buffer.Buffer,
) -> Bool raise LzwError {
  let output = self.output
  let suffix = self.suffix
  let prefix = self.prefix
  let clear = self.clear
  // Safety: all indices are bounded by LZW state machine invariants:
  // - codes < 1<<MAX_WIDTH (table size)
  // - self.o < 2*(1<<MAX_WIDTH) (output buffer, flushed at 1<<MAX_WIDTH)
  // - self.hi < 1<<MAX_WIDTH (table high water mark)
  if code < clear {
    // Literal code
    output.unsafe_set(self.o, code.to_byte())
    self.o += 1
    if self.last != DECODER_INVALID_CODE {
      suffix.unsafe_set(self.hi, code.to_byte())
      prefix.unsafe_set(self.hi, self.last)
    }
  } else if code == clear {
    self.width = 1 + self.lit_width
    self.hi = self.eof
    self.overflow = 1 << self.width
    self.last = DECODER_INVALID_CODE
    return false
  } else if code == self.eof {
    self.flush(result)
    return true
  } else if code <= self.hi {
    let mut c = code
    let out_len = output.length()
    let mut i = out_len - 1
    if code == self.hi && self.last != DECODER_INVALID_CODE {
      c = self.last
      while c >= clear {
        c = prefix.unsafe_get(c)
      }
      output.unsafe_set(i, c.to_byte())
      i -= 1
      c = self.last
    }
    while c >= clear {
      output.unsafe_set(i, suffix.unsafe_get(c))
      i -= 1
      c = prefix.unsafe_get(c)
    }
    output.unsafe_set(i, c.to_byte())
    let decoded_len = out_len - i
    // Copy decoded bytes — use unsafe_blit for bulk copy
    if self.o != i {
      FixedArray::unsafe_blit(output, self.o, output, i, decoded_len)
    }
    self.o += decoded_len
    if self.last != DECODER_INVALID_CODE {
      suffix.unsafe_set(self.hi, c.to_byte())
      prefix.unsafe_set(self.hi, self.last)
    }
  } else {
    raise LzwError::InvalidCode("lzw: invalid code \{code}")
  }
  self.last = code
  self.hi += 1
  if self.hi >= self.overflow {
    if self.hi > self.overflow {
      abort("unreachable")
    }
    if self.width == MAX_WIDTH {
      self.last = DECODER_INVALID_CODE
      self.hi -= 1
    } else {
      self.width += 1
      self.overflow = 1 << self.width
    }
  }
  if self.o >= 1 << MAX_WIDTH {
    self.flush(result)
  }
  false
}

///|
/// LSB-specific decompression — avoids match on order in hot loop.
fn decompress_lsb(data : Bytes, lit_width : Int) -> Bytes raise LzwError {
  let state = LzwDecompressState::new(lit_width)
  let result = @buffer.new(size_hint=data.length() * 2)
  let data_len = data.length()
  // Extract bit-reader state to locals for the hot loop
  let mut bits = state.bits
  let mut n_bits = state.n_bits
  let mut pos = state.pos
  while true {
    // Read code (LSB) — inlined with locals
    while n_bits < state.width {
      if pos >= data_len {
        raise LzwError::UnexpectedEOF
      }
      bits = bits | (data[pos].to_uint() << n_bits)
      n_bits += 8
      pos += 1
    }
    let mask = (1U << state.width) - 1U
    let code = (bits & mask).reinterpret_as_int()
    bits = bits >> state.width
    n_bits -= state.width
    if state.process_code(code, result) {
      break
    }
  }
  result.to_bytes()
}

///|
/// MSB-specific decompression — avoids match on order in hot loop.
fn decompress_msb(data : Bytes, lit_width : Int) -> Bytes raise LzwError {
  let state = LzwDecompressState::new(lit_width)
  let result = @buffer.new(size_hint=data.length() * 2)
  let data_len = data.length()
  let mut bits = state.bits
  let mut n_bits = state.n_bits
  let mut pos = state.pos
  while true {
    // Read code (MSB) — inlined with locals
    while n_bits < state.width {
      if pos >= data_len {
        raise LzwError::UnexpectedEOF
      }
      bits = bits | (data[pos].to_uint() << (24 - n_bits))
      n_bits += 8
      pos += 1
    }
    let code = (bits >> (32 - state.width)).reinterpret_as_int()
    bits = bits << state.width
    n_bits -= state.width
    if state.process_code(code, result) {
      break
    }
  }
  result.to_bytes()
}
