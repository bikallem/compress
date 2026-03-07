///|
/// Returns true if hardware-accelerated CRC-32 (PCLMULQDQ) is available.
pub fn has_hw_crc32() -> Bool {
  checksum_has_hw_crc32() != 0
}

///|
/// Returns true if hardware-accelerated Adler-32 (SSSE3) is available.
pub fn has_hw_adler32() -> Bool {
  checksum_has_hw_adler32() != 0
}

///|
extern "c" fn checksum_has_hw_crc32() -> Int = "moonbit_checksum_has_hw_crc32"

///|
extern "c" fn checksum_has_hw_adler32() -> Int = "moonbit_checksum_has_hw_adler32"

///|
#borrow(data)
extern "c" fn crc32_hw_ffi(
  crc : UInt,
  data : Bytes,
  offset : Int,
  len : Int,
) -> UInt = "moonbit_crc32_hw"

///|
#borrow(data)
extern "c" fn adler32_hw_ffi(
  adler : UInt,
  data : Bytes,
  offset : Int,
  len : Int,
) -> UInt = "moonbit_adler32_hw"

///|
/// Native CRC-32 dispatch: CLMUL acceleration for data >= 64 bytes.
/// The C function takes a running CRC state and returns the running state.
/// We pass 0xFFFFFFFF (standard init) and finalize with XOR 0xFFFFFFFF.
fn crc32_try_hw(data : BytesView) -> UInt? {
  if data.length() >= 64 && has_hw_crc32() {
    let result = crc32_hw_ffi(
      0xFFFFFFFF_U,
      data.data(),
      data.start_offset(),
      data.length(),
    )
    Some(result ^ 0xFFFFFFFF_U)
  } else {
    None
  }
}

///|
/// Native Adler-32 dispatch: try hardware acceleration.
fn adler32_try_hw(data : BytesView) -> UInt? {
  if data.length() >= 32 && has_hw_adler32() {
    Some(adler32_hw_ffi(1U, data.data(), data.start_offset(), data.length()))
  } else {
    None
  }
}
