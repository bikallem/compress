///|
/// Pure bit buffer for DEFLATE decoding. No I/O dependencies.
/// Pulls bytes from a caller-supplied Bytes segment. Returns false
/// from ensure() when more input is needed (caller provides via refill).
priv struct BitBuf {
  mut buf : UInt64
  mut count : Int
  mut input : Bytes
  mut pos : Int
}

///|
fn BitBuf::new() -> BitBuf {
  { buf: 0UL, count: 0, input: Bytes::default(), pos: 0 }
}

///|
/// Replace the input segment. Called when the caller has new data.
fn BitBuf::set_input(self : BitBuf, data : Bytes) -> Unit {
  self.input = data
  self.pos = 0
}

///|
/// Pack bytes from input into the bit accumulator (up to 56 bits).
fn BitBuf::fill(self : BitBuf) -> Unit {
  let input = self.input
  let input_len = input.length()
  let (buf, count, pos) = for buf = self.buf, count = self.count, pos = self.pos
    count <= 56 && pos < input_len {
    continue buf | (input[pos].to_uint64() << count), count + 8, pos + 1
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
/// Read n bits from the buffer. Caller must ensure enough bits via ensure().
fn BitBuf::read_unchecked(self : BitBuf, n : Int) -> Int {
  let mask = (1UL << n) - 1UL
  let val = (self.buf & mask).to_int()
  self.buf = self.buf >> n
  self.count -= n
  val
}

///|
/// Try to read n bits. Returns None if insufficient bits.
fn BitBuf::read(self : BitBuf, n : Int) -> Int? {
  if not(self.ensure(n)) {
    return None
  }
  Some(self.read_unchecked(n))
}

///|
/// Discard bits to align to byte boundary.
fn BitBuf::align_to_byte(self : BitBuf) -> Unit {
  let discard = self.count % 8
  if discard > 0 {
    self.buf = self.buf >> discard
    self.count -= discard
  }
}

///|
/// Returns a view of up to max_len unconsumed input bytes.
/// Drains buffered whole bytes first, then reads from input.
fn BitBuf::next_bytes(self : BitBuf, max_len : Int) -> Bytes {
  // First drain any whole bytes from the bit buffer
  if self.count >= 8 && max_len > 0 {
    let n_from_buf = if self.count / 8 < max_len {
      self.count / 8
    } else {
      max_len
    }
    let result = FixedArray::make(n_from_buf, b'\x00')
    for i in 0..<n_from_buf {
      result[i] = (self.buf & 0xFFUL).to_byte()
      self.buf = self.buf >> 8
      self.count -= 8
    }
    return result.unsafe_reinterpret_as_bytes()
  }
  // Read from input
  let avail = self.input.length() - self.pos
  if avail <= 0 {
    return Bytes::default()
  }
  let n = if avail < max_len { avail } else { max_len }
  let start = self.pos
  self.pos += n
  Bytes::makei(n, fn(i) { self.input[start + i] })
}

///|
/// Returns true if there is any data available (bits or input).
fn BitBuf::_has_data(self : BitBuf) -> Bool {
  self.count > 0 || self.pos < self.input.length()
}

///|
/// Returns any unconsumed bytes (from bit buffer + remaining input).
fn BitBuf::remaining(self : BitBuf) -> Bytes {
  self.align_to_byte()
  let num_bytes = self.count / 8
  let remaining_input = self.input.length() - self.pos
  let total = num_bytes + remaining_input
  if total == 0 {
    return Bytes::default()
  }
  let result = FixedArray::make(total, b'\x00')
  let mut b = self.buf
  for i in 0..<num_bytes {
    result[i] = (b & 0xFFUL).to_byte()
    b = b >> 8
  }
  for i in 0..<remaining_input {
    result[num_bytes + i] = self.input[self.pos + i]
  }
  result.unsafe_reinterpret_as_bytes()
}
