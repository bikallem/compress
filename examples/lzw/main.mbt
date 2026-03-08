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
  let compressed_lsb = @lzwlib.compress(original, LSB, 8)
  let restored_lsb = @lzwlib.decompress(compressed_lsb, LSB, 8)
  assert_eq(restored_lsb, original)
  println("LZW LSB: \{original.length()} -> \{compressed_lsb.length()} bytes")

  // --- MSB order (TIFF/PDF format) ---
  let compressed_msb = @lzwlib.compress(original, MSB, 8)
  let restored_msb = @lzwlib.decompress(compressed_msb, MSB, 8)
  assert_eq(restored_msb, original)
  println("LZW MSB: \{original.length()} -> \{compressed_msb.length()} bytes")

  // --- Different literal widths ---
  let small = repeat_bytes(b"\x00\x01\x02\x03", 200)
  let compressed_2 = @lzwlib.compress(small, LSB, 2)
  let restored_2 = @lzwlib.decompress(compressed_2, LSB, 2)
  assert_eq(restored_2, small)
  println("LZW litWidth=2: \{small.length()} -> \{compressed_2.length()} bytes")

  // --- Streaming API ---
  let dest = @stream.BufferWriter::new()
  let lzw_writer = @lzwlib.LzwStreamWriter::new(dest, LSB, 8)
  @stream.pipe(@stream.BytesReader::new(original, slice_length=256), lzw_writer)
  let stream_compressed = dest.to_bytes()
  let reader = @lzwlib.LzwReader::new(
    @stream.BytesReader::new(stream_compressed),
    LSB,
    8,
  )
  let stream_restored = @stream.read_all(reader)
  assert_eq(stream_restored, original)
  println("Streaming: \{stream_compressed.length()} bytes, round-trip OK")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
