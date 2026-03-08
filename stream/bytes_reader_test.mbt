///|
test "BytesReader yields chunks of slice_length" {
  let data = Bytes::makei(100, fn(i) { i.to_byte() })
  let reader = @stream.BytesReader::new(data, slice_length=30)
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
test "BytesReader empty input" {
  let reader = @stream.BytesReader::new(b"")
  let c = reader.read()
  assert_true(c.is_empty())
}

///|
test "BytesReader chunks never exceed slice_length" {
  let data = Bytes::makei(1000, fn(i) { i.to_byte() })
  let slice_length = 64
  let reader = @stream.BytesReader::new(data, slice_length~)
  while true {
    let chunk = reader.read()
    if chunk.is_empty() {
      break
    }
    assert_true(chunk.length() <= slice_length)
  }
}
