///|
/// Compresses data from `src` to `dst` using the LZW algorithm (streaming).
/// `order` specifies the bit packing order (LSB for GIF, MSB for TIFF/PDF).
/// `lit_width` is the literal code width in bits (typically 8, range [2, 8]).
pub async fn compress(
  src : &@io.Reader,
  dst : &@io.Writer,
  order : BitOrder,
  lit_width? : Int = 8,
) -> Unit raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  let enc = LzwEncoder::new(order, lit_width)
  // Send clear code
  let clear = 1 << lit_width
  enc.write_code(clear)
  // Read first byte
  let first = src.read_byte() catch {
    _ => {
      // Empty input — emit EOF and flush
      enc.write_code(clear + 1)
      enc.flush_remaining_bits()
      enc.flush_to_writer(dst)
      return
    }
  }
  enc.saved_code = first.to_int()
  // Process remaining bytes
  while true {
    let b = src.read_byte() catch { _ => break }
    enc.process_byte(b)
    // Periodically flush buffer to writer to bound memory
    if enc.buf.length() >= 8192 {
      enc.flush_to_writer(dst)
    }
  }
  enc.close()
  enc.flush_to_writer(dst)
}

///|
/// Compresses `data` bytes using the LZW algorithm, returning compressed bytes.
pub fn compress_bytes(
  data : Bytes,
  order : BitOrder,
  lit_width? : Int = 8,
) -> Bytes raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
  let enc = LzwEncoder::new(order, lit_width)
  enc.write_data(data)
  enc.close()
  enc.buf.to_bytes()
}

///|
/// Internal LZW compression state machine.
priv struct LzwEncoder {
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
fn LzwEncoder::new(order : BitOrder, lit_width : Int) -> LzwEncoder {
  {
    order,
    lit_width,
    buf: @buffer.new(size_hint=256),
    table: FixedArray::make(TABLE_SIZE, 0U),
    width: 1 + lit_width,
    hi: (1 << lit_width) + 1,
    overflow: 1 << (lit_width + 1),
    saved_code: INVALID_CODE,
    bits: 0U,
    n_bits: 0,
  }
}

///|
fn LzwEncoder::write_code(self : LzwEncoder, code : Int) -> Unit {
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
fn LzwEncoder::inc_hi(self : LzwEncoder) -> Bool {
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
    for i in 0..<TABLE_SIZE {
      self.table[i] = 0U
    }
    return true
  }
  false
}

///|
/// Processes one input byte through the LZW state machine.
fn LzwEncoder::process_byte(self : LzwEncoder, b : Byte) -> Unit {
  let literal = b.to_int()
  let code = self.saved_code
  let key = (code << 8) | literal
  let mut hash = ((key >> 12) ^ key) & TABLE_MASK
  // Hash table lookup
  let mut found = false
  while self.table[hash] != 0U {
    let t = self.table[hash]
    if key.reinterpret_as_uint() == t >> 12 {
      self.saved_code = (t & MAX_CODE.reinterpret_as_uint()).reinterpret_as_int()
      found = true
      break
    }
    hash = (hash + 1) & TABLE_MASK
  }
  if found {
    return
  }
  // Not found: emit current code
  self.write_code(code)
  self.saved_code = literal
  // Inc hi and possibly clear table
  if self.inc_hi() {
    return
  }
  // Insert into hash table
  while self.table[hash] != 0U {
    hash = (hash + 1) & TABLE_MASK
  }
  self.table[hash] = (key.reinterpret_as_uint() << 12) |
    self.hi.reinterpret_as_uint()
}

///|
/// Processes an entire Bytes input through the encoder.
fn LzwEncoder::write_data(self : LzwEncoder, data : Bytes) -> Unit {
  if data.length() == 0 {
    return
  }
  let mut code = self.saved_code
  let mut start = 0
  if code == INVALID_CODE {
    let clear = 1 << self.lit_width
    self.write_code(clear)
    code = data[0].to_int()
    start = 1
  }
  for i in start..<data.length() {
    let literal = data[i].to_int()
    let key = (code << 8) | literal
    let mut hash = ((key >> 12) ^ key) & TABLE_MASK
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
    self.write_code(code)
    code = literal
    if self.inc_hi() {
      continue
    }
    while self.table[hash] != 0U {
      hash = (hash + 1) & TABLE_MASK
    }
    self.table[hash] = (key.reinterpret_as_uint() << 12) |
      self.hi.reinterpret_as_uint()
  }
  self.saved_code = code
}

///|
/// Flushes remaining bits to the buffer.
fn LzwEncoder::flush_remaining_bits(self : LzwEncoder) -> Unit {
  if self.n_bits > 0 {
    match self.order {
      MSB => self.buf.write_byte((self.bits >> 24).to_byte())
      LSB => self.buf.write_byte((self.bits & 0xFFU).to_byte())
    }
  }
}

///|
/// Emits saved_code + EOF code + flushes remaining bits.
fn LzwEncoder::close(self : LzwEncoder) -> Unit {
  if self.saved_code != INVALID_CODE {
    self.write_code(self.saved_code)
    ignore(self.inc_hi())
  } else {
    let clear = 1 << self.lit_width
    self.write_code(clear)
  }
  let eof = (1 << self.lit_width) + 1
  self.write_code(eof)
  self.flush_remaining_bits()
}

///|
/// Flushes the internal buffer to an async writer, then resets the buffer.
async fn LzwEncoder::flush_to_writer(
  self : LzwEncoder,
  dst : &@io.Writer,
) -> Unit raise LzwError {
  let bytes = self.buf.to_bytes()
  if bytes.length() > 0 {
    dst.write(bytes[:]) catch {
      _ => raise LzwError::InvalidCode("write error")
    }
    self.buf.reset()
  }
}
