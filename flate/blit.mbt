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

///|
/// Fill a byte array region with a single byte value (vectorized memset).
#borrow(dst)
extern "c" fn fill_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  value : Int,
  length : Int,
) -> Unit = "bikallem_compress_flate_fill_bytes"
