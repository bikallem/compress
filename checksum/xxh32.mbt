///|
/// XXH32 prime constants.
const XXH32_PRIME1 : UInt = 0x9E3779B1_U

///|
const XXH32_PRIME2 : UInt = 0x85EBCA77_U

///|
const XXH32_PRIME3 : UInt = 0xC2B2AE3D_U

///|
const XXH32_PRIME4 : UInt = 0x27D4EB2F_U

///|
const XXH32_PRIME5 : UInt = 0x165667B1_U

///|
fn xxh32_round(acc : UInt, input : UInt) -> UInt {
  let acc = acc + input * XXH32_PRIME2
  let acc = xxh32_rotl(acc, 13)
  acc * XXH32_PRIME1
}

///|
fn xxh32_rotl(val : UInt, bits : Int) -> UInt {
  (val << bits) | (val >> (32 - bits))
}

///|
fn xxh32_read32(data : BytesView, offset : Int) -> UInt {
  data[offset].to_uint() |
    (data[offset + 1].to_uint() << 8) |
    (data[offset + 2].to_uint() << 16) |
    (data[offset + 3].to_uint() << 24)
}

///|
fn xxh32_avalanche(h_ : UInt) -> UInt {
  let mut h = h_
  h = h ^ (h >> 15)
  h = h * XXH32_PRIME2
  h = h ^ (h >> 13)
  h = h * XXH32_PRIME3
  h = h ^ (h >> 16)
  h
}

///|
/// Computes XXH32 checksum of the given bytes in one shot.
pub fn xxh32(data : BytesView, seed~ : UInt = 0U) -> UInt {
  let h = XXH32::new(seed~)
  h.update(data)
  h.checksum()
}

///|
/// XXH32 is an incremental XXH32 hasher.
pub struct XXH32 {
  seed : UInt
  mut v1 : UInt
  mut v2 : UInt
  mut v3 : UInt
  mut v4 : UInt
  mut total_len : UInt
  buf : FixedArray[Byte]
  mut buf_used : Int
}

///|
/// Creates a new XXH32 hasher.
pub fn XXH32::new(seed~ : UInt = 0U) -> XXH32 {
  {
    seed,
    v1: seed + XXH32_PRIME1 + XXH32_PRIME2,
    v2: seed + XXH32_PRIME2,
    v3: seed,
    v4: seed - XXH32_PRIME1,
    total_len: 0U,
    buf: FixedArray::make(16, b'\x00'),
    buf_used: 0,
  }
}

///|
pub impl Hasher for XXH32 with size(_self) -> Int {
  4
}

///|
pub impl Hasher for XXH32 with reset(self) -> Unit {
  self.v1 = self.seed + XXH32_PRIME1 + XXH32_PRIME2
  self.v2 = self.seed + XXH32_PRIME2
  self.v3 = self.seed
  self.v4 = self.seed - XXH32_PRIME1
  self.total_len = 0U
  self.buf_used = 0
}

///|
pub impl Hasher for XXH32 with update(self, data) -> Unit {
  let len = data.length()
  self.total_len = self.total_len + len.reinterpret_as_uint()
  let mut offset = 0
  // If we have buffered data, try to fill the 16-byte block
  if self.buf_used > 0 {
    let fill = 16 - self.buf_used
    let to_copy = if fill < len { fill } else { len }
    for i in 0..<to_copy {
      self.buf[self.buf_used + i] = data[i]
    }
    self.buf_used += to_copy
    offset += to_copy
    if self.buf_used == 16 {
      // Process the full buffer as a BytesView via temporary Bytes
      let buf_bytes = Bytes::makei(16, fn(i) { self.buf[i] })
      self.v1 = xxh32_round(self.v1, xxh32_read32(buf_bytes[:], 0))
      self.v2 = xxh32_round(self.v2, xxh32_read32(buf_bytes[:], 4))
      self.v3 = xxh32_round(self.v3, xxh32_read32(buf_bytes[:], 8))
      self.v4 = xxh32_round(self.v4, xxh32_read32(buf_bytes[:], 12))
      self.buf_used = 0
    }
  }
  // Process 16-byte blocks directly from input
  while offset + 16 <= len {
    self.v1 = xxh32_round(self.v1, xxh32_read32(data, offset))
    self.v2 = xxh32_round(self.v2, xxh32_read32(data, offset + 4))
    self.v3 = xxh32_round(self.v3, xxh32_read32(data, offset + 8))
    self.v4 = xxh32_round(self.v4, xxh32_read32(data, offset + 12))
    offset += 16
  }
  // Buffer remaining bytes
  while offset < len {
    self.buf[self.buf_used] = data[offset]
    self.buf_used += 1
    offset += 1
  }
}

///|
pub impl Hasher for XXH32 with checksum(self) -> UInt {
  let mut h : UInt = if self.total_len >= 16U {
    xxh32_rotl(self.v1, 1) +
      xxh32_rotl(self.v2, 7) +
      xxh32_rotl(self.v3, 12) +
      xxh32_rotl(self.v4, 18)
  } else {
    self.seed + XXH32_PRIME5
  }
  h = h + self.total_len
  // Process remaining buffered bytes
  let buf_bytes = Bytes::makei(self.buf_used, fn(i) { self.buf[i] })
  let mut i = 0
  while i + 4 <= self.buf_used {
    h = h + xxh32_read32(buf_bytes[:], i) * XXH32_PRIME3
    h = xxh32_rotl(h, 17) * XXH32_PRIME4
    i += 4
  }
  while i < self.buf_used {
    h = h + buf_bytes[i].to_uint() * XXH32_PRIME5
    h = xxh32_rotl(h, 11) * XXH32_PRIME1
    i += 1
  }
  xxh32_avalanche(h)
}
