///|
/// IEEE polynomial used by ethernet, gzip, PNG, etc.
const IEEE_POLY : UInt = 0xEDB88320

///|
/// Precomputed slicing-by-8 CRC-32 tables for the IEEE polynomial.
/// Table 0 is the standard byte-at-a-time table.
/// Tables 1-7 enable processing 8 bytes at a time.
let crc32_tables : ReadOnlyArray[ReadOnlyArray[UInt]] = {
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
    t0[i] = crc
  }
  tables[0] = t0
  // Build tables 1-7 for slicing-by-8
  for k in 1..<8 {
    let tk = FixedArray::make(256, 0U)
    for i in 0..<256 {
      tk[i] = (tables[k - 1][i] >> 8) ^
        t0[(tables[k - 1][i] & 0xFFU).reinterpret_as_int()]
    }
    tables[k] = tk
  }
  // Convert to ReadOnlyArray
  let ro = FixedArray::makei(8, fn(i) {
    ReadOnlyArray::from_array(tables[i][:])
  })
  ReadOnlyArray::from_array(ro[:])
}

///|
/// Computes CRC-32 (IEEE) checksum of the given bytes in one shot.
/// Uses slicing-by-8 for inputs >= 8 bytes.
pub fn crc32(data : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFF_U
  let len = data.length()
  let mut i = 0
  // Process 8 bytes at a time
  let t0 = crc32_tables[0]
  let t1 = crc32_tables[1]
  let t2 = crc32_tables[2]
  let t3 = crc32_tables[3]
  let t4 = crc32_tables[4]
  let t5 = crc32_tables[5]
  let t6 = crc32_tables[6]
  let t7 = crc32_tables[7]
  while i + 8 <= len {
    let b0 = data[i].to_uint()
    let b1 = data[i + 1].to_uint()
    let b2 = data[i + 2].to_uint()
    let b3 = data[i + 3].to_uint()
    let b4 = data[i + 4].to_uint()
    let b5 = data[i + 5].to_uint()
    let b6 = data[i + 6].to_uint()
    let b7 = data[i + 7].to_uint()
    // XOR first 4 bytes with current CRC
    let p0 = (crc ^ b0) & 0xFFU
    let p1 = ((crc >> 8) ^ b1) & 0xFFU
    let p2 = ((crc >> 16) ^ b2) & 0xFFU
    let p3 = ((crc >> 24) ^ b3) & 0xFFU
    crc = t7[p0.reinterpret_as_int()] ^
      t6[p1.reinterpret_as_int()] ^
      t5[p2.reinterpret_as_int()] ^
      t4[p3.reinterpret_as_int()] ^
      t3[b4.reinterpret_as_int()] ^
      t2[b5.reinterpret_as_int()] ^
      t1[b6.reinterpret_as_int()] ^
      t0[b7.reinterpret_as_int()]
    i += 8
  }
  // Process remaining bytes one at a time
  while i < len {
    let index = (crc ^ data[i].to_uint()) & 0xFF_U
    crc = t0[index.reinterpret_as_int()] ^ (crc >> 8)
    i += 1
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
  let len = data.length()
  let mut i = 0
  let t0 = crc32_tables[0]
  let t1 = crc32_tables[1]
  let t2 = crc32_tables[2]
  let t3 = crc32_tables[3]
  let t4 = crc32_tables[4]
  let t5 = crc32_tables[5]
  let t6 = crc32_tables[6]
  let t7 = crc32_tables[7]
  while i + 8 <= len {
    let b0 = data[i].to_uint()
    let b1 = data[i + 1].to_uint()
    let b2 = data[i + 2].to_uint()
    let b3 = data[i + 3].to_uint()
    let b4 = data[i + 4].to_uint()
    let b5 = data[i + 5].to_uint()
    let b6 = data[i + 6].to_uint()
    let b7 = data[i + 7].to_uint()
    let p0 = (self.crc ^ b0) & 0xFFU
    let p1 = ((self.crc >> 8) ^ b1) & 0xFFU
    let p2 = ((self.crc >> 16) ^ b2) & 0xFFU
    let p3 = ((self.crc >> 24) ^ b3) & 0xFFU
    self.crc = t7[p0.reinterpret_as_int()] ^
      t6[p1.reinterpret_as_int()] ^
      t5[p2.reinterpret_as_int()] ^
      t4[p3.reinterpret_as_int()] ^
      t3[b4.reinterpret_as_int()] ^
      t2[b5.reinterpret_as_int()] ^
      t1[b6.reinterpret_as_int()] ^
      t0[b7.reinterpret_as_int()]
    i += 8
  }
  while i < len {
    let index = (self.crc ^ data[i].to_uint()) & 0xFF_U
    self.crc = t0[index.reinterpret_as_int()] ^ (self.crc >> 8)
    i += 1
  }
}

///|
pub impl Hasher for CRC32 with checksum(self) -> UInt {
  self.crc ^ 0xFFFFFFFF_U
}
