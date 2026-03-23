///|
/// IEEE polynomial used by ethernet, gzip, PNG, etc.
const IEEE_POLY : UInt = 0xEDB88320

///|
/// Precomputed slicing-by-8 CRC-32 tables for the IEEE polynomial.
/// Table 0 is the standard byte-at-a-time table.
/// Tables 1-7 enable processing 8 bytes at a time.
let crc32_tables : FixedArray[FixedArray[UInt]] = {
  let tables = FixedArray::make(8, FixedArray::make(0, 0U))
  // Build table 0 (standard)
  let t0 = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc : UInt = i.reinterpret_as_uint()
    for _ in 0..<8 {
      if (crc & 1U) == 1U {
        crc = (crc >> 1) ^ IEEE_POLY
      } else {
        crc = crc >> 1
      }
    }
    t0.unsafe_set(i, crc)
  }
  tables.unsafe_set(0, t0)
  // Build tables 1-7 for slicing-by-8
  for k in 1..<8 {
    let tk = FixedArray::make(256, 0U)
    for i in 0..<256 {
      tk.unsafe_set(
        i,
        (tables.unsafe_get(k - 1).unsafe_get(i) >> 8) ^
        t0[(tables.unsafe_get(k - 1).unsafe_get(i) & 0xFFU).reinterpret_as_int()],
      )
    }
    tables.unsafe_set(k, tk)
  }
  tables
}

///|
/// Computes CRC-32 (IEEE) checksum of the given bytes in one shot.
/// Uses hardware CLMUL acceleration when available, software slicing-by-8 otherwise.
pub fn crc32(data : BytesView) -> UInt {
  if crc32_try_hw(data) is Some(result) {
    return result
  }
  let h = CRC32::new()
  h.update(data)
  h.checksum()
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
  let len = data.length()
  let mut i = 0
  let t0 = crc32_tables.unsafe_get(0)
  let t1 = crc32_tables.unsafe_get(1)
  let t2 = crc32_tables.unsafe_get(2)
  let t3 = crc32_tables.unsafe_get(3)
  let t4 = crc32_tables.unsafe_get(4)
  let t5 = crc32_tables.unsafe_get(5)
  let t6 = crc32_tables.unsafe_get(6)
  let t7 = crc32_tables.unsafe_get(7)
  while i + 8 <= len {
    let b0 = data.unsafe_get(i).to_uint()
    let b1 = data.unsafe_get(i + 1).to_uint()
    let b2 = data.unsafe_get(i + 2).to_uint()
    let b3 = data.unsafe_get(i + 3).to_uint()
    let b4 = data.unsafe_get(i + 4).to_uint()
    let b5 = data.unsafe_get(i + 5).to_uint()
    let b6 = data.unsafe_get(i + 6).to_uint()
    let b7 = data.unsafe_get(i + 7).to_uint()
    let p0 = (self.crc ^ b0) & 0xFFU
    let p1 = ((self.crc >> 8) ^ b1) & 0xFFU
    let p2 = ((self.crc >> 16) ^ b2) & 0xFFU
    let p3 = ((self.crc >> 24) ^ b3) & 0xFFU
    // Safety: all indices are byte values (0-255), tables are 256 entries
    self.crc = t7.unsafe_get(p0.reinterpret_as_int()) ^
      t6.unsafe_get(p1.reinterpret_as_int()) ^
      t5.unsafe_get(p2.reinterpret_as_int()) ^
      t4.unsafe_get(p3.reinterpret_as_int()) ^
      t3.unsafe_get(b4.reinterpret_as_int()) ^
      t2.unsafe_get(b5.reinterpret_as_int()) ^
      t1.unsafe_get(b6.reinterpret_as_int()) ^
      t0.unsafe_get(b7.reinterpret_as_int())
    i += 8
  }
  while i < len {
    let index = (self.crc ^ data.unsafe_get(i).to_uint()) & 0xFF_U
    self.crc = t0.unsafe_get(index.reinterpret_as_int()) ^ (self.crc >> 8)
    i += 1
  }
}

///|
pub impl Hasher for CRC32 with checksum(self) -> UInt {
  self.crc ^ 0xFFFFFFFF_U
}
