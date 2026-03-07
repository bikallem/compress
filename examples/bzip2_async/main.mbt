///|
async fn read_all_bytes(reader : &@io.Reader) -> Bytes {
  let buf = @buffer.new()
  while true {
    let chunk = reader.read_some()
    guard chunk is Some(bytes) else { break }
    for i in 0..<bytes.length() {
      buf.write_byte(bytes[i])
    }
  }
  buf.to_bytes()
}

///|

///|
#cfg(target="native")
fn main {
  @moonasync.run_async_main(async fn() {
    // bzip2-compressed "Hello"
    let compressed : Bytes = [
      0x42, 0x5A, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x1A, 0x54, 0x64,
      0x92, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x40, 0x02, 0x04, 0xA0, 0x00, 0x21,
      0x9A, 0x68, 0x33, 0x4D, 0x13, 0x33, 0x8B, 0xB9, 0x22, 0x9C, 0x28, 0x48, 0x0D,
      0x2A, 0x32, 0x49, 0x00,
    ]

    @moonasync.with_task_group(root => {
      // --- Decompress through Bzip2Reader ---
      let (pipe_read, pipe_write) = @io.pipe()
      let reader = @bzip2_async.Bzip2Reader::new(pipe_read)
      root.spawn_bg(() => {
        ignore(
          pipe_write.write_once(compressed, offset=0, len=compressed.length()),
        )
        pipe_write.close()
      })
      let restored = read_all_bytes(reader)
      assert_eq(restored, b"Hello")
      println("bzip2 async decompression: OK (\{restored.length()} bytes)")
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
