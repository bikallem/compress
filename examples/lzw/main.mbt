///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for i = 0; i < n; i = i + 1 {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
fn run() -> Unit raise {
  let original = repeat_bytes(b"ABABABABABABABABABAB", 50)

  // --- LSB order (GIF format) ---
  let compressed_lsb = @lzwlib.compress_bytes(original, LSB)
  let restored_lsb = @lzwlib.decompress_bytes(compressed_lsb, LSB)
  assert_eq(restored_lsb, original)
  println("LZW LSB: \{original.length()} -> \{compressed_lsb.length()} bytes")

  // --- MSB order (TIFF/PDF format) ---
  let compressed_msb = @lzwlib.compress_bytes(original, MSB)
  let restored_msb = @lzwlib.decompress_bytes(compressed_msb, MSB)
  assert_eq(restored_msb, original)
  println("LZW MSB: \{original.length()} -> \{compressed_msb.length()} bytes")

  // --- Different literal widths ---
  let small = repeat_bytes(b"\x00\x01\x02\x03", 200)
  let compressed_2 = @lzwlib.compress_bytes(small, LSB, lit_width=2)
  let restored_2 = @lzwlib.decompress_bytes(compressed_2, LSB, lit_width=2)
  assert_eq(restored_2, small)
  println("LZW litWidth=2: \{small.length()} -> \{compressed_2.length()} bytes")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
