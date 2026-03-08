///|
test "Bzip2Reader decompresses bzip2 data" {
  let original = b"Hello, World! This is a test of bzip2 streaming."
  let compressed = @bzip2.compress(original)
  let reader = @bzip2.Bzip2Reader::new(
    @stream.BytesReader::new(compressed, slice_length=16),
  )
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}

///|
test "Bzip2Reader yields bounded chunks" {
  let original = Bytes::makei(5000, fn(i) { (i % 256).to_byte() })
  let compressed = @bzip2.compress(original)
  let reader = @bzip2.Bzip2Reader::new(
    @stream.BytesReader::new(compressed),
    slice_length=1000,
  )
  let mut max_chunk = 0
  let mut total = 0
  while true {
    let chunk = reader.read()
    if chunk.is_empty() {
      break
    }
    if chunk.length() > max_chunk {
      max_chunk = chunk.length()
    }
    total += chunk.length()
  }
  assert_eq(total, 5000)
  assert_true(max_chunk <= 1000)
}

///|
test "Bzip2Reader round-trip via pipe" {
  let original = Bytes::makei(3000, fn(i) { (i % 251).to_byte() })
  let compressed = @bzip2.compress(original)
  let reader = @bzip2.Bzip2Reader::new(@stream.BytesReader::new(compressed))
  let dest = @stream.BufferWriter::new()
  @stream.pipe(reader, dest)
  assert_eq(dest.to_bytes(), original)
}
