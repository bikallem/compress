///|
/// Streaming decompression of LZW data from a reader to a writer.
pub async fn decompress_to(
  source : &@io.Reader,
  dest : &@io.Writer,
  order : BitOrder,
  lit_width : Int,
) -> Unit {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  match order {
    LSB => async_decompress_lsb(source, dest, lit_width)
    MSB => async_decompress_msb(source, dest, lit_width)
  }
}

///|
async fn async_decompress_lsb(
  source : &@io.Reader,
  dest : &@io.Writer,
  lit_width : Int,
) -> Unit {
  let state = LzwDecompressState::new(lit_width)
  let read_buf = FixedArray::make(1, b'\x00')
  while true {
    while state.n_bits < state.width {
      let n = source.read(read_buf, offset=0, max_len=1)
      if n == 0 {
        raise LzwError::UnexpectedEOF
      }
      state.bits = state.bits | (read_buf[0].to_uint() << state.n_bits)
      state.n_bits += 8
    }
    let mask = (1U << state.width) - 1U
    let code = (state.bits & mask).reinterpret_as_int()
    state.bits = state.bits >> state.width
    state.n_bits -= state.width
    if state.async_process_code(code, dest) {
      break
    }
  }
}

///|
async fn async_decompress_msb(
  source : &@io.Reader,
  dest : &@io.Writer,
  lit_width : Int,
) -> Unit {
  let state = LzwDecompressState::new(lit_width)
  let read_buf = FixedArray::make(1, b'\x00')
  while true {
    while state.n_bits < state.width {
      let n = source.read(read_buf, offset=0, max_len=1)
      if n == 0 {
        raise LzwError::UnexpectedEOF
      }
      state.bits = state.bits | (read_buf[0].to_uint() << (24 - state.n_bits))
      state.n_bits += 8
    }
    let code = (state.bits >> (32 - state.width)).reinterpret_as_int()
    state.bits = state.bits << state.width
    state.n_bits -= state.width
    if state.async_process_code(code, dest) {
      break
    }
  }
}

///|
/// Process a decoded code, writing output to a writer instead of buffer.
async fn LzwDecompressState::async_process_code(
  self : LzwDecompressState,
  code : Int,
  dest : &@io.Writer,
) -> Bool {
  if code < self.clear {
    self.output[self.o] = code.to_byte()
    self.o += 1
    if self.last != DECODER_INVALID_CODE {
      self.suffix[self.hi] = code.to_byte()
      self.prefix[self.hi] = self.last
    }
  } else if code == self.clear {
    self.width = 1 + self.lit_width
    self.hi = self.eof
    self.overflow = 1 << self.width
    self.last = DECODER_INVALID_CODE
    return false
  } else if code == self.eof {
    self.async_flush(dest)
    return true
  } else if code <= self.hi {
    let mut c = code
    let mut i = self.output.length() - 1
    if code == self.hi && self.last != DECODER_INVALID_CODE {
      c = self.last
      while c >= self.clear {
        c = self.prefix[c]
      }
      self.output[i] = c.to_byte()
      i -= 1
      c = self.last
    }
    while c >= self.clear {
      self.output[i] = self.suffix[c]
      i -= 1
      c = self.prefix[c]
    }
    self.output[i] = c.to_byte()
    let decoded_len = self.output.length() - i
    if self.o != i {
      FixedArray::unsafe_blit(self.output, self.o, self.output, i, decoded_len)
    }
    self.o += decoded_len
    if self.last != DECODER_INVALID_CODE {
      self.suffix[self.hi] = c.to_byte()
      self.prefix[self.hi] = self.last
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
    self.async_flush(dest)
  }
  false
}

///|
/// Flush output buffer to writer.
async fn LzwDecompressState::async_flush(
  self : LzwDecompressState,
  dest : &@io.Writer,
) -> Unit {
  let bytes = self.output.unsafe_reinterpret_as_bytes()
  let mut offset = 0
  while offset < self.o {
    let written = dest.write_once(bytes, offset~, len=self.o - offset)
    offset += written
  }
  self.o = 0
}
