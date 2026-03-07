///|
async fn read_all_bytes(reader : &@io.Reader) -> Bytes {
  reader.read_all().binary()
}

///|
async test "streaming inflate round-trip" {
  let original = b"Hello, streaming DEFLATE world!"
  let compressed = @flate.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      ignore(@flate.decompress_to(pipe_read, out_write))
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}

///|
async test "streaming inflate large data" {
  let original = Bytes::makei(50000, fn(i) { (i % 256).to_byte() })
  let compressed = @flate.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      ignore(@flate.decompress_to(pipe_read, out_write))
    })
    let result = read_all_bytes(out_read)
    assert_eq(result.length(), original.length())
    assert_eq(result, original)
  })
}

///|
async test "streaming inflate highly compressible" {
  let original = Bytes::make(50000, b'A')
  let compressed = @flate.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      ignore(@flate.decompress_to(pipe_read, out_write))
    })
    let result = read_all_bytes(out_read)
    inspect(result.length(), content="50000")
    assert_eq(result, original)
  })
}
