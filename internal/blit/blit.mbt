///|
fn BytesView::bytes(self : BytesView) -> Bytes = "%bytesview.bytes"

///|
pub fn blit_bytesview(
  dst : FixedArray[Byte],
  dst_offset : Int,
  src : BytesView,
  src_offset : Int,
  length : Int,
) -> Unit {
  blit_bytes(dst, dst_offset, src.bytes(), src_offset, length)
}
