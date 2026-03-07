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
    let original = repeat_bytes(b"gzip async example data. ", 200)

    // --- Compress: pipe_async with GzipStreamWriter filter ---
    let (compressed_read, compressed_write) = @io.pipe()
    let (source_read, source_write) = @io.pipe()
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        source_write.write(original)
        source_write.close()
      })
      root.spawn_bg(() => {
        @sa.pipe_async(source_read, compressed_write, fn(sink) {
          @gz.GzipStreamWriter::new(sink)
        })
        compressed_write.close()
      })
      let compressed = compressed_read.read_all().binary()
      println(
        "Async gzip compress: \{original.length()} -> \{compressed.length()} bytes",
      )

      // --- Decompress: reader_of_io + GzipReader ---
      let (pipe_read, pipe_write) = @io.pipe()
      root.spawn_bg(() => {
        pipe_write.write(compressed)
        pipe_write.close()
      })
      let stream_reader = @sa.reader_of_io(pipe_read)
      let gz_reader = @gz.GzipReader::new(stream_reader)
      let restored = @stream.read_all(gz_reader)
      assert_eq(restored, original)
      println(
        "Async gzip decompress: round-trip OK (\{restored.length()} bytes)",
      )
      println("Header name: \"\{gz_reader.header().name}\"")
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
