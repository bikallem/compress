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
async test "zlib_reader round-trip" {
  let original = b"Hello, async zlib world!"
  let compressed = @zlib.compress(original)
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(compressed)
    })
    let reader = @async.ZlibReader::new(pipe_read)
    let result = read_all_bytes(reader)
    assert_eq(result, original)
  })
}

///|
async test "zlib_writer round-trip" {
  let original = b"Hello, async zlib writer!"
  @moonasync.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    let writer = @async.ZlibWriter::new(pipe_write)
    root.spawn_bg(() => {
      ignore(writer.write_once(original, offset=0, len=original.length()))
      writer.close()
      pipe_write.close()
    })
    let compressed = read_all_bytes(pipe_read)
    let decompressed = @zlib.decompress(compressed)
    assert_eq(decompressed, original)
  })
}

///|
async test "zlib_writer/zlib_reader pipeline" {
  let original = b"The quick brown fox jumps over the lazy dog."
  @moonasync.with_task_group(root => {
    let (mid_read, mid_write) = @io.pipe()
    let writer = @async.ZlibWriter::new(mid_write)
    root.spawn_bg(() => {
      ignore(writer.write_once(original, offset=0, len=original.length()))
      writer.close()
      mid_write.close()
    })
    let reader = @async.ZlibReader::new(mid_read)
    let result = read_all_bytes(reader)
    assert_eq(result, original)
  })
}
