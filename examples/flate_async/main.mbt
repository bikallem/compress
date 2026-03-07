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
    let original = repeat_bytes(b"Streaming compression example data. ", 500)

    // --- Compress: write through DeflateWriter to a pipe ---
    let (pipe_read, pipe_write) = @io.pipe()
    let writer = @flate_async.DeflateWriter::new(
      pipe_write,
      level=DefaultCompression,
    )
    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        ignore(writer.write_once(original, offset=0, len=original.length()))
        writer.close()
        pipe_write.close()
      })
      let compressed = read_all_bytes(pipe_read)
      println(
        "Compressed: \{original.length()} -> \{compressed.length()} bytes",
      )

      // --- Decompress: read through InflateReader from a pipe ---
      let (pipe_read2, pipe_write2) = @io.pipe()
      let reader = @flate_async.InflateReader::new(pipe_read2)
      root.spawn_bg(() => {
        ignore(
          pipe_write2.write_once(compressed, offset=0, len=compressed.length()),
        )
        pipe_write2.close()
      })
      let restored = read_all_bytes(reader)
      assert_eq(restored, original)
      println("Round-trip: OK (\{restored.length()} bytes)")
    })
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This example requires --target native")
}
