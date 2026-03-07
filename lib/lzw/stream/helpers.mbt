///|
async fn extract_data_bytes(data : &@io.Data) -> Bytes {
  let buf = @buffer.new()
  let (r, w) = @io.pipe()
  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      defer w.close()
      w.write(data)
    })
    while true {
      let chunk = r.read_some()
      guard chunk is Some(bytes) else { break }
      for i in 0..<bytes.length() {
        buf.write_byte(bytes[i])
      }
    }
  })
  buf.to_bytes()
}
