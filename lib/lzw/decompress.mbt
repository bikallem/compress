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
  let state = LzwDecompressState::new(order, lit_width)
  state.decompress(data)
}

///|
/// Internal LZW decompression state machine.
priv struct LzwDecompressState {
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
  // Bit reading state
  mut bits : UInt
  mut n_bits : Int
}

///|
fn LzwDecompressState::new(
  order : BitOrder,
  lit_width : Int,
) -> LzwDecompressState {
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
  }
}

///|
fn LzwDecompressState::read_code(
  self : LzwDecompressState,
  data : Bytes,
  pos : Ref[Int],
) -> Int raise LzwError {
  while self.n_bits < self.width {
    if pos.val >= data.length() {
      raise LzwError::UnexpectedEOF
    }
    let x = data[pos.val].to_uint()
    pos.val += 1
    match self.order {
      LSB => {
        self.bits = self.bits | (x << self.n_bits)
        self.n_bits += 8
      }
      MSB => {
        self.bits = self.bits | (x << (24 - self.n_bits))
        self.n_bits += 8
      }
    }
  }
  let code : Int = match self.order {
    LSB => {
      let mask = (1U << self.width) - 1U
      let c = (self.bits & mask).reinterpret_as_int()
      self.bits = self.bits >> self.width
      self.n_bits -= self.width
      c
    }
    MSB => {
      let c = (self.bits >> (32 - self.width)).reinterpret_as_int()
      self.bits = self.bits << self.width
      self.n_bits -= self.width
      c
    }
  }
  code
}

///|
fn LzwDecompressState::decompress(
  self : LzwDecompressState,
  data : Bytes,
) -> Bytes raise LzwError {
  let result = @buffer.new(size_hint=data.length() * 2)
  let pos = Ref::new(0)
  while true {
    let code = self.read_code(data, pos)
    if code < self.clear {
      // Literal code
      self.output[self.o] = code.to_byte()
      self.o += 1
      if self.last != DECODER_INVALID_CODE {
        self.suffix[self.hi] = code.to_byte()
        self.prefix[self.hi] = self.last
      }
    } else if code == self.clear {
      // Clear code: reset state
      self.width = 1 + self.lit_width
      self.hi = self.eof
      self.overflow = 1 << self.width
      self.last = DECODER_INVALID_CODE
      continue
    } else if code == self.eof {
      // EOF code
      // Flush remaining output
      for i in 0..<self.o {
        result.write_byte(self.output[i])
      }
      self.o = 0
      break
    } else if code <= self.hi {
      // Code in dictionary
      let mut c = code
      let mut i = self.output.length() - 1
      if code == self.hi && self.last != DECODER_INVALID_CODE {
        // Special case: code == hi
        c = self.last
        while c >= self.clear {
          c = self.prefix[c]
        }
        self.output[i] = c.to_byte()
        i -= 1
        c = self.last
      }
      // Walk the prefix chain
      while c >= self.clear {
        self.output[i] = self.suffix[c]
        i -= 1
        c = self.prefix[c]
      }
      self.output[i] = c.to_byte()
      // Copy decoded bytes to output position
      let decoded_len = self.output.length() - i
      for j in 0..<decoded_len {
        self.output[self.o + j] = self.output[i + j]
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
    // Flush output when buffer gets full
    if self.o >= 1 << MAX_WIDTH {
      for i in 0..<self.o {
        result.write_byte(self.output[i])
      }
      self.o = 0
    }
  }
  result.to_bytes()
}
