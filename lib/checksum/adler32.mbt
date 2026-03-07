///|
/// Largest prime smaller than 65536.
const ADLER32_MOD : UInt = 65521

///|
/// nmax is the largest n such that 255*n*(n+1)/2 + (n+1)*(mod-1) <= 2^32-1.
/// This bounds how many bytes we can process before reducing.
const ADLER32_NMAX : Int = 5552

///|
/// Computes Adler-32 checksum of the given bytes in one shot.
/// Uses 16x loop unrolling within NMAX-bounded chunks.
pub fn adler32(data : BytesView) -> UInt {
  // Try hardware acceleration first
  if adler32_try_hw(data) is Some(result) {
    return result
  }
  let mut s1 = 1U
  let mut s2 = 0U
  let mut offset = 0
  let len = data.length()
  while offset < len {
    let chunk_end = if offset + ADLER32_NMAX < len {
      offset + ADLER32_NMAX
    } else {
      len
    }
    let chunk_len = chunk_end - offset
    // Process 16 bytes at a time
    let unrolled_end = offset + (chunk_len & -16)
    while offset < unrolled_end {
      s1 = s1 + data[offset].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 1].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 2].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 3].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 4].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 5].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 6].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 7].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 8].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 9].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 10].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 11].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 12].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 13].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 14].to_uint()
      s2 = s2 + s1
      s1 = s1 + data[offset + 15].to_uint()
      s2 = s2 + s1
      offset += 16
    }
    // Remaining bytes in chunk
    while offset < chunk_end {
      s1 = s1 + data[offset].to_uint()
      s2 = s2 + s1
      offset += 1
    }
    s1 = s1 % ADLER32_MOD
    s2 = s2 % ADLER32_MOD
  }
  (s2 << 16) | s1
}

///|
/// Adler32 is an incremental Adler-32 hasher.
struct Adler32 {
  mut s1 : UInt
  mut s2 : UInt
}

///|
/// Creates a new Adler-32 hasher.
pub fn Adler32::new() -> Adler32 {
  { s1: 1U, s2: 0U }
}

///|
pub impl Hasher for Adler32 with size(_self) -> Int {
  4
}

///|
pub impl Hasher for Adler32 with reset(self) -> Unit {
  self.s1 = 1U
  self.s2 = 0U
}

///|
pub impl Hasher for Adler32 with update(self, data) -> Unit {
  let mut offset = 0
  let len = data.length()
  while offset < len {
    let chunk_end = if offset + ADLER32_NMAX < len {
      offset + ADLER32_NMAX
    } else {
      len
    }
    let chunk_len = chunk_end - offset
    let unrolled_end = offset + (chunk_len & -16)
    while offset < unrolled_end {
      self.s1 = self.s1 + data[offset].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 1].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 2].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 3].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 4].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 5].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 6].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 7].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 8].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 9].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 10].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 11].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 12].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 13].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 14].to_uint()
      self.s2 = self.s2 + self.s1
      self.s1 = self.s1 + data[offset + 15].to_uint()
      self.s2 = self.s2 + self.s1
      offset += 16
    }
    while offset < chunk_end {
      self.s1 = self.s1 + data[offset].to_uint()
      self.s2 = self.s2 + self.s1
      offset += 1
    }
    self.s1 = self.s1 % ADLER32_MOD
    self.s2 = self.s2 % ADLER32_MOD
  }
}

///|
pub impl Hasher for Adler32 with checksum(self) -> UInt {
  (self.s2 << 16) | self.s1
}
