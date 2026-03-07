///|
/// Largest prime smaller than 65536.
let adler32_mod : UInt = 65521

///|
/// nmax is the largest n such that 255*n*(n+1)/2 + (n+1)*(mod-1) <= 2^32-1.
/// This bounds how many bytes we can process before reducing.
let adler32_nmax : Int = 5552

///|
/// Computes Adler-32 checksum of the given bytes in one shot.
pub fn adler32(data : BytesView) -> UInt {
  let mut s1 = 1U
  let mut s2 = 0U
  let mut offset = 0
  let len = data.length()
  while offset < len {
    let chunk_end = if offset + adler32_nmax < len {
      offset + adler32_nmax
    } else {
      len
    }
    for i in offset..<chunk_end {
      s1 = s1 + data[i].to_uint()
      s2 = s2 + s1
    }
    s1 = s1 % adler32_mod
    s2 = s2 % adler32_mod
    offset = chunk_end
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
    let chunk_end = if offset + adler32_nmax < len {
      offset + adler32_nmax
    } else {
      len
    }
    for i in offset..<chunk_end {
      self.s1 = self.s1 + data[i].to_uint()
      self.s2 = self.s2 + self.s1
    }
    self.s1 = self.s1 % adler32_mod
    self.s2 = self.s2 % adler32_mod
    offset = chunk_end
  }
}

///|
pub impl Hasher for Adler32 with checksum(self) -> UInt {
  (self.s2 << 16) | self.s1
}
