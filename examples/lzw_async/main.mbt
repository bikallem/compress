///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for i = 0; i < n; i = i + 1 {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

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
    let original = repeat_bytes(b"LZW async streaming data. ", 500)

    @moonasync.with_task_group(root => {
      // --- Compress via LzwWriter ---
      let (pipe_read, pipe_write) = @io.pipe()
      let writer = @lzwlib.LzwWriter::new(pipe_write, LSB, 8)
      root.spawn_bg(() => {
        write_all(writer, original)
        writer.close()
        pipe_write.close()
      })
      let compressed = read_all_bytes(pipe_read)
      println(
        "LZW compressed: \{original.length()} -> \{compressed.length()} bytes",
      )

      // --- Decompress: streaming decompress_to ---
      let (pipe_read2, pipe_write2) = @io.pipe()
      let (pipe_read3, pipe_write3) = @io.pipe()
      root.spawn_bg(() => {
        write_all(pipe_write2, compressed)
        pipe_write2.close()
      })
      root.spawn_bg(() => {
        @lzwlib.decompress_to(pipe_read2, pipe_write3, LSB, 8)
        pipe_write3.close()
      })
      let restored = read_all_bytes(pipe_read3)
      assert_eq(restored, original)
      println("LZW async round-trip: OK (\{restored.length()} bytes)")
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
