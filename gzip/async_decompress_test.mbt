///|
async fn read_all_bytes(reader : &@io.Reader) -> Bytes {
  reader.read_all().binary()
}

///|
async test "streaming gzip round-trip" {
  let original = b"Hello, streaming gzip world!"
  let compressed = @gzip.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      ignore(@gzip.decompress_to(pipe_read, out_write))
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}

///|
async test "streaming gzip large data" {
  let original = Bytes::makei(50000, fn(i) { (i % 256).to_byte() })
  let compressed = @gzip.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      ignore(@gzip.decompress_to(pipe_read, out_write))
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}

///|
async test "streaming gzip with header" {
  let original = Bytes::makei(15000, fn(i) { (i % 251).to_byte() })
  let hdr : @gzip.Header = {
    name: "data.txt",
    comment: "",
    extra: b"",
    mod_time: 0U,
    os: b'\xff',
  }
  let compressed = @gzip.compress(original, header=hdr)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      let header = @gzip.decompress_to(pipe_read, out_write)
      inspect(header.name, content="data.txt")
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}
