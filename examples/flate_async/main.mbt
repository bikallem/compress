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
    let original = repeat_bytes(
      b"The quick brown fox jumps over the lazy dog. ", 100,
    )

    // --- Compress: pipe_async with DeflateWriter filter ---
    let (compressed_read, compressed_write) = @io.pipe()
    let (source_read, source_write) = @io.pipe()
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        source_write.write(original)
        source_write.close()
      })
      root.spawn_bg(() => {
        @sa.pipe_async(source_read, compressed_write, fn(sink) {
          @deflate.DeflateWriter::new(sink)
        })
        compressed_write.close()
      })
      let compressed = compressed_read.read_all().binary()
      println(
        "Async compress: \{original.length()} -> \{compressed.length()} bytes",
      )

      // --- Decompress: reader_of_io + InflateReader ---
      let (pipe_read, pipe_write) = @io.pipe()
      root.spawn_bg(() => {
        pipe_write.write(compressed)
        pipe_write.close()
      })
      let stream_reader = @sa.reader_of_io(pipe_read)
      let inflater = @deflate.InflateReader::new(stream_reader)
      let restored = @stream.read_all(inflater)
      assert_eq(restored, original)
      println("Async decompress: round-trip OK (\{restored.length()} bytes)")
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
