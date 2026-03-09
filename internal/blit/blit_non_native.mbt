///|
pub fn blit_fixed_array(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : FixedArray[Byte],
  src_offset : Int,
  length : Int,
) -> Unit {
  FixedArray::unsafe_blit(dst, dst_offset, src, src_offset, length)
}

///|
pub fn fill_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  value : Int,
  length : Int,
) -> Unit {
  let byte_val = value.to_byte()
  for i in 0..<length {
    dst[dst_offset + i] = byte_val
  }
}

///|
pub fn make_uninit(len : Int) -> FixedArray[Byte] {
  FixedArray::make(len, b'\x00')
}
