///|
/// IEEE polynomial used by ethernet, gzip, PNG, etc.
let ieee_poly : UInt = 0xEDB88320

///|
/// Precomputed CRC-32 table for the IEEE polynomial.
let crc32_table : FixedArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc : UInt = i.reinterpret_as_uint()
    for _ in 0..<8 {
      if (crc & 1U) == 1U {
        crc = (crc >> 1) ^ ieee_poly
      } else {
        crc = crc >> 1
      }
    }
    t[i] = crc
  }
  t
}

///|
/// Computes CRC-32 (IEEE) checksum of the given bytes in one shot.
pub fn crc32(data : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFF_U
  for i in 0..<data.length() {
    let index = (crc ^ data[i].to_uint()) & 0xFF_U
    crc = crc32_table[index.reinterpret_as_int()] ^ (crc >> 8)
  }
  crc ^ 0xFFFFFFFF_U
}

///|
/// CRC32 is an incremental CRC-32 (IEEE) hasher.
struct CRC32 {
  mut crc : UInt
}

///|
/// Creates a new CRC-32 hasher.
pub fn CRC32::new() -> CRC32 {
  { crc: 0xFFFFFFFF_U }
}

///|
pub impl Hasher for CRC32 with size(_self) -> Int {
  4
}

///|
pub impl Hasher for CRC32 with reset(self) -> Unit {
  self.crc = 0xFFFFFFFF_U
}

///|
pub impl Hasher for CRC32 with update(self, data) -> Unit {
  for i in 0..<data.length() {
    let index = (self.crc ^ data[i].to_uint()) & 0xFF_U
    self.crc = crc32_table[index.reinterpret_as_int()] ^ (self.crc >> 8)
  }
}

///|
pub impl Hasher for CRC32 with checksum(self) -> UInt {
  self.crc ^ 0xFFFFFFFF_U
}
