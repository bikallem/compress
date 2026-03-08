///|
test "Buffered push_back" {
  let reader = @stream.BytesReader::new(b"hello world", slice_length=5)
  let buffered = @stream.Buffered::new(reader)
  let c1 = buffered.read()
  inspect(c1.length(), content="5") // "hello"
  // push it back
  buffered.push_back(c1)
  let c2 = buffered.read()
  inspect(c2.length(), content="5") // "hello" again
  assert_eq(c2[0], b'h')
  let c3 = buffered.read()
  inspect(c3.length(), content="5") // " worl"
}

///|
test "LimitReader truncates" {
  let reader = @stream.BytesReader::new(b"hello world", slice_length=100)
  let limited = @stream.LimitReader::new(reader, 5)
  let c1 = limited.read()
  inspect(c1.length(), content="5")
  assert_eq(c1, b"hello"[:])
  let c2 = limited.read()
  assert_true(c2.is_empty())
}

///|
test "LimitReader with smaller chunks" {
  let reader = @stream.BytesReader::new(b"abcdefghij", slice_length=3)
  let limited = @stream.LimitReader::new(reader, 7)
  let c1 = limited.read()
  inspect(c1.length(), content="3") // "abc"
  let c2 = limited.read()
  inspect(c2.length(), content="3") // "def"
  let c3 = limited.read()
  inspect(c3.length(), content="1") // "g" (truncated)
  let c4 = limited.read()
  assert_true(c4.is_empty())
}

///|
test "AppendReader concatenates" {
  let r1 = @stream.BytesReader::new(b"abc", slice_length=100)
  let r2 = @stream.BytesReader::new(b"def", slice_length=100)
  let appended = @stream.AppendReader::new(r1, r2)
  let c1 = appended.read()
  assert_eq(c1, b"abc"[:])
  let c2 = appended.read()
  assert_eq(c2, b"def"[:])
  let c3 = appended.read()
  assert_true(c3.is_empty())
}

///|
test "TapReader observes without transforming" {
  let mut total = 0
  let reader = @stream.BytesReader::new(b"hello", slice_length=100)
  let tapped = @stream.TapReader::new(reader, fn(chunk) {
    total += chunk.length()
  })
  let c = tapped.read()
  assert_eq(c, b"hello"[:])
  inspect(total, content="5")
  let eod = tapped.read()
  assert_true(eod.is_empty())
  inspect(total, content="5") // tap not called for eod
}

///|
test "TapWriter observes without transforming" {
  let mut total = 0
  let inner = @stream.BytesWriter::new()
  let tapped = @stream.TapWriter::new(inner, fn(chunk) {
    total += chunk.length()
  })
  tapped.write(b"hi"[:])
  tapped.write(b"there"[:])
  tapped.write(b""[:]) // eod
  inspect(total, content="7")
  assert_eq(inner.content(), b"hithere")
}

///|
test "CountedReader tracks position" {
  let reader = @stream.BytesReader::new(b"abcdefghij", slice_length=4)
  let counted = @stream.CountedReader::new(reader)
  inspect(counted.position(), content="0")
  let _ = counted.read()
  inspect(counted.position(), content="4")
  let _ = counted.read()
  inspect(counted.position(), content="8")
  let _ = counted.read()
  inspect(counted.position(), content="10")
  let _ = counted.read() // eod
  inspect(counted.position(), content="10")
}

///|
test "CountedWriter tracks position" {
  let inner = @stream.BytesWriter::new()
  let counted = @stream.CountedWriter::new(inner)
  inspect(counted.position(), content="0")
  counted.write(b"hello"[:])
  inspect(counted.position(), content="5")
  counted.write(b" world"[:])
  inspect(counted.position(), content="11")
}

///|
test "composition: limit + tap + counted" {
  let data = Bytes::makei(100, fn(i) { i.to_byte() })
  let reader = @stream.BytesReader::new(data, slice_length=20)
  let limited = @stream.LimitReader::new(reader, 50)
  let mut observed = 0
  let tapped = @stream.TapReader::new(limited, fn(chunk) {
    observed += chunk.length()
  })
  let counted = @stream.CountedReader::new(tapped)
  let result = @stream.read_all(counted)
  inspect(result.length(), content="50")
  inspect(observed, content="50")
  inspect(counted.position(), content="50")
}

///|
test "error propagation through combinators" {
  let reader = @stream.FnReader::new(error_fill, slice_length=10)
  let limited = @stream.LimitReader::new(reader, 100)
  let result : Result[BytesView, Error] = try? limited.read()
  assert_true(result is Err(_))
}

///|
fn error_fill(_buf : FixedArray[Byte]) -> Int raise @stream.StreamError {
  raise @stream.StreamError::Io("test error")
}
