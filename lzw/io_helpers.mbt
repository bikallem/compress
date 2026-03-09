///|
fn validate_lit_width(lit_width : Int) -> Unit raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
}

///|
async fn read_one_byte(
  src : &@io.Reader,
  scratch : FixedArray[Byte],
) -> Byte? raise LzwError {
  let n = src.read(scratch, offset=0, max_len=1) catch {
    e => raise LzwError::Io(e.to_string())
  }
  if n == 0 {
    None
  } else {
    Some(scratch[0])
  }
}

///|
async fn write_one_byte(
  dst : &@io.Writer,
  scratch : FixedArray[Byte],
  byte : Byte,
) -> Unit raise LzwError {
  scratch[0] = byte
  dst.write(scratch.unsafe_reinterpret_as_bytes()) catch {
    e => raise LzwError::Io(e.to_string())
  }
}
