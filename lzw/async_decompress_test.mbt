///|
async fn read_all_bytes(reader : &@io.Reader) -> Bytes {
  reader.read_all().binary()
}

///|
async test "streaming lzw LSB round-trip" {
  let original = b"Hello, streaming LZW world!"
  let compressed = @lzw.compress(original, @lzw.LSB, 8)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      @lzw.decompress_to(pipe_read, out_write, @lzw.LSB, 8)
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}

///|
async test "streaming lzw MSB round-trip" {
  let original = b"Hello, streaming LZW MSB!"
  let compressed = @lzw.compress(original, @lzw.MSB, 8)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let (out_read, out_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    root.spawn_bg(() => {
      defer out_write.close()
      @lzw.decompress_to(pipe_read, out_write, @lzw.MSB, 8)
    })
    let result = read_all_bytes(out_read)
    assert_eq(result, original)
  })
}
