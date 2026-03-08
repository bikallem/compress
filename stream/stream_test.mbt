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
test "BytesWriter collects output" {
  let writer = @stream.BytesWriter::new()
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
  assert_eq(inner.to_bytes(), b"hithere")
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
test "pipe reader to writer" {
  let reader = @stream.BytesReader::new(b"hello world", slice_length=4)
  let writer = @stream.BytesWriter::new()
  @stream.pipe(reader, writer)
  assert_eq(writer.to_bytes(), b"hello world")
}

///|
test "read_all drains reader" {
  let reader = @stream.BytesReader::new(b"hello world", slice_length=3)
  let result = @stream.read_all(reader)
  assert_eq(result, b"hello world")
}

///|
test "read_all empty reader" {
  let reader = @stream.BytesReader::new(b"")
  let result = @stream.read_all(reader)
  assert_eq(result, b"")
}

///|
test "pipe through TapReader for checksum" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let reader = @stream.BytesReader::new(data, slice_length=50)
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

///|
/// Large-stream bounded memory test: 10MB generated data piped through
/// TapReader+CountedReader, consumed chunk-by-chunk with running checksum.
/// No accumulation — only one chunk alive at a time.
test "large stream bounded memory: 10MB pipe with running checksum" {
  let total_bytes = 10 * 1024 * 1024 // 10MB
  let chunk_size = 4096
  // Generate data chunk-by-chunk via FnReader (no 10MB allocation)
  let mut generated = 0
  let reader = @stream.FnReader::new(slice_length=chunk_size, fn(buf) {
    if generated >= total_bytes {
      return 0
    }
    let remaining = total_bytes - generated
    let n = if remaining < buf.length() { remaining } else { buf.length() }
    for i in 0..<n {
      // deterministic byte pattern
      buf[i] = ((generated + i) % 251).to_byte()
    }
    generated += n
    n
  })
  // Running checksum via TapReader — no accumulation
  let mut checksum : UInt = 0U
  let tapped = @stream.TapReader::new(reader, fn(chunk) {
    for i in 0..<chunk.length() {
      // simple hash: rotate left 5 + xor
      checksum = (checksum << 5) | (checksum >> 27)
      checksum = checksum ^ chunk[i].to_int().reinterpret_as_uint()
    }
  })
  let counted = @stream.CountedReader::new(tapped)
  // Consume chunk-by-chunk via FnWriter — discard immediately
  let mut max_chunk_seen = 0
  let writer = @stream.FnWriter::new(fn(data) {
    if data.length() > max_chunk_seen {
      max_chunk_seen = data.length()
    }
  })
  @stream.pipe(counted, writer)
  // Verify all bytes consumed
  inspect(counted.position(), content="10485760")
  // Verify chunks bounded
  assert_true(max_chunk_seen <= chunk_size)
  assert_true(max_chunk_seen > 0)
  // Verify checksum is deterministic (not zero)
  assert_true(checksum != 0U)
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
  let result = inner.to_bytes()
  assert_eq(result[0], b'\x00')
  assert_eq(result[255], b'\xff')
  assert_eq(result[256], b'\x00')
}
