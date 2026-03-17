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
  let original = repeat_bytes(
    b"brotli async example with repeated repeated repeated text. ", 128,
  )

  let (pipe_read, pipe_write) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      let compressed = @br.compress(original, level=BestCompression)
      pipe_write.write(compressed)
      pipe_write.close()
    })
    let compressed = pipe_read.read_all().binary()
    println(
      "Async brotli compress: \{original.length()} -> \{compressed.length()} bytes",
    )
    let restored = @br.decompress(compressed)
    assert_eq(restored, original)
    println(
      "Async brotli decompress: round-trip OK (\{restored.length()} bytes)",
    )
  })
}
