///|
#cfg(target="native")
fn main {
  @moonasync.run_async_main(async fn() {
    let original = b"Hello, bzip2 async streaming!"
    let compressed = @bz2.compress(original)

    // --- Decompress: reader_of_io + Bzip2Reader ---
    let (pipe_read, pipe_write) = @io.pipe()
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        pipe_write.write(compressed)
        pipe_write.close()
      })
      let stream_reader = @sa.reader_of_io(pipe_read)
      let bz2_reader = @bz2.Bzip2Reader::new(stream_reader)
      let restored = @stream.read_all(bz2_reader)
      assert_eq(restored, original)
      println(
        "Async bzip2 decompress: round-trip OK (\{restored.length()} bytes)",
      )
    })

    // --- write_to_io: stream reader -> async writer ---
    let bz2_reader2 = @bz2.Bzip2Reader::new(
      @stream.SliceReader::new(compressed),
    )
    let (out_read, out_write) = @io.pipe()
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        @sa.write_to_io(bz2_reader2, out_write)
        out_write.close()
      })
      let result = out_read.read_all().binary()
      assert_eq(result, original)
      println("write_to_io: OK (\{result.length()} bytes)")
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
