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
) -> Unit = "bikallem_compress_lzw_blit_bytes"

///|
/// Allocate a FixedArray[Byte] without zeroing memory.
/// The caller MUST fully initialize the buffer before reading from it.
extern "c" fn make_uninit(len : Int) -> FixedArray[Byte] = "bikallem_compress_lzw_make_bytes_uninit"
