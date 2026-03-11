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
  let original = repeat_bytes(b"gzip async example data. ", 200)

  // Compress in one async task, decompress in another
  let (pipe_read, pipe_write) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      let compressed = @gz.compress(original)
      pipe_write.write(compressed)
      pipe_write.close()
    })
    let compressed = pipe_read.read_all().binary()
    println(
      "Async gzip compress: \{original.length()} -> \{compressed.length()} bytes",
    )
    let (restored, header) = @gz.decompress(compressed)
    assert_eq(restored, original)
    println("Async gzip decompress: round-trip OK (\{restored.length()} bytes)")
    println("Header name: \"\{header.name}\"")
  })
}
