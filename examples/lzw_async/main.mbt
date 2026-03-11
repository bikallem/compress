///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for _ in 0..<n {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
async fn main {
  let original = repeat_bytes(b"ABABABABABABABABABAB", 50)

  // Async LZW compress
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      let compressed = @lzwlib.compress(original, LSB, 8)
      println(
        "Async LZW compress: \{original.length()} -> \{compressed.length()} bytes",
      )
      let restored = @lzwlib.decompress(compressed, LSB, 8)
      assert_eq(restored, original)
      println(
        "Async LZW decompress: round-trip OK (\{restored.length()} bytes)",
      )
    })
  })
}
