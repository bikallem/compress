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
async fn write_all(w : &@io.Writer, data : Bytes) -> Unit {
  let mut offset = 0
  let len = data.length()
  while offset < len {
    let written = w.write_once(data, offset~, len=len - offset)
    offset += written
  }
}

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
      // --- Decompress: streaming decompress_to ---
      let (pipe_read, pipe_write) = @io.pipe()
      let (pipe_read2, pipe_write2) = @io.pipe()
      root.spawn_bg(() => {
        write_all(pipe_write, compressed)
        pipe_write.close()
      })
      root.spawn_bg(() => {
        @bz2.decompress_to(pipe_read, pipe_write2)
        pipe_write2.close()
      })
      let restored = read_all_bytes(pipe_read2)
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
