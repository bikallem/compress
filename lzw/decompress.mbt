///|
/// Decompresses LZW-encoded data from `src` to `dst` (streaming).
/// `order` specifies the bit packing order (LSB for GIF, MSB for TIFF/PDF).
/// `lit_width` is the literal code width in bits (typically 8, range [2, 8]).
pub async fn decompress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width? : Int = 8,
) -> Unit raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  let dec = LzwDecoder::new(order, lit_width)
  let reader = BufReader::new(src)
  while true {
    // Read code
    while dec.n_bits < dec.width {
      let b = reader.read_byte()
      dec.feed_byte(b)
    }
    let code = dec.extract_code()
    if dec.process_code(code) {
      // EOF
      break
    }
    // Flush output to writer when buffer is full
    if dec.o > 0 {
      dec.flush_output()
      flush_buffer(dst, dec.flush_buf)
    }
  }
  // Final flush
  dec.flush_output()
  flush_buffer(dst, dec.flush_buf)
}

///|
/// Decompresses LZW-encoded `data` bytes, returning decompressed bytes.
pub fn decompress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width? : Int = 8,
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
priv struct LzwDecoder {
  order : BitOrder
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
  mut bits : UInt
  mut n_bits : Int
  // Buffer for streaming flush
  flush_buf : @buffer.Buffer
}

///|
fn LzwDecoder::new(order : BitOrder, lit_width : Int) -> LzwDecoder {
  let clear = 1 << lit_width
  let eof = clear + 1
  let width = lit_width + 1
  {
    order,
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
    flush_buf: @buffer.new(size_hint=8192),
  }
}

///|
/// Feeds one byte into the bit accumulator.
fn LzwDecoder::feed_byte(self : LzwDecoder, b : Byte) -> Unit {
  match self.order {
    LSB => self.bits = self.bits | (b.to_uint() << self.n_bits)
    MSB => self.bits = self.bits | (b.to_uint() << (24 - self.n_bits))
  }
  self.n_bits += 8
}

///|
/// Extracts a code from the bit accumulator.
fn LzwDecoder::extract_code(self : LzwDecoder) -> Int {
  let code = match self.order {
    LSB => {
      let mask = (1U << self.width) - 1U
      (self.bits & mask).reinterpret_as_int()
    }
    MSB => (self.bits >> (32 - self.width)).reinterpret_as_int()
  }
  match self.order {
    LSB => self.bits = self.bits >> self.width
    MSB => self.bits = self.bits << self.width
  }
  self.n_bits -= self.width
  code
}

///|
/// Process a decoded code and update dictionary.
/// Returns true when EOF code is encountered.
fn LzwDecoder::process_code(
  self : LzwDecoder,
  code : Int,
) -> Bool raise LzwError {
  let output = self.output
  let suffix = self.suffix
  let prefix = self.prefix
  let clear = self.clear
  if code < clear {
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
    self.flush_output()
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
    if self.o != i {
      @blit.blit_fixed_array(output, self.o, output, i, decoded_len)
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
    self.flush_output()
  }
  false
}

///|
/// Flushes the output scratch buffer to flush_buf (for streaming) or
/// to the OutputBuffer (for bytes mode). In streaming mode, sets needs_flush.
fn LzwDecoder::flush_output(self : LzwDecoder) -> Unit {
  if self.o > 0 {
    for i in 0..<self.o {
      self.flush_buf.write_byte(self.output[i])
    }
    self.o = 0
  }
}

///|
/// LSB-specific decompression — avoids match on order in hot loop.
fn decompress_lsb(data : Bytes, lit_width : Int) -> Bytes raise LzwError {
  let state = LzwDecoder::new(LSB, lit_width)
  let result = OutputBuffer::new(data.length() * 4)
  let data_len = data.length()
  let mut bits = state.bits
  let mut n_bits = state.n_bits
  let mut pos = 0
  while true {
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
    if state.process_code(code) {
      break
    }
    // Flush to OutputBuffer instead of flush_buf
    if state.o > 0 {
      result.write_fixed(state.output, 0, state.o)
      state.o = 0
    }
  }
  // Flush any remaining output
  if state.o > 0 {
    result.write_fixed(state.output, 0, state.o)
    state.o = 0
  }
  result.to_bytes()
}

///|
/// MSB-specific decompression — avoids match on order in hot loop.
fn decompress_msb(data : Bytes, lit_width : Int) -> Bytes raise LzwError {
  let state = LzwDecoder::new(MSB, lit_width)
  let result = OutputBuffer::new(data.length() * 4)
  let data_len = data.length()
  let mut bits = state.bits
  let mut n_bits = state.n_bits
  let mut pos = 0
  while true {
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
    if state.process_code(code) {
      break
    }
    if state.o > 0 {
      result.write_fixed(state.output, 0, state.o)
      state.o = 0
    }
  }
  if state.o > 0 {
    result.write_fixed(state.output, 0, state.o)
    state.o = 0
  }
  result.to_bytes()
}
