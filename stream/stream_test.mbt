///|
test "SliceReader yields chunks of slice_length" {
  let data = Bytes::makei(100, fn(i) { i.to_byte() })
  let reader = @stream.SliceReader::new(data, slice_length=30)
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
test "SliceReader empty input" {
  let reader = @stream.SliceReader::new(b"")
  let c = reader.read()
  assert_true(c.is_empty())
}

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
test "BufferWriter collects output" {
  let writer = @stream.BufferWriter::new()
  writer.write(b"hello"[:])
  writer.write(b" world"[:])
  writer.write(b""[:]) // eod
  let result = writer.to_bytes()
  assert_eq(result, b"hello world")
}

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

///|
test "Buffered push_back" {
  let reader = @stream.SliceReader::new(b"hello world", slice_length=5)
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
  let reader = @stream.SliceReader::new(b"hello world", slice_length=100)
  let limited = @stream.LimitReader::new(reader, 5)
  let c1 = limited.read()
  inspect(c1.length(), content="5")
  assert_eq(c1, b"hello"[:])
  let c2 = limited.read()
  assert_true(c2.is_empty())
}

///|
test "LimitReader with smaller chunks" {
  let reader = @stream.SliceReader::new(b"abcdefghij", slice_length=3)
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
  let r1 = @stream.SliceReader::new(b"abc", slice_length=100)
  let r2 = @stream.SliceReader::new(b"def", slice_length=100)
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
  let reader = @stream.SliceReader::new(b"hello", slice_length=100)
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
  let inner = @stream.BufferWriter::new()
  let tapped = @stream.TapWriter::new(inner, fn(chunk) {
    total += chunk.length()
  })
  tapped.write(b"hi"[:])
  tapped.write(b"there"[:])
  tapped.write(b""[:]) // eod
  inspect(total, content="7")
  assert_eq(inner.to_bytes(), b"hithere")
}

///|
test "CountedReader tracks position" {
  let reader = @stream.SliceReader::new(b"abcdefghij", slice_length=4)
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
  let inner = @stream.BufferWriter::new()
  let counted = @stream.CountedWriter::new(inner)
  inspect(counted.position(), content="0")
  counted.write(b"hello"[:])
  inspect(counted.position(), content="5")
  counted.write(b" world"[:])
  inspect(counted.position(), content="11")
}

///|
test "pipe reader to writer" {
  let reader = @stream.SliceReader::new(b"hello world", slice_length=4)
  let writer = @stream.BufferWriter::new()
  @stream.pipe(reader, writer)
  assert_eq(writer.to_bytes(), b"hello world")
}

///|
test "read_all drains reader" {
  let reader = @stream.SliceReader::new(b"hello world", slice_length=3)
  let result = @stream.read_all(reader)
  assert_eq(result, b"hello world")
}

///|
test "read_all empty reader" {
  let reader = @stream.SliceReader::new(b"")
  let result = @stream.read_all(reader)
  assert_eq(result, b"")
}

///|
test "pipe through TapReader for checksum" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let reader = @stream.SliceReader::new(data, slice_length=50)
  let mut byte_sum = 0
  let tapped = @stream.TapReader::new(reader, fn(chunk) {
    for i in 0..<chunk.length() {
      byte_sum += chunk[i].to_int()
    }
  })
  let result = @stream.read_all(tapped)
  assert_eq(result, data)
  // Sum of 0..255 = 32640
  inspect(byte_sum, content="32640")
}

///|
test "composition: limit + tap + counted" {
  let data = Bytes::makei(100, fn(i) { i.to_byte() })
  let reader = @stream.SliceReader::new(data, slice_length=20)
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
