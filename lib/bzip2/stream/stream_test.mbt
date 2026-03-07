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
let bzip2_hello : Bytes = [
  0x42, 0x5A, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x1A, 0x54, 0x64, 0x92,
  0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x40, 0x02, 0x04, 0xA0, 0x00, 0x21, 0x9A, 0x68,
  0x33, 0x4D, 0x13, 0x33, 0x8B, 0xB9, 0x22, 0x9C, 0x28, 0x48, 0x0D, 0x2A, 0x32, 0x49,
  0x00,
]

///|
async test "bzip2_reader decompress" {
  @async.with_task_group(root => {
    let (pipe_read, pipe_write) = @io.pipe()
    root.spawn_bg(() => {
      defer pipe_write.close()
      pipe_write.write(bzip2_hello)
    })
    let reader = @stream.Bzip2Reader::new(pipe_read)
    let result = read_all_bytes(reader)
    assert_eq(result, b"Hello")
  })
}
