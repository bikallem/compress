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
  let remaining = self.data.length() - self.byte_pos
  if remaining >= 8 && self.n_bits <= 0 {
    // Fast path: load 8 bytes at once into an empty buffer
    let d = self.data
    let p = self.byte_pos
    self.bits = d[p].to_uint().to_uint64() |
      (d[p + 1].to_uint().to_uint64() << 8) |
      (d[p + 2].to_uint().to_uint64() << 16) |
      (d[p + 3].to_uint().to_uint64() << 24) |
      (d[p + 4].to_uint().to_uint64() << 32) |
      (d[p + 5].to_uint().to_uint64() << 40) |
      (d[p + 6].to_uint().to_uint64() << 48) |
      (d[p + 7].to_uint().to_uint64() << 56)
    self.byte_pos += 8
    self.n_bits = 64
  } else if remaining >= 7 && self.n_bits <= 8 {
    // Fast path: load 7 bytes when we have room
    let d = self.data
    let p = self.byte_pos
    let n = self.n_bits
    self.bits = self.bits |
      (d[p].to_uint().to_uint64() << n) |
      (d[p + 1].to_uint().to_uint64() << (n + 8)) |
      (d[p + 2].to_uint().to_uint64() << (n + 16)) |
      (d[p + 3].to_uint().to_uint64() << (n + 24)) |
      (d[p + 4].to_uint().to_uint64() << (n + 32)) |
      (d[p + 5].to_uint().to_uint64() << (n + 40)) |
      (d[p + 6].to_uint().to_uint64() << (n + 48))
    self.byte_pos += 7
    self.n_bits += 56
  } else {
    while self.n_bits <= 56 && self.byte_pos < self.data.length() {
      self.bits = self.bits |
        (self.data[self.byte_pos].to_uint().to_uint64() << self.n_bits)
      self.byte_pos += 1
      self.n_bits += 8
    }
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
/// Read `len` bytes directly from the underlying data when the bit reader is
/// byte-aligned. Writes them into `sink` using bulk blit. This avoids per-byte
/// read_bits(8) calls for uncompressed metablocks.
fn BitReader::read_bytes_to_sink(
  self : BitReader,
  sink : @output_sink.OutputSink,
  len : Int,
) -> Unit {
  // First, drain any buffered bits as individual bytes
  let mut remaining = len
  while remaining > 0 && self.n_bits >= 8 {
    sink.write_byte((self.bits & 0xFFUL).to_uint().to_byte())
    self.bits = self.bits >> 8
    self.n_bits -= 8
    remaining -= 1
  }
  if remaining <= 0 {
    return
  }
  // Now n_bits < 8. If n_bits == 0, we can bulk copy from data.
  // If n_bits > 0, we have partial bits that don't form a full byte,
  // which shouldn't happen after byte alignment, but handle gracefully.
  if self.n_bits == 0 {
    // Bulk copy directly from input data to sink
    sink.write_bytesview(self.data, self.byte_pos, remaining)
    self.byte_pos += remaining
  } else {
    // Fallback: read byte by byte
    for _ in 0..<remaining {
      self.refill()
      let b = (self.bits & 0xFFUL).to_uint().to_byte()
      self.bits = self.bits >> 8
      self.n_bits -= 8
      sink.write_byte(b)
    }
  }
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
  let mask = (1UL << n) - 1UL
  self.bits = self.bits | ((val.reinterpret_as_uint().to_uint64() & mask) << self.n_bits)
  self.n_bits += n
  if self.n_bits >= 8 {
    self.flush()
  }
}

///|
fn BitWriter::flush(self : BitWriter) -> Unit {
  if self.n_bits < 8 {
    return
  }
  // At most 8 bytes can be flushed (64 bits / 8)
  self.ensure_capacity(8)
  while self.n_bits >= 8 {
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
