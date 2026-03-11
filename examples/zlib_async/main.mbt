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
    let original = repeat_bytes(b"zlib async framing example. ", 200)

    // Compress in one async task, decompress in another
    let (pipe_read, pipe_write) = @io.pipe()
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        let compressed = @zliblib.compress(original)
        pipe_write.write(compressed)
        pipe_write.close()
      })
      let compressed = pipe_read.read_all().binary()
      println(
        "Async zlib compress: \{original.length()} -> \{compressed.length()} bytes",
      )
      let restored = @zliblib.decompress(compressed)
      assert_eq(restored, original)
      println(
        "Async zlib decompress: round-trip OK (\{restored.length()} bytes)",
      )
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
