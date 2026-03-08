///|
test "BytesWriter collects output" {
  let writer = @stream.BytesWriter::new()
  writer.write(b"hello"[:])
  writer.write(b" world"[:])
  writer.write(b""[:]) // eod
  let result = writer.content()
  assert_eq(result, b"hello world")
}

///|
test "pipe preserves data integrity for large stream" {
  let total = 1024 * 1024 // 1MB
  let mut gen_pos = 0
  let reader = @stream.FnReader::new(slice_length=8192, fn(buf) {
    if gen_pos >= total {
      return 0
    }
    let n = if total - gen_pos < buf.length() {
      total - gen_pos
    } else {
      buf.length()
    }
    for i in 0..<n {
      buf[i] = ((gen_pos + i) % 256).to_byte()
    }
    gen_pos += n
    n
  })
  // Pipe through CountedWriter to verify total bytes
  let inner = @stream.BytesWriter::new()
  let counted_w = @stream.CountedWriter::new(inner)
  @stream.pipe(reader, counted_w)
  inspect(counted_w.position(), content="1048576")
  // Spot-check a few bytes in output
  let result = inner.content()
  assert_eq(result[0], b'\x00')
  assert_eq(result[255], b'\xff')
  assert_eq(result[256], b'\x00')
}
