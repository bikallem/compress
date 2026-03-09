///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for i = 0; i < n; i = i + 1 {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
async fn run() -> Unit {
  let original = repeat_bytes(b"ABABABABABABABABABAB", 50)

  // --- LSB order (GIF format) ---
  let compressed_lsb = @lzwlib.compress_bytes(original, @lzwlib.LSB, 8)
  let restored_lsb = @lzwlib.decompress_bytes(compressed_lsb, @lzwlib.LSB, 8)
  assert_eq(restored_lsb, original)
  println("LZW LSB: \{original.length()} -> \{compressed_lsb.length()} bytes")

  // --- MSB order (TIFF/PDF format) ---
  let compressed_msb = @lzwlib.compress_bytes(original, @lzwlib.MSB, 8)
  let restored_msb = @lzwlib.decompress_bytes(compressed_msb, @lzwlib.MSB, 8)
  assert_eq(restored_msb, original)
  println("LZW MSB: \{original.length()} -> \{compressed_msb.length()} bytes")

  // --- Different literal widths ---
  let small = repeat_bytes(b"\x00\x01\x02\x03", 200)
  let compressed_2 = @lzwlib.compress_bytes(small, @lzwlib.LSB, 2)
  let restored_2 = @lzwlib.decompress_bytes(compressed_2, @lzwlib.LSB, 2)
  assert_eq(restored_2, small)
  println("LZW litWidth=2: \{small.length()} -> \{compressed_2.length()} bytes")

  // --- Streaming API ---
  let source = @ibytes.BytesReader::new(original)
  let compressed_dest = @ibytes.BytesWriter::new()
  @lzwlib.compress(source, compressed_dest, @lzwlib.LSB, 8)
  let stream_compressed = compressed_dest.content()
  let compressed_source = @ibytes.BytesReader::new(stream_compressed)
  let restored_dest = @ibytes.BytesWriter::new()
  @lzwlib.decompress(compressed_source, restored_dest, @lzwlib.LSB, 8)
  let stream_restored = restored_dest.content()
  assert_eq(stream_restored, original)
  println("Streaming: \{stream_compressed.length()} bytes, round-trip OK")
}

///|
fn main {
  @moonasync.run_async_main(async fn() {
    run() catch {
      e => println("Error: \{e}")
    }
  })
}
