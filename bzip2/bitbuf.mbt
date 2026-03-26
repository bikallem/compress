///|
/// MSB-first bit buffer for streaming bzip2 decompression.
/// Pulls bytes from a caller-supplied Bytes segment. Returns false
/// from ensure() when more input is needed (caller provides via set_input).
priv struct BitBuf {
  mut buf : UInt64
  mut count : Int
  mut input : BytesView
  mut pos : Int
}

///|
fn BitBuf::new() -> BitBuf {
  { buf: 0UL, count: 0, input: b""[:], pos: 0 }
}

///|
/// Replace the input segment. Called when the caller has new data.
fn BitBuf::set_input(self : BitBuf, data : BytesView) -> Unit {
  self.input = data
  self.pos = 0
}

///|
/// Pack bytes from input into the bit accumulator (up to 56 bits).
/// MSB-first: new bytes go into the least significant positions,
/// existing bits stay at the top.
fn BitBuf::fill(self : BitBuf) -> Unit {
  let input = self.input
  let input_len = input.length()
  let (buf, count, pos) = for buf = self.buf, count = self.count, pos = self.pos; count <=
                             56 &&
                             pos < input_len; {
    continue buf | (input.unsafe_get(pos).to_uint64() << (56 - count)),
      count + 8,
      pos + 1
  } nobreak {
    (buf, count, pos)
  }
  self.buf = buf
  self.count = count
  self.pos = pos
}

///|
/// Ensure at least n bits are available. Returns false if input exhausted.
fn BitBuf::ensure(self : BitBuf, n : Int) -> Bool {
  if self.count >= n {
    return true
  }
  self.fill()
  self.count >= n
}

///|
/// Read n bits MSB-first from the buffer. Caller must ensure enough bits.
fn BitBuf::read_unchecked(self : BitBuf, n : Int) -> UInt {
  let val = (self.buf >> (64 - n)).to_uint()
  self.buf = self.buf << n
  self.count -= n
  val
}

///|
/// Try to read n bits MSB-first. Returns None if insufficient bits.
fn BitBuf::read(self : BitBuf, n : Int) -> UInt? {
  if !self.ensure(n) {
    return None
  }
  Some(self.read_unchecked(n))
}

///|
/// Try to read 1 bit. Returns None if insufficient bits.
fn BitBuf::read_bit(self : BitBuf) -> Bool? {
  match self.read(1) {
    Some(v) => Some(v != 0U)
    None => None
  }
}

///|
fn BitBuf::remaining(self : BitBuf) -> Bytes {
  let skip_bits = self.count % 8
  let buffered_bits = self.count - skip_bits
  let buffered_bytes = buffered_bits / 8
  let trailing_len = self.input.length() - self.pos
  let out = @blit.Buffer::new(size_hint=buffered_bytes + trailing_len)
  let shifted = self.buf << skip_bits
  for i in 0..<buffered_bytes {
    out.write_byte(((shifted >> (56 - i * 8)) & 0xFFUL).to_byte())
  }
  if trailing_len > 0 {
    out.write_bytesview(self.input[self.pos:])
  }
  out.to_bytes()
}
