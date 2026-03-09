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

    // --- Streaming compress via pipe ---
    let (compress_src_r, compress_src_w) = @io.pipe()
    let (compress_dst_r, compress_dst_w) = @io.pipe()
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        compress_src_w.write(original)
        compress_src_w.close()
      })
      root.spawn_bg(() => {
        @lzwlib.compress(compress_src_r, compress_dst_w, LSB)
        compress_dst_w.close()
      })
      let compressed = compress_dst_r.read_all().binary()
      println(
        "Async LZW compress: \{original.length()} -> \{compressed.length()} bytes",
      )

      // --- Streaming decompress via pipe ---
      let (decompress_src_r, decompress_src_w) = @io.pipe()
      let (decompress_dst_r, decompress_dst_w) = @io.pipe()
      root.spawn_bg(() => {
        decompress_src_w.write(compressed)
        decompress_src_w.close()
      })
      root.spawn_bg(() => {
        @lzwlib.decompress(decompress_src_r, decompress_dst_w, LSB)
        decompress_dst_w.close()
      })
      let restored = decompress_dst_r.read_all().binary()
      assert_eq(restored, original)
      println(
        "Async LZW decompress: round-trip OK (\{restored.length()} bytes)",
      )
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
