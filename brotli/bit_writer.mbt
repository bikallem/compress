///|
/// LSB-first bit writer used by the Brotli encoder and test helpers.
priv struct BitWriter {
  mut buf : FixedArray[Byte]
  mut pos : Int
  mut bits : UInt64
  mut count : Int
}

///|
fn BitWriter::new(size_hint? : Int = 256) -> BitWriter {
  let capacity = if size_hint > 64 { size_hint } else { 64 }
  { buf: FixedArray::make(capacity, b'\x00'), pos: 0, bits: 0UL, count: 0 }
}

///|
fn BitWriter::ensure_capacity(self : BitWriter, needed : Int) -> Unit {
  if self.pos + needed > self.buf.length() {
    let new_cap = if self.buf.length() * 2 > self.pos + needed {
      self.buf.length() * 2
    } else {
      self.pos + needed
    }
    let new_buf = FixedArray::make(new_cap, b'\x00')
    @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.pos)
    self.buf = new_buf
  }
}

///|
fn BitWriter::write_bits(self : BitWriter, value : UInt, n : Int) -> Unit {
  if n == 0 {
    return
  }
  self.bits = self.bits | (value.to_uint64() << self.count)
  self.count += n
  while self.count >= 8 {
    self.ensure_capacity(1)
    self.buf[self.pos] = (self.bits & 0xFFUL).to_byte()
    self.pos += 1
    self.bits = self.bits >> 8
    self.count -= 8
  }
}

///|
fn BitWriter::align_to_byte(self : BitWriter) -> Unit {
  if self.count > 0 {
    self.ensure_capacity(1)
    self.buf[self.pos] = (self.bits & 0xFFUL).to_byte()
    self.pos += 1
    self.bits = 0UL
    self.count = 0
  }
}

///|
fn BitWriter::write_bytes(self : BitWriter, data : BytesView) -> Unit {
  self.align_to_byte()
  let len = data.length()
  self.ensure_capacity(len)
  for i, b in data {
    self.buf[self.pos + i] = b
  }
  self.pos += len
}

///|
fn BitWriter::take_output(self : BitWriter) -> Bytes {
  Bytes::makei(self.pos, fn(i) { self.buf[i] })
}

///|
fn BitWriter::finish(self : BitWriter) -> Bytes {
  self.align_to_byte()
  self.take_output()
}
