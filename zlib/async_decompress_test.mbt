///|
async fn read_all_bytes(reader : &@io.Reader) -> Bytes {
  reader.read_all().binary()
}

///|
async test "streaming zlib round-trip" {
  let original = b"Hello, streaming zlib world!"
  let compressed = @zlib.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      @zlib.decompress_to(pipe_read, out_write)
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}

///|
async test "streaming zlib large data" {
  let original = Bytes::makei(50000, fn(i) { (i % 256).to_byte() })
  let compressed = @zlib.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      @zlib.decompress_to(pipe_read, out_write)
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}
