///|
/// Copy `length` bytes from `src` (BytesView) at `src_offset` into `dst` (FixedArray) at `dst_offset`.
/// Note: `src_offset` is relative to the underlying Bytes, not the view's start.
pub fn blit_bytesview(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : BytesView,
  src_offset : Int,
  length : Int,
) -> Unit {
  blit_bytes(dst, dst_offset, src.data(), src_offset, length)
}

///|
/// Word-at-a-time match length comparison on BytesView.
/// Returns the number of matching bytes between src[a..] and src[b..], up to max_len.
pub fn match_length_bv(src : BytesView, a : Int, b : Int, max_len : Int) -> Int {
  match_length_bytes(src.data(), a, src.data(), b, max_len)
}
