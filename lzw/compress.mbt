///|
/// Compresses data using the LZW algorithm.
/// `order` specifies the bit packing order (LSB for GIF, MSB for TIFF/PDF).
/// `lit_width` is the literal code width in bits (typically 8, range [2, 8]).
pub fn compress(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError {
  let def = Deflater::new(order, lit_width)
  let buf = @blit.Buffer::new(size_hint=256)
  match def.encode(Some(data[:])) {
    Data(chunk) => buf.write_bytesview(chunk)
    Ok | End | Error(_) => ()
  }
  match def.encode(None) {
    Data(chunk) => buf.write_bytesview(chunk)
    Ok | End | Error(_) => ()
  }
  buf.to_bytes()
}

///|
/// Internal LZW compression state machine.
priv struct Encoder {
  order : BitOrder
  lit_width : Int
  buf : @blit.Buffer
  table : FixedArray[UInt]
  mut width : Int
  mut hi : Int
  mut overflow : Int
  mut saved_code : Int
  mut bits : UInt
  mut n_bits : Int
}

///|
fn Encoder::new(order : BitOrder, lit_width : Int) -> Encoder {
  let lw = lit_width
  {
    order,
    lit_width: lw,
    buf: @blit.Buffer::new(size_hint=4096),
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
fn Encoder::write_code(self : Encoder, code : Int) -> Unit {
  let c = code.reinterpret_as_uint()
  self.buf.ensure_capacity(16)
  let out = self.buf.data()
  let initial_pos = self.buf.length()
  let mut pos = initial_pos
  match self.order {
    LSB => {
      self.bits = self.bits | (c << self.n_bits)
      self.n_bits += self.width
      while self.n_bits >= 8 {
        out.unsafe_set(pos, (self.bits & 0xFFU).to_byte())
        pos += 1
        self.bits = self.bits >> 8
        self.n_bits -= 8
      }
    }
    MSB => {
      self.bits = self.bits | (c << (32 - self.width - self.n_bits))
      self.n_bits += self.width
      while self.n_bits >= 8 {
        out.unsafe_set(pos, (self.bits >> 24).to_byte())
        pos += 1
        self.bits = self.bits << 8
        self.n_bits -= 8
      }
    }
  }
  self.buf.unsafe_advance(pos - initial_pos)
}

///|
/// Increments hi and handles overflow/clear code emission.
/// Returns true if a clear code was emitted and the caller should continue.
fn Encoder::inc_hi(self : Encoder) -> Bool {
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
      self.table.unsafe_set(i, 0U)
    }
    return true
  }
  false
}

///|
fn Encoder::write(self : Encoder, data : BytesView) -> Unit {
  if data.length() == 0 {
    return
  }
  let mut code = self.saved_code
  let mut start = 0
  if code == INVALID_CODE {
    // First write: send clear code
    let clear = 1 << self.lit_width
    self.write_code(clear)
    code = data.unsafe_get(0).to_int()
    start = 1
  }
  let table = self.table
  for i in start..<data.length() {
    let literal = data[i].to_int()
    let key = (code << 8) | literal
    let mut hash = ((key >> 12) ^ key) & TABLE_MASK
    // Hash table lookup with unsafe access (hash is always masked to TABLE_MASK)
    let mut found = false
    while table.unsafe_get(hash) != 0U {
      let t = table.unsafe_get(hash)
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
    while table.unsafe_get(hash) != 0U {
      hash = (hash + 1) & TABLE_MASK
    }
    table.unsafe_set(
      hash,
      (key.reinterpret_as_uint() << 12) | self.hi.reinterpret_as_uint(),
    )
  }
  self.saved_code = code
}

///|
/// Take accumulated output so far without closing the encoder.
fn Encoder::take_output(self : Encoder) -> BytesView {
  if self.buf.length() == 0 {
    return b""[:]
  }
  let result = self.buf.to_bytes()
  self.buf.reset()
  result[:]
}

///|
fn Encoder::close(self : Encoder) -> BytesView {
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
  let result = self.buf.to_bytes()
  result[:]
}
