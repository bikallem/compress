///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for _ in 0..<n {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
#cfg(target="native")
fn main {
  @moonasync.run_async_main(async fn() {
    let original = repeat_bytes(b"ABABABABABABABABABAB", 50)

    // --- Streaming compress via @lzwio Reader/Writer ---
    let src = @lzwio.BytesReader::new(original)
    let compressed_dst = @lzwio.BytesWriter::new()
    @lzwlib.compress(src, compressed_dst, LSB)
    let compressed = compressed_dst.content()
    println(
      "Async LZW compress: \{original.length()} -> \{compressed.length()} bytes",
    )

    // --- Streaming decompress ---
    let src2 = @lzwio.BytesReader::new(compressed)
    let decompressed_dst = @lzwio.BytesWriter::new()
    @lzwlib.decompress(src2, decompressed_dst, LSB)
    let restored = decompressed_dst.content()
    assert_eq(restored, original)
    println("Async LZW decompress: round-trip OK (\{restored.length()} bytes)")
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
