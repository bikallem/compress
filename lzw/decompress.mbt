///|
/// Decompresses LZW-encoded data.
/// `order` specifies the bit packing order (LSB for GIF, MSB for TIFF/PDF).
/// `lit_width` is the literal code width in bits (typically 8, range [2, 8]).
pub fn decompress(
  data : Bytes,
  order : BitOrder,
  lit_width : Int,
) -> Bytes raise LzwError {
  let inf = Inflater::new(order, lit_width)
  inf.src(data[:])
  let capacity = (data.length() * 4).max(32768)
  inf.enable_direct_output(capacity)
  loop inf.decode() {
    Await => raise LzwError::UnexpectedEOF
    Data(_) => continue inf.decode()
    End => inf.take_output()
    Error(e) => raise e
  }
}
