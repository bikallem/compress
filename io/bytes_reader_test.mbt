///|
async test "BytesReader yields chunks of slice_length" {
  let data = Bytes::makei(100, fn(i) { i.to_byte() })
  let reader = @io.BytesReader::new(data, slice_length=30)
  let c1 = reader.read()
  inspect(c1.length(), content="30")
  let c2 = reader.read()
  inspect(c2.length(), content="30")
  let c3 = reader.read()
  inspect(c3.length(), content="30")
  let c4 = reader.read()
  inspect(c4.length(), content="10")
  let c5 = reader.read()
  inspect(c5.length(), content="0") // eod
  // eod is idempotent
  let c6 = reader.read()
  inspect(c6.length(), content="0")
}

///|
async test "BytesReader empty input" {
  let reader = @io.BytesReader::new(b"")
  let c = reader.read()
  assert_true(c.is_empty())
}

///|
async test "BytesReader chunks never exceed slice_length" {
  let data = Bytes::makei(1000, fn(i) { i.to_byte() })
  let slice_length = 64
  let reader = @io.BytesReader::new(data, slice_length~)
  while true {
    let chunk = reader.read()
    if chunk.is_empty() {
      break
    }
    assert_true(chunk.length() <= slice_length)
  }
}

///|
async test "BytesReader.read_byte reads sequential bytes" {
  let reader = @io.BytesReader::new(b"abc", slice_length=2)
  assert_eq(reader.read_byte(), b'a')
  assert_eq(reader.read_byte(), b'b')
  assert_eq(reader.read_byte(), b'c')
}

///|
async test "BytesReader.read_byte interops with read" {
  let reader = @io.BytesReader::new(b"abcd", slice_length=2)
  assert_eq(reader.read_byte(), b'a')
  assert_eq(reader.read(), b"bc"[:])
  assert_eq(reader.read_byte(), b'd')
  assert_true(reader.read().is_empty())
}

///|
async test "BytesReader.read_byte raises at eof" {
  let reader = @io.BytesReader::new(b"a")
  assert_eq(reader.read_byte(), b'a')
  let result : Result[Byte, Error] = try? reader.read_byte()
  guard result is Err(err) else { fail("expected eof error") }
  inspect(
    err,
    content=(
      #|IoError: unexpected end of data
    ),
  )
}
