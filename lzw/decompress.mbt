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
  inf.src(data)
  let buf = @buffer.new(size_hint=data.length() * 4)
  loop inf.decode() {
    Await => raise LzwError::UnexpectedEOF
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue inf.decode()
    }
    End => buf.to_bytes()
    Error(e) => raise e
  }
}
