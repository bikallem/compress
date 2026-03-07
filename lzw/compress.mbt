///|
/// Compresses data using the LZW algorithm.
/// `order` specifies the bit packing order (LSB for GIF, MSB for TIFF/PDF).
/// `lit_width` is the literal code width in bits (typically 8, range [2, 8]).
pub fn compress(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  let state = LzwCompressState::new(order, lit_width)
  state.write(data)
  state.close()
}

///|
/// Internal LZW compression state machine.
priv struct LzwCompressState {
  order : BitOrder
  lit_width : Int
  buf : @buffer.Buffer
  table : FixedArray[UInt]
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
    buf: @buffer.new(size_hint=256),
    table: FixedArray::make(TABLE_SIZE, 0U),
    width: 1 + lw,
    hi: (1 << lw) + 1,
    overflow: 1 << (lw + 1),
    saved_code: INVALID_CODE,
    bits: 0U,
    n_bits: 0,
  }
}

///|
fn LzwCompressState::write_code(self : LzwCompressState, code : Int) -> Unit {
  let c = code.reinterpret_as_uint()
  match self.order {
    LSB => {
      self.bits = self.bits | (c << self.n_bits)
      self.n_bits += self.width
      while self.n_bits >= 8 {
        self.buf.write_byte((self.bits & 0xFFU).to_byte())
        self.bits = self.bits >> 8
        self.n_bits -= 8
      }
    }
    MSB => {
      self.bits = self.bits | (c << (32 - self.width - self.n_bits))
      self.n_bits += self.width
      while self.n_bits >= 8 {
        self.buf.write_byte((self.bits >> 24).to_byte())
        self.bits = self.bits << 8
        self.n_bits -= 8
      }
    }
  }
}

///|
/// Increments hi and handles overflow/clear code emission.
/// Returns true if a clear code was emitted and the caller should continue.
fn LzwCompressState::inc_hi(self : LzwCompressState) -> Bool {
  self.hi += 1
  if self.hi == self.overflow {
    self.width += 1
    self.overflow = self.overflow << 1
  }
  if self.hi == MAX_CODE {
    let clear = 1 << self.lit_width
    self.write_code(clear)
    self.width = self.lit_width + 1
    self.hi = clear + 1
    self.overflow = clear << 1
    // Clear the hash table
    for i in 0..<TABLE_SIZE {
      self.table[i] = 0U
    }
    return true
  }
  false
}

///|
fn LzwCompressState::write(self : LzwCompressState, data : Bytes) -> Unit {
  if data.length() == 0 {
    return
  }
  let mut code = self.saved_code
  let mut start = 0
  if code == INVALID_CODE {
    // First write: send clear code
    let clear = 1 << self.lit_width
    self.write_code(clear)
    code = data[0].to_int()
    start = 1
  }
  for i in start..<data.length() {
    let literal = data[i].to_int()
    let key = (code << 8) | literal
    let mut hash = ((key >> 12) ^ key) & TABLE_MASK
    // Hash table lookup
    let mut found = false
    while self.table[hash] != 0U {
      let t = self.table[hash]
      if key.reinterpret_as_uint() == t >> 12 {
        code = (t & MAX_CODE.reinterpret_as_uint()).reinterpret_as_int()
        found = true
        break
      }
      hash = (hash + 1) & TABLE_MASK
    }
    if found {
      continue
    }
    // Not found: emit current code
    self.write_code(code)
    code = literal
    // Inc hi and possibly clear table
    if self.inc_hi() {
      continue
    }
    // Insert into hash table
    while self.table[hash] != 0U {
      hash = (hash + 1) & TABLE_MASK
    }
    self.table[hash] = (key.reinterpret_as_uint() << 12) |
      self.hi.reinterpret_as_uint()
  }
  self.saved_code = code
}

///|
fn LzwCompressState::close(self : LzwCompressState) -> Bytes {
  // Write the saved code if valid
  if self.saved_code != INVALID_CODE {
    self.write_code(self.saved_code)
    ignore(self.inc_hi())
  } else {
    // Write clear code since write was never called
    let clear = 1 << self.lit_width
    self.write_code(clear)
  }
  // Write EOF code
  let eof = (1 << self.lit_width) + 1
  self.write_code(eof)
  // Flush remaining bits
  if self.n_bits > 0 {
    match self.order {
      MSB => self.buf.write_byte((self.bits >> 24).to_byte())
      LSB => self.buf.write_byte((self.bits & 0xFFU).to_byte())
    }
  }
  self.buf.to_bytes()
}
