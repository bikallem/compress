///|
async test "BytesReader feeds async io.Reader" {
  let data = Bytes::makei(64, fn(i) { i.to_byte() })
  let reader = @bytes.BytesReader::new(data)
  let buf = FixedArray::make(16, b'\x00')
  let out = @bytes.BytesWriter::new()
  while reader.read(buf, offset=0, max_len=buf.length()) is n && n > 0 {
    out.write(buf.unsafe_reinterpret_as_bytes()[:n])
  }
  assert_eq(out.content(), data)
}

///|
async test "BytesWriter collects async io.Writer output" {
  let writer = @bytes.BytesWriter::new(size_hint=2)
  writer.write(b"ab")
  writer.write(b"cd")
  assert_eq(writer.content(), b"abcd")
}
