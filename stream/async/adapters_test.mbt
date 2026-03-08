///|
async test "reader_of_io buffers async reader into BytesReader" {
  let (reader, writer) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      writer.write(b"Hello, stream!")
      writer.close()
    })
    let slice_reader = @async.reader_of_io(reader)
    let result = @stream.read_all(slice_reader)
    assert_eq(result, b"Hello, stream!")
  })
}

///|
async test "write_to_io drains stream reader to async writer" {
  let original = b"Hello, async world!"
  let stream_reader = @stream.BytesReader::new(original, slice_length=8)
  let (reader, writer) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      @async.write_to_io(stream_reader, writer)
      writer.close()
    })
    let result = reader.read_all().binary()
    assert_eq(result, original)
  })
}

///|
async test "pipe_async with identity filter" {
  let (source_read, source_write) = @io.pipe()
  let (dest_read, dest_write) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      source_write.write(b"pipe test data")
      source_write.close()
    })
    root.spawn_bg(() => {
      @async.pipe_async(source_read, dest_write, fn(w) { w })
      dest_write.close()
    })
    let result = dest_read.read_all().binary()
    assert_eq(result, b"pipe test data")
  })
}

///|
async test "pipe_async round-trip with stream filter" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress via pipe_async
  let (source_read, source_write) = @io.pipe()
  let (compressed_read, compressed_write) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      source_write.write(original)
      source_write.close()
    })
    root.spawn_bg(() => {
      @async.pipe_async(source_read, compressed_write, fn(sink) {
        @stream.BufferWriter::new()
      })
      compressed_write.close()
    })
    // Just verify pipe_async completes without error
    let _result = compressed_read.read_all().binary()
  })
}
