///|
/// Fast byte-level blit using libc memmove (vectorized).
/// FixedArray[Byte] has the same memory layout as Bytes in native backend.
#borrow(dst, src)
extern "c" fn blit_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : FixedArray[Byte],
  src_offset : Int,
  length : Int,
) -> Unit = "bikallem_compress_flate_blit_bytes"
