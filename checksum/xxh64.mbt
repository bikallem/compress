///|
/// XXH64 prime constants.
const XXH64_PRIME1 : UInt64 = 0x9E3779B185EBCA87UL

///|
const XXH64_PRIME2 : UInt64 = 0xC2B2AE3D27D4EB4FUL

///|
const XXH64_PRIME3 : UInt64 = 0x165667B19E3779F9UL

///|
const XXH64_PRIME4 : UInt64 = 0x85EBCA77C2B2AE63UL

///|
const XXH64_PRIME5 : UInt64 = 0x27D4EB2F165667C5UL

///|
fn xxh64_round(acc : UInt64, input : UInt64) -> UInt64 {
  let acc = acc + input * XXH64_PRIME2
  let acc = xxh64_rotl(acc, 31)
  acc * XXH64_PRIME1
}

///|
fn xxh64_merge_round(acc : UInt64, val : UInt64) -> UInt64 {
  let val = xxh64_round(0UL, val)
  let acc = acc ^ val
  acc * XXH64_PRIME1 + XXH64_PRIME4
}

///|
fn xxh64_rotl(val : UInt64, bits : Int) -> UInt64 {
  (val << bits) | (val >> (64 - bits))
}

///|
fn xxh64_read32(data : BytesView, offset : Int) -> UInt64 {
  data[offset].to_uint().to_uint64() |
  (data[offset + 1].to_uint().to_uint64() << 8) |
  (data[offset + 2].to_uint().to_uint64() << 16) |
  (data[offset + 3].to_uint().to_uint64() << 24)
}

///|
fn xxh64_read64(data : BytesView, offset : Int) -> UInt64 {
  data[offset].to_uint().to_uint64() |
  (data[offset + 1].to_uint().to_uint64() << 8) |
  (data[offset + 2].to_uint().to_uint64() << 16) |
  (data[offset + 3].to_uint().to_uint64() << 24) |
  (data[offset + 4].to_uint().to_uint64() << 32) |
  (data[offset + 5].to_uint().to_uint64() << 40) |
  (data[offset + 6].to_uint().to_uint64() << 48) |
  (data[offset + 7].to_uint().to_uint64() << 56)
}

///|
fn xxh64_avalanche(h_ : UInt64) -> UInt64 {
  let mut h = h_
  h = h ^ (h >> 33)
  h = h * XXH64_PRIME2
  h = h ^ (h >> 29)
  h = h * XXH64_PRIME3
  h = h ^ (h >> 32)
  h
}

///|
/// Computes XXH64 checksum of the given bytes in one shot.
pub fn xxh64(data : BytesView, seed? : UInt64 = 0UL) -> UInt64 {
  let h = XXH64::new(seed~)
  h.update(data)
  h.checksum64()
}

///|
/// XXH64 is an incremental XXH64 hasher.
pub struct XXH64 {
  seed : UInt64
  mut v1 : UInt64
  mut v2 : UInt64
  mut v3 : UInt64
  mut v4 : UInt64
  mut total_len : UInt64
  buf : FixedArray[Byte]
  mut buf_used : Int
}

///|
/// Creates a new XXH64 hasher.
pub fn XXH64::new(seed? : UInt64 = 0UL) -> XXH64 {
  {
    seed,
    v1: seed + XXH64_PRIME1 + XXH64_PRIME2,
    v2: seed + XXH64_PRIME2,
    v3: seed,
    v4: seed - XXH64_PRIME1,
    total_len: 0UL,
    buf: FixedArray::make(32, b'\x00'),
    buf_used: 0,
  }
}

///|
/// Returns the hash output size in bytes.
pub fn XXH64::size(_self : XXH64) -> Int {
  8
}

///|
/// Resets the hasher to its initial state.
pub fn XXH64::reset(self : XXH64) -> Unit {
  self.v1 = self.seed + XXH64_PRIME1 + XXH64_PRIME2
  self.v2 = self.seed + XXH64_PRIME2
  self.v3 = self.seed
  self.v4 = self.seed - XXH64_PRIME1
  self.total_len = 0UL
  self.buf_used = 0
}

///|
/// Feeds bytes into the running hash.
pub fn XXH64::update(self : XXH64, data : BytesView) -> Unit {
  let len = data.length()
  self.total_len = self.total_len + len.reinterpret_as_uint().to_uint64()
  let mut offset = 0
  // Fill buffered data first
  if self.buf_used > 0 {
    let fill = 32 - self.buf_used
    let to_copy = if fill < len { fill } else { len }
    for i in 0..<to_copy {
      self.buf[self.buf_used + i] = data[i]
    }
    self.buf_used += to_copy
    offset += to_copy
    if self.buf_used == 32 {
      let buf_bytes = Bytes::makei(32, fn(i) { self.buf[i] })
      self.v1 = xxh64_round(self.v1, xxh64_read64(buf_bytes[:], 0))
      self.v2 = xxh64_round(self.v2, xxh64_read64(buf_bytes[:], 8))
      self.v3 = xxh64_round(self.v3, xxh64_read64(buf_bytes[:], 16))
      self.v4 = xxh64_round(self.v4, xxh64_read64(buf_bytes[:], 24))
      self.buf_used = 0
    }
  }
  // Process 32-byte blocks directly from input
  while offset + 32 <= len {
    self.v1 = xxh64_round(self.v1, xxh64_read64(data, offset))
    self.v2 = xxh64_round(self.v2, xxh64_read64(data, offset + 8))
    self.v3 = xxh64_round(self.v3, xxh64_read64(data, offset + 16))
    self.v4 = xxh64_round(self.v4, xxh64_read64(data, offset + 24))
    offset += 32
  }
  // Buffer remaining bytes
  while offset < len {
    self.buf[self.buf_used] = data[offset]
    self.buf_used += 1
    offset += 1
  }
}

///|
/// Returns the current 64-bit checksum value.
pub fn XXH64::checksum64(self : XXH64) -> UInt64 {
  let mut h : UInt64 = if self.total_len >= 32UL {
    let mut h = xxh64_rotl(self.v1, 1) +
      xxh64_rotl(self.v2, 7) +
      xxh64_rotl(self.v3, 12) +
      xxh64_rotl(self.v4, 18)
    h = xxh64_merge_round(h, self.v1)
    h = xxh64_merge_round(h, self.v2)
    h = xxh64_merge_round(h, self.v3)
    h = xxh64_merge_round(h, self.v4)
    h
  } else {
    self.seed + XXH64_PRIME5
  }
  h = h + self.total_len
  // Process remaining buffered bytes
  let buf_bytes = Bytes::makei(self.buf_used, fn(i) { self.buf[i] })
  let mut i = 0
  while i + 8 <= self.buf_used {
    let k1 = xxh64_round(0UL, xxh64_read64(buf_bytes[:], i))
    h = h ^ k1
    h = xxh64_rotl(h, 27) * XXH64_PRIME1 + XXH64_PRIME4
    i += 8
  }
  while i + 4 <= self.buf_used {
    h = h ^ (xxh64_read32(buf_bytes[:], i) * XXH64_PRIME1)
    h = xxh64_rotl(h, 23) * XXH64_PRIME2 + XXH64_PRIME3
    i += 4
  }
  while i < self.buf_used {
    h = h ^ (buf_bytes[i].to_uint().to_uint64() * XXH64_PRIME5)
    h = xxh64_rotl(h, 11) * XXH64_PRIME1
    i += 1
  }
  xxh64_avalanche(h)
}
