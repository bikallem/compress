///|
async test "BytesWriter collects output" {
  let writer = @io.BytesWriter::new()
  writer.write(b"hello"[:])
  writer.write(b" world"[:])
  let result = writer.content()
  assert_eq(result, b"hello world")
}
