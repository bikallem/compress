///|
/// LSB-first bit reader used by Brotli prefix-code and metablock parsers.
priv struct BitReader {
  mut buf : UInt64
  mut count : Int
  mut input : BytesView
  mut pos : Int
}

///|
fn BitReader::new() -> BitReader {
  { buf: 0UL, count: 0, input: b""[:], pos: 0 }
}

///|
fn BitReader::set_input(self : BitReader, data : BytesView) -> Unit {
  self.input = data
  self.pos = 0
}

///|
fn BitReader::fill(self : BitReader) -> Unit {
  let input = self.input
  let input_len = input.length()
  let (buf, count, pos) = for buf = self.buf, count = self.count, pos = self.pos; count <=
                             56 &&
                             pos < input_len; {
    continue buf | (input[pos].to_uint64() << count), count + 8, pos + 1
  } nobreak {
    (buf, count, pos)
  }
  self.buf = buf
  self.count = count
  self.pos = pos
}

///|
fn BitReader::ensure(self : BitReader, n : Int) -> Bool {
  if self.count >= n {
    return true
  }
  self.fill()
  self.count >= n
}

///|
fn BitReader::peek_unchecked(self : BitReader, n : Int) -> UInt {
  let mask = (1UL << n) - 1UL
  (self.buf & mask).to_uint()
}

///|
fn BitReader::peek(self : BitReader, n : Int) -> UInt? {
  if !self.ensure(n) {
    return None
  }
  Some(self.peek_unchecked(n))
}

///|
fn BitReader::drop(self : BitReader, n : Int) -> Unit {
  self.buf = self.buf >> n
  self.count -= n
}

///|
fn BitReader::read_unchecked(self : BitReader, n : Int) -> Int {
  let value = self.peek_unchecked(n).reinterpret_as_int()
  self.drop(n)
  value
}

///|
fn BitReader::read(self : BitReader, n : Int) -> Int? {
  if !self.ensure(n) {
    return None
  }
  Some(self.read_unchecked(n))
}

///|
fn BitReader::read_bit(self : BitReader) -> Bool? {
  match self.read(1) {
    Some(v) => Some(v != 0)
    None => None
  }
}

///|
fn BitReader::align_to_byte(self : BitReader) -> Unit {
  let discard = self.count % 8
  if discard > 0 {
    self.drop(discard)
  }
}

///|
fn BitReader::remaining_bytes(self : BitReader) -> Bytes {
  self.align_to_byte()
  let buffered = self.count / 8
  let remaining = self.input.length() - self.pos
  let total = buffered + remaining
  if total == 0 {
    return Bytes::default()
  }
  let result = FixedArray::make(total, b'\x00')
  let mut bits = self.buf
  for i in 0..<buffered {
    result[i] = (bits & 0xFFUL).to_byte()
    bits = bits >> 8
  }
  for i in 0..<remaining {
    result[buffered + i] = self.input[self.pos + i]
  }
  result.unsafe_reinterpret_as_bytes()
}

///|
fn BitReader::read_required(self : BitReader, n : Int) -> Int raise BrotliError {
  match self.read(n) {
    Some(v) => v
    None => raise BrotliError::UnexpectedEOF
  }
}
