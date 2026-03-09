///|
/// Compresses all bytes from `src` and writes the LZW stream into `dst`.
pub async fn compress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width : Int,
) -> Unit raise LzwError {
  validate_lit_width(lit_width)
  let state = LzwCompressState::new(order, lit_width)
  let input_buf = FixedArray::make(IO_BUFFER_SIZE, b'\x00')
  while true {
    let n = src.read(input_buf, offset=0, max_len=input_buf.length()) catch {
      e => raise LzwError::Io(e.to_string())
    }
    if n == 0 {
      break
    }
    for i in 0..<n {
      state.write_input_byte(dst, input_buf[i])
    }
  }
  state.finish(dst)
}

///|
/// Convenience wrapper for in-memory compression.
pub async fn compress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError {
  let src = @ibytes.BytesReader::new(data)
  let dst = @ibytes.BytesWriter::new()
  compress(src, dst, order, lit_width)
  dst.content()
}

///|
priv struct LzwCompressState {
  order : BitOrder
  lit_width : Int
  table : FixedArray[UInt]
  output : OutputByteBuffer
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut saved_code : Int
  mut bits : UInt
  mut n_bits : Int
}

///|
fn LzwCompressState::new(order : BitOrder, lit_width : Int) -> LzwCompressState {
  let lw = lit_width
  {
    order,
    lit_width: lw,
    table: FixedArray::make(TABLE_SIZE, 0U),
    output: OutputByteBuffer::new(),
    width: 1 + lw,
    hi: (1 << lw) + 1,
    overflow: 1 << (lw + 1),
    saved_code: INVALID_CODE,
    bits: 0U,
    n_bits: 0,
  }
}

///|
async fn LzwCompressState::emit_byte(
  self : LzwCompressState,
  dst : &@io.Writer,
  byte : Byte,
) -> Unit raise LzwError {
  self.output.write_byte(dst, byte)
}

///|
async fn LzwCompressState::write_code(
  self : LzwCompressState,
  dst : &@io.Writer,
  code : Int,
) -> Unit raise LzwError {
  let c = code.reinterpret_as_uint()
  match self.order {
    LSB => {
      self.bits = self.bits | (c << self.n_bits)
      self.n_bits += self.width
      while self.n_bits >= 8 {
        self.emit_byte(dst, (self.bits & 0xFFU).to_byte())
        self.bits = self.bits >> 8
        self.n_bits -= 8
      }
    }
    MSB => {
      self.bits = self.bits | (c << (32 - self.width - self.n_bits))
      self.n_bits += self.width
      while self.n_bits >= 8 {
        self.emit_byte(dst, (self.bits >> 24).to_byte())
        self.bits = self.bits << 8
        self.n_bits -= 8
      }
    }
  }
}

///|
async fn LzwCompressState::inc_hi(
  self : LzwCompressState,
  dst : &@io.Writer,
) -> Bool raise LzwError {
  self.hi += 1
  if self.hi == self.overflow {
    self.width += 1
    self.overflow = self.overflow << 1
  }
  if self.hi == MAX_CODE {
    let clear = 1 << self.lit_width
    self.write_code(dst, clear)
    self.width = self.lit_width + 1
    self.hi = clear + 1
    self.overflow = clear << 1
    for i in 0..<TABLE_SIZE {
      self.table[i] = 0U
    }
    return true
  }
  false
}

///|
async fn LzwCompressState::write_input_byte(
  self : LzwCompressState,
  dst : &@io.Writer,
  byte : Byte,
) -> Unit raise LzwError {
  let literal = byte.to_int()
  if self.saved_code == INVALID_CODE {
    let clear = 1 << self.lit_width
    self.write_code(dst, clear)
    self.saved_code = literal
    return
  }
  let mut code = self.saved_code
  let key = (code << 8) | literal
  let mut hash = ((key >> 12) ^ key) & TABLE_MASK
  while self.table[hash] != 0U {
    let t = self.table[hash]
    if key.reinterpret_as_uint() == t >> 12 {
      self.saved_code = (t & MAX_CODE.reinterpret_as_uint()).reinterpret_as_int()
      return
    }
    hash = (hash + 1) & TABLE_MASK
  }
  self.write_code(dst, code)
  code = literal
  self.saved_code = code
  if self.inc_hi(dst) {
    return
  }
  while self.table[hash] != 0U {
    hash = (hash + 1) & TABLE_MASK
  }
  self.table[hash] = (key.reinterpret_as_uint() << 12) |
    self.hi.reinterpret_as_uint()
}

///|
async fn LzwCompressState::finish(
  self : LzwCompressState,
  dst : &@io.Writer,
) -> Unit raise LzwError {
  if self.saved_code != INVALID_CODE {
    self.write_code(dst, self.saved_code)
    ignore(self.inc_hi(dst))
  } else {
    let clear = 1 << self.lit_width
    self.write_code(dst, clear)
  }
  let eof = (1 << self.lit_width) + 1
  self.write_code(dst, eof)
  if self.n_bits > 0 {
    match self.order {
      MSB => self.emit_byte(dst, (self.bits >> 24).to_byte())
      LSB => self.emit_byte(dst, (self.bits & 0xFFU).to_byte())
    }
  }
  self.output.flush(dst)
}
