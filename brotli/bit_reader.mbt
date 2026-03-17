///|
/// LSB-first bit reader used by Brotli prefix-code and metablock parsers.
priv struct BitReader {
  mut buf : UInt64
  mut count : Int
  mut input : BytesView
  mut pos : Int
}

///|
priv struct BitReaderSnapshot {
  buf : UInt64
  count : Int
  pos : Int
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
fn BitReader::snapshot(self : BitReader) -> BitReaderSnapshot {
  { buf: self.buf, count: self.count, pos: self.pos }
}

///|
fn BitReader::restore(self : BitReader, snapshot : BitReaderSnapshot) -> Unit {
  self.buf = snapshot.buf
  self.count = snapshot.count
  self.pos = snapshot.pos
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
fn BitReader::align_to_byte_zero(self : BitReader) -> Unit raise BrotliError {
  let discard = self.count % 8
  if discard == 0 {
    return
  }
  guard self.peek_unchecked(discard) == 0U else {
    raise BrotliError::CorruptInput("non-zero padding bits")
  }
  self.drop(discard)
}

///|
fn BitReader::read_aligned_bytes(self : BitReader, max_len : Int) -> Bytes {
  if max_len <= 0 {
    return Bytes::default()
  }
  let buffered = self.count / 8
  let remaining = self.input.length() - self.pos
  let total = buffered + remaining
  let len = if max_len < total { max_len } else { total }
  if len == 0 {
    return Bytes::default()
  }
  let output = FixedArray::make(len, b'\x00')
  let from_buffer = if buffered < len { buffered } else { len }
  let mut bits = self.buf
  for i in 0..<from_buffer {
    output[i] = (bits & 0xFFUL).to_byte()
    bits = bits >> 8
  }
  if from_buffer > 0 {
    self.drop(from_buffer * 8)
  }
  let from_input = len - from_buffer
  for i in 0..<from_input {
    output[from_buffer + i] = self.input[self.pos + i]
  }
  self.pos += from_input
  output.unsafe_reinterpret_as_bytes()
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
