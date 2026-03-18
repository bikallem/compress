///|
/// Copy `length` bytes between FixedArray[Byte] buffers.
/// Safe for overlapping regions within the same array.
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
/// Copy `length` bytes from `src` (Bytes) at `src_offset` into `dst` (FixedArray) at `dst_offset`.
pub fn blit_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : Bytes,
  src_offset : Int,
  length : Int,
) -> Unit {
  dst.blit_from_bytes(dst_offset, src, src_offset, length)
}

///|
/// Fill `length` bytes in `dst` starting at `dst_offset` with `value`.
pub fn fill_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  value : Byte,
  length : Int,
) -> Unit {
  for i in 0..<length {
    dst[dst_offset + i] = value
  }
}

///|
/// Word-at-a-time match length comparison (byte-by-byte fallback for non-native).
pub fn match_length(
  a : FixedArray[Byte],
  a_offset : Int,
  b : FixedArray[Byte],
  b_offset : Int,
  max_len : Int,
) -> Int {
  let mut i = 0
  while i < max_len && a[a_offset + i] == b[b_offset + i] {
    i += 1
  }
  i
}

///|
/// Word-at-a-time match length comparison on Bytes (byte-by-byte fallback for non-native).
pub fn match_length_bytes(
  a : Bytes,
  a_offset : Int,
  b : Bytes,
  b_offset : Int,
  max_len : Int,
) -> Int {
  let mut i = 0
  while i < max_len && a[a_offset + i] == b[b_offset + i] {
    i += 1
  }
  i
}

///|
/// Allocate a FixedArray[Byte] without zeroing memory.
/// The caller MUST fully initialize the buffer before reading from it.
pub fn make_uninit(len : Int) -> FixedArray[Byte] {
  FixedArray::make(len, b'\x00')
}
