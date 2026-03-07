///|
async fn read_all_bytes(reader : &@io.Reader) -> Bytes {
  let buf = @buffer.new()
  while true {
    let chunk = reader.read_some()
    guard chunk is Some(data) else { break }
    for i in 0..<data.length() {
      buf.write_byte(data[i])
    }
  }
  buf.to_bytes()
}

///|
async test "lzw_reader round-trip" {
  let original = b"Hello, async LZW world!"
  let compressed = @lzw.compress(original, @lzw.LSB, 8)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    let reader = @async.LzwReader::new(pipe_read, @lzw.LSB, 8)
    let result = read_all_bytes(reader)
    assert_eq(result, original)
  })
}

///|
async test "lzw_writer round-trip" {
  let original = b"Hello, async LZW writer!"
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let writer = @async.LzwWriter::new(pipe_write, @lzw.LSB, 8)
    root.spawn_bg(() => {
      ignore(writer.write_once(original, offset=0, len=original.length()))
      writer.close()
      pipe_write.close()
    })
    let compressed = read_all_bytes(pipe_read)
    let decompressed = @lzw.decompress(compressed, @lzw.LSB, 8)
    assert_eq(decompressed, original)
  })
}

///|
async test "lzw_writer/lzw_reader pipeline" {
  let original = b"The quick brown fox jumps over the lazy dog."
  @moonasync.with_task_group(root => {
    let (mid_read, mid_write) = @io.pipe()
    let writer = @async.LzwWriter::new(mid_write, @lzw.MSB, 8)
    root.spawn_bg(() => {
      ignore(writer.write_once(original, offset=0, len=original.length()))
      writer.close()
      mid_write.close()
    })
    let reader = @async.LzwReader::new(mid_read, @lzw.MSB, 8)
    let result = read_all_bytes(reader)
    assert_eq(result, original)
  })
}
