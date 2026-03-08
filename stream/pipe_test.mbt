///|
test "pipe reader to writer" {
  let reader = @stream.BytesReader::new(b"hello world", slice_length=4)
  let writer = @stream.BytesWriter::new()
  @stream.pipe(reader, writer)
  assert_eq(writer.content(), b"hello world")
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
