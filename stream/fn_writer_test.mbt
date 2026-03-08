///|
test "FnWriter callback" {
  let collected = @buffer.new()
  let writer = @stream.FnWriter::new(fn(data) {
    for i in 0..<data.length() {
      collected.write_byte(data[i])
    }
  })
  writer.write(b"abc"[:])
  writer.write(b"def"[:])
  assert_eq(collected.to_bytes(), b"abcdef")
}
