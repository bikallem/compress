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

///|
#cfg(target="native")
fn main {
  @moonasync.run_async_main(async fn() {
    let original = repeat_bytes(b"LZW async streaming data. ", 500)

    @moonasync.with_task_group(root => {
      // --- Compress via LzwWriter ---
      let (pipe_read, pipe_write) = @io.pipe()
      let writer = @lzw_async.LzwWriter::new(pipe_write, LSB, 8)
      root.spawn_bg(() => {
        ignore(writer.write_once(original, offset=0, len=original.length()))
        writer.close()
        pipe_write.close()
      })
      let compressed = read_all_bytes(pipe_read)
      println(
        "LZW compressed: \{original.length()} -> \{compressed.length()} bytes",
      )

      // --- Decompress via LzwReader ---
      let (pipe_read2, pipe_write2) = @io.pipe()
      let reader = @lzw_async.LzwReader::new(pipe_read2, LSB, 8)
      root.spawn_bg(() => {
        ignore(
          pipe_write2.write_once(compressed, offset=0, len=compressed.length()),
        )
        pipe_write2.close()
      })
      let restored = read_all_bytes(reader)
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
