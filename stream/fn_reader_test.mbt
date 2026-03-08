///|
test "FnReader buffer reuse pattern" {
  let data = Bytes::makei(50, fn(i) { i.to_byte() })
  let mut offset = 0
  let reader = @stream.FnReader::new(slice_length=20, fn(buf) {
    if offset >= data.length() {
      return 0
    }
    let remaining = data.length() - offset
    let n = if remaining < buf.length() { remaining } else { buf.length() }
    for i in 0..<n {
      buf[i] = data[offset + i]
    }
    offset += n
    n
  })
  let c1 = reader.read()
  inspect(c1.length(), content="20")
  assert_eq(c1[0], b'\x00')
  let c2 = reader.read()
  inspect(c2.length(), content="20")
  let c3 = reader.read()
  inspect(c3.length(), content="10")
  let c4 = reader.read()
  assert_true(c4.is_empty())
}

///|
test "FnReader chunks never exceed slice_length" {
  let total = 500
  let mut pos = 0
  let slice_length = 37
  let reader = @stream.FnReader::new(slice_length~, fn(buf) {
    if pos >= total {
      return 0
    }
    let n = if total - pos < buf.length() { total - pos } else { buf.length() }
    for i in 0..<n {
      buf[i] = b'\x42'
    }
    pos += n
    n
  })
  let mut chunks = 0
  while true {
    let chunk = reader.read()
    if chunk.is_empty() {
      break
    }
    assert_true(chunk.length() <= slice_length)
    chunks += 1
  }
  // ceil(500/37) = 14 chunks
  inspect(chunks, content="14")
}
