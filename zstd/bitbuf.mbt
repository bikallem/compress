///|
priv enum BitReloadStatus {
  Unfinished
  EndOfBuffer
  Completed
  Overflow
}

///|
/// Backward bit reader for zstd bitstreams.
/// This mirrors the reference `BIT_DStream_t` behavior closely enough for
/// Huffman, FSE, and sequence decoding.
priv struct BackwardBitReader {
  data : BytesView
  mut ptr : Int
  mut bits : UInt64
  mut bits_consumed : Int
}

///|
fn read_le64_padded(src : BytesView, pos : Int) -> UInt64 {
  let b0 = if pos < src.length() { src.unsafe_get(pos).to_uint() } else { 0U }
  let b1 = if pos + 1 < src.length() {
    src.unsafe_get(pos + 1).to_uint()
  } else {
    0U
  }
  let b2 = if pos + 2 < src.length() {
    src.unsafe_get(pos + 2).to_uint()
  } else {
    0U
  }
  let b3 = if pos + 3 < src.length() {
    src.unsafe_get(pos + 3).to_uint()
  } else {
    0U
  }
  let b4 = if pos + 4 < src.length() {
    src.unsafe_get(pos + 4).to_uint()
  } else {
    0U
  }
  let b5 = if pos + 5 < src.length() {
    src.unsafe_get(pos + 5).to_uint()
  } else {
    0U
  }
  let b6 = if pos + 6 < src.length() {
    src.unsafe_get(pos + 6).to_uint()
  } else {
    0U
  }
  let b7 = if pos + 7 < src.length() {
    src.unsafe_get(pos + 7).to_uint()
  } else {
    0U
  }
  b0.to_uint64() |
  (b1.to_uint64() << 8) |
  (b2.to_uint64() << 16) |
  (b3.to_uint64() << 24) |
  (b4.to_uint64() << 32) |
  (b5.to_uint64() << 40) |
  (b6.to_uint64() << 48) |
  (b7.to_uint64() << 56)
}

///|
fn BackwardBitReader::new(
  data : BytesView,
) -> BackwardBitReader raise ZstdError {
  let len = data.length()
  guard len > 0 else { raise ZstdError::CorruptData("empty backward stream") }
  let last_byte = data.unsafe_get(len - 1).to_int()
  guard last_byte != 0 else {
    raise ZstdError::CorruptData("zero padding byte in backward stream")
  }
  let ptr = if len >= 8 { len - 8 } else { 0 }
  let bits_consumed = 9 -
    highest_bit(last_byte) +
    (if len < 8 { (8 - len) * 8 } else { 0 })
  { data, ptr, bits: read_le64_padded(data, ptr), bits_consumed }
}

///|
fn BackwardBitReader::available_bits(self : BackwardBitReader) -> Int {
  if self.bits_consumed > 64 {
    0
  } else {
    64 - self.bits_consumed
  }
}

///|
fn BackwardBitReader::remaining_bits(self : BackwardBitReader) -> Int {
  self.available_bits() + self.ptr * 8
}

///|
fn BackwardBitReader::reload(self : BackwardBitReader) -> BitReloadStatus {
  if self.bits_consumed > 64 {
    return BitReloadStatus::Overflow
  }
  if self.ptr >= 8 {
    self.ptr -= self.bits_consumed >> 3
    self.bits_consumed = self.bits_consumed & 7
    self.bits = read_le64_padded(self.data, self.ptr)
    return BitReloadStatus::Unfinished
  }
  if self.ptr == 0 {
    if self.bits_consumed < 64 {
      return BitReloadStatus::EndOfBuffer
    }
    return BitReloadStatus::Completed
  }
  let mut nb_bytes = self.bits_consumed >> 3
  let mut status = BitReloadStatus::Unfinished
  if self.ptr - nb_bytes < 0 {
    nb_bytes = self.ptr
    status = BitReloadStatus::EndOfBuffer
  }
  self.ptr -= nb_bytes
  self.bits_consumed -= nb_bytes * 8
  self.bits = read_le64_padded(self.data, self.ptr)
  status
}

///|
fn BackwardBitReader::ensure_bits(self : BackwardBitReader, n : Int) -> Bool {
  guard n >= 0 else { return false }
  while self.available_bits() < n {
    match self.reload() {
      BitReloadStatus::Unfinished => ()
      BitReloadStatus::EndOfBuffer
      | BitReloadStatus::Completed
      | BitReloadStatus::Overflow => break
    }
  }
  self.available_bits() >= n
}

///|
fn BackwardBitReader::can_read(self : BackwardBitReader, n : Int) -> Bool {
  self.remaining_bits() >= n
}

///|
fn BackwardBitReader::look_bits(self : BackwardBitReader, n : Int) -> UInt {
  guard n > 0 else { return 0U }
  let start = self.available_bits() - n
  let mask = if n >= 32 { 0xFFFFFFFF_U.to_uint64() } else { (1UL << n) - 1UL }
  ((self.bits >> start) & mask).to_uint()
}

///|
fn BackwardBitReader::peek_bits(self : BackwardBitReader, n : Int) -> UInt {
  if self.ensure_bits(n) {
    return self.look_bits(n)
  }
  let available = self.available_bits()
  if available <= 0 {
    return 0U
  }
  self.look_bits(available) << (n - available)
}

///|
fn BackwardBitReader::skip_bits(self : BackwardBitReader, n : Int) -> Unit {
  self.bits_consumed += n
}

///|
fn BackwardBitReader::read_bits(self : BackwardBitReader, n : Int) -> UInt {
  let value = self.look_bits(n)
  self.skip_bits(n)
  value
}

///|
fn BackwardBitReader::read_bits_checked(
  self : BackwardBitReader,
  n : Int,
) -> UInt raise ZstdError {
  guard self.ensure_bits(n) else { raise ZstdError::UnexpectedEOF }
  self.read_bits(n)
}

///|
fn BackwardBitReader::read_bits_padded(
  self : BackwardBitReader,
  n : Int,
) -> UInt {
  if self.ensure_bits(n) {
    return self.read_bits(n)
  }
  let available = self.available_bits()
  let value = if available <= 0 {
    0U
  } else {
    self.look_bits(available) << (n - available)
  }
  self.bits_consumed += n
  value
}

///|
fn BackwardBitReader::end_of_stream(self : BackwardBitReader) -> Bool {
  self.ptr == 0 && self.bits_consumed == 64
}

///|
fn BackwardBitReader::is_empty(self : BackwardBitReader) -> Bool {
  self.end_of_stream()
}
