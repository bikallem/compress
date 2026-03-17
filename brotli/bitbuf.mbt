///|
/// LSB-first bit reader for Brotli.
priv struct BitReader {
  data : BytesView
  mut byte_pos : Int
  mut bits : UInt64
  mut n_bits : Int
}

///|
fn BitReader::new(data : BytesView) -> BitReader {
  { data, byte_pos: 0, bits: 0UL, n_bits: 0 }
}

///|
fn BitReader::refill(self : BitReader) -> Unit {
  while self.n_bits <= 56 && self.byte_pos < self.data.length() {
    self.bits = self.bits |
      (self.data[self.byte_pos].to_uint().to_uint64() << self.n_bits)
    self.byte_pos += 1
    self.n_bits += 8
  }
}

///|
fn BitReader::read_bits(self : BitReader, n : Int) -> Int {
  if n == 0 {
    return 0
  }
  self.refill()
  let mask : UInt64 = (1UL << n) - 1UL
  let val = (self.bits & mask).to_uint().reinterpret_as_int()
  self.bits = self.bits >> n
  self.n_bits -= n
  val
}

///|
fn BitReader::read_bool(self : BitReader) -> Bool {
  self.read_bits(1) == 1
}

///|
/// LSB-first bit writer for Brotli compression.
priv struct BitWriter {
  mut buf : FixedArray[Byte]
  mut pos : Int
  mut bits : UInt64
  mut n_bits : Int
}

///|
fn BitWriter::new(capacity : Int) -> BitWriter {
  { buf: FixedArray::make(capacity, b'\x00'), pos: 0, bits: 0UL, n_bits: 0 }
}

///|
fn BitWriter::ensure_capacity(self : BitWriter, additional : Int) -> Unit {
  while self.pos + additional >= self.buf.length() {
    let old = self.buf
    let new_buf = FixedArray::make(old.length() * 2, b'\x00')
    FixedArray::unsafe_blit(new_buf, 0, old, 0, self.pos)
    self.buf = new_buf
  }
}

///|
fn BitWriter::write_bits(self : BitWriter, val : Int, n : Int) -> Unit {
  if n == 0 {
    return
  }
  self.bits = self.bits | (val.reinterpret_as_uint().to_uint64() << self.n_bits)
  self.n_bits += n
  self.flush()
}

///|
fn BitWriter::flush(self : BitWriter) -> Unit {
  while self.n_bits >= 8 {
    self.ensure_capacity(1)
    self.buf[self.pos] = (self.bits & 0xFFUL).to_uint().to_byte()
    self.pos += 1
    self.bits = self.bits >> 8
    self.n_bits -= 8
  }
}

///|
fn BitWriter::flush_final(self : BitWriter) -> Unit {
  if self.n_bits > 0 {
    self.ensure_capacity(1)
    self.buf[self.pos] = (self.bits & 0xFFUL).to_uint().to_byte()
    self.pos += 1
    self.bits = 0UL
    self.n_bits = 0
  }
}

///|
fn BitWriter::to_bytes(self : BitWriter) -> Bytes {
  self.flush_final()
  let result = @blit.make_uninit(self.pos)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.pos)
  result.unsafe_reinterpret_as_bytes()
}
