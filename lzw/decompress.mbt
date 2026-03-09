///|
/// Decompresses an LZW stream from `src` into `dst`.
pub async fn decompress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width : Int,
) -> Unit raise LzwError {
  validate_lit_width(lit_width)
  let state = LzwDecompressState::new(lit_width)
  while true {
    let code = state.read_code(src, order)
    if state.process_code(dst, code) {
      state.finish(dst)
      return
    }
  }
}

///|
/// Convenience wrapper for in-memory decompression.
pub async fn decompress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError {
  let src = @ibytes.BytesReader::new(data)
  let dst = @ibytes.BytesWriter::new()
  decompress(src, dst, order, lit_width)
  dst.content()
}

///|
priv struct LzwDecompressState {
  lit_width : Int
  clear : Int
  eof : Int
  suffix : FixedArray[Byte]
  prefix : FixedArray[Int]
  stack : FixedArray[Byte]
  input : InputByteBuffer
  output : OutputByteBuffer
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut last : Int
  mut bits : UInt
  mut n_bits : Int
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
    stack: FixedArray::make(1 << MAX_WIDTH, b'\x00'),
    input: InputByteBuffer::new(),
    output: OutputByteBuffer::new(),
    width,
    hi: eof,
    overflow: 1 << width,
    last: DECODER_INVALID_CODE,
    bits: 0U,
    n_bits: 0,
  }
}

///|
async fn LzwDecompressState::emit_byte(
  self : LzwDecompressState,
  dst : &@io.Writer,
  byte : Byte,
) -> Unit raise LzwError {
  self.output.write_byte(dst, byte)
}

///|
async fn LzwDecompressState::finish(
  self : LzwDecompressState,
  dst : &@io.Writer,
) -> Unit raise LzwError {
  self.output.flush(dst)
}

///|
fn LzwDecompressState::reset(self : LzwDecompressState) -> Unit {
  self.width = 1 + self.lit_width
  self.hi = self.eof
  self.overflow = 1 << self.width
  self.last = DECODER_INVALID_CODE
}

///|
fn LzwDecompressState::advance_hi(self : LzwDecompressState) -> Unit {
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
}

///|
fn LzwDecompressState::first_literal(
  self : LzwDecompressState,
  code : Int,
) -> Byte {
  let mut current = code
  while current >= self.clear {
    current = self.prefix.unsafe_get(current)
  }
  current.to_byte()
}

///|
async fn LzwDecompressState::read_code(
  self : LzwDecompressState,
  src : &@io.Reader,
  order : BitOrder,
) -> Int raise LzwError {
  while self.n_bits < self.width {
    match self.input.read_byte(src) {
      Some(byte) => {
        match order {
          LSB => self.bits = self.bits | (byte.to_uint() << self.n_bits)
          MSB => self.bits = self.bits | (byte.to_uint() << (24 - self.n_bits))
        }
        self.n_bits += 8
      }
      None => raise LzwError::UnexpectedEOF
    }
  }
  match order {
    LSB => {
      let mask = (1U << self.width) - 1U
      let code = (self.bits & mask).reinterpret_as_int()
      self.bits = self.bits >> self.width
      self.n_bits -= self.width
      code
    }
    MSB => {
      let code = (self.bits >> (32 - self.width)).reinterpret_as_int()
      self.bits = self.bits << self.width
      self.n_bits -= self.width
      code
    }
  }
}

///|
async fn LzwDecompressState::flush_stack(
  self : LzwDecompressState,
  dst : &@io.Writer,
  start : Int,
) -> Unit raise LzwError {
  self.output.write_fixed(dst, self.stack, start, self.stack.length() - start)
}

///|
async fn LzwDecompressState::process_code(
  self : LzwDecompressState,
  dst : &@io.Writer,
  code : Int,
) -> Bool raise LzwError {
  if code < self.clear {
    self.emit_byte(dst, code.to_byte())
    if self.last != DECODER_INVALID_CODE {
      self.suffix.unsafe_set(self.hi, code.to_byte())
      self.prefix.unsafe_set(self.hi, self.last)
    }
    self.last = code
    self.advance_hi()
    return false
  }
  if code == self.clear {
    self.reset()
    return false
  }
  if code == self.eof {
    return true
  }
  if code > self.hi || self.last == DECODER_INVALID_CODE {
    raise LzwError::InvalidCode("lzw: invalid code \{code}")
  }
  let incode = code
  let mut current = code
  let mut top = self.stack.length()
  if code == self.hi {
    top -= 1
    self.stack.unsafe_set(top, self.first_literal(self.last))
    current = self.last
  }
  while current >= self.clear {
    top -= 1
    self.stack.unsafe_set(top, self.suffix.unsafe_get(current))
    current = self.prefix.unsafe_get(current)
  }
  let first = current.to_byte()
  top -= 1
  self.stack.unsafe_set(top, first)
  self.flush_stack(dst, top)
  self.suffix.unsafe_set(self.hi, first)
  self.prefix.unsafe_set(self.hi, self.last)
  self.last = incode
  self.advance_hi()
  false
}
