///|
/// Backward bit reader for sequence decoding in zstd.
/// Zstd sequences use a backward bit stream: bytes are read from end to start.
priv struct BackwardBitReader {
  data : BytesView
  mut byte_pos : Int // current byte position (decreasing)
  mut bits : UInt64
  mut n_bits : Int
}

///|
fn BackwardBitReader::new(
  data : BytesView,
) -> BackwardBitReader raise ZstdError {
  let len = data.length()
  guard len > 0 else { raise ZstdError::CorruptData("empty backward stream") }
  // Find the highest set bit in the last byte to establish initial position
  let last_byte = data.unsafe_get(len - 1).to_int()
  guard last_byte != 0 else {
    raise ZstdError::CorruptData("zero padding byte in backward stream")
  }
  // Count leading zeros to find the sentinel bit
  let mut sentinel_bits = 0
  let mut b = last_byte
  while (b & 0x80) == 0 {
    sentinel_bits += 1
    b = b << 1
  }
  // Skip the sentinel bit
  let init_bits = 7 - sentinel_bits
  let init_val = (last_byte & ((1 << init_bits) - 1))
    .reinterpret_as_uint()
    .to_uint64()
  { data, byte_pos: len - 2, bits: init_val, n_bits: init_bits }
}

///|
fn BackwardBitReader::refill(self : BackwardBitReader) -> Unit {
  while self.n_bits <= 56 && self.byte_pos >= 0 {
    self.bits = (self.bits << 8) |
      self.data.unsafe_get(self.byte_pos).to_uint().to_uint64()
    self.byte_pos -= 1
    self.n_bits += 8
  }
}

///|
fn BackwardBitReader::read_bits(self : BackwardBitReader, n : Int) -> UInt {
  self.refill()
  self.n_bits -= n
  let val = (self.bits >> self.n_bits) &
    (if n >= 32 { 0xFFFFFFFF_U.to_uint64() } else { (1UL << n) - 1UL })
  val.to_uint()
}
