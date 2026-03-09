///|
async test "BytesWriter collects output" {
  let writer = @io.BytesWriter::new()
  writer.write(b"hello"[:])
  writer.write(b" world"[:])
  let result = writer.content()
  assert_eq(result, b"hello world")
}

///|
async test "BytesWriter.write_byte" {
  let w = @io.BytesWriter::new()
  let writer : &@io.Writer = w
  writer.write_byte(b'A')
  writer.write_byte(b'B')
  writer.write_byte(b'C')
  assert_eq(w.content(), b"ABC")
}

///|
async test "BytesWriter.write_byte mixed with write" {
  let w = @io.BytesWriter::new()
  let writer : &@io.Writer = w
  writer.write(b"hi"[:])
  writer.write_byte(b'!')
  assert_eq(w.content(), b"hi!")
}

///|
async test "BytesWriter.write_byte triggers grow" {
  let w = @io.BytesWriter::new(size_hint=2)
  let writer : &@io.Writer = w
  writer.write_byte(b'a')
  writer.write_byte(b'b')
  writer.write_byte(b'c') // exceeds initial capacity
  assert_eq(w.content(), b"abc")
}
