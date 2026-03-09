///|
/// Fast byte-level blit using libc memmove (vectorized).
/// FixedArray[Byte] has the same memory layout as Bytes in native backend.
#borrow(dst, src)
pub extern "c" fn blit_fixed_array(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : FixedArray[Byte],
  src_offset : Int,
  length : Int,
) -> Unit = "bikallem_compress_internal_blit_blit_fixed_array"

///|
#borrow(dst, src)
pub extern "c" fn blit_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : Bytes,
  src_offset : Int,
  length : Int,
) -> Unit = "bikallem_compress_internal_blit_blit_fixed_array"

///|
/// Fill a byte array region with a single byte value (vectorized memset).
#borrow(dst)
pub extern "c" fn fill_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int,
  value : Int,
  length : Int,
) -> Unit = "bikallem_compress_internal_blit_fill_bytes"

///|
/// Allocate a FixedArray[Byte] without zeroing memory.
/// The caller MUST fully initialize the buffer before reading from it.
pub extern "c" fn make_uninit(len : Int) -> FixedArray[Byte] = "bikallem_compress_internal_blit_make_uninit"
