///|
test "GzipReader decompresses gzip data" {
  let original = b"Hello, World! This is a test of gzip streaming."
  let compressed = @gzip.compress(original)
  let reader = @gzip.GzipReader::new(
    @stream.SliceReader::new(compressed, slice_length=16),
  )
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}

///|
test "GzipReader exposes header" {
  let original = b"test data"
  let header = @gzip.Header::{
    name: "test.txt",
    comment: "a comment",
    extra: Bytes::default(),
    mod_time: 12345U,
    os: b'\xFF',
  }
  let compressed = @gzip.compress(original, header~)
  let reader = @gzip.GzipReader::new(@stream.SliceReader::new(compressed))
  let result = @stream.read_all(reader)
  assert_eq(result, original)
  assert_eq(reader.header().name, "test.txt")
  assert_eq(reader.header().comment, "a comment")
  assert_eq(reader.header().mod_time, 12345U)
}

///|
test "GzipReader yields bounded chunks" {
  let original = Bytes::makei(5000, fn(i) { (i % 256).to_byte() })
  let compressed = @gzip.compress(original)
  let reader = @gzip.GzipReader::new(
    @stream.SliceReader::new(compressed),
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
test "GzipStreamWriter compresses data" {
  let original = b"Hello, World! This is gzip streaming compression."
  let dest_buf = @stream.BufferWriter::new()
  let writer = @gzip.GzipStreamWriter::new(dest_buf)
  writer.write(original[0:20])
  writer.write(original[20:])
  writer.write(b""[:])
  let compressed = dest_buf.to_bytes()
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "GzipStreamWriter with header" {
  let original = b"test"
  let header = @gzip.Header::{
    name: "out.txt",
    comment: "",
    extra: Bytes::default(),
    mod_time: 0U,
    os: b'\xFF',
  }
  let dest_buf = @stream.BufferWriter::new()
  let writer = @gzip.GzipStreamWriter::new(dest_buf, header~)
  writer.write(original[:])
  writer.write(b""[:])
  let (decompressed, got_header) = @gzip.decompress(dest_buf.to_bytes())
  assert_eq(decompressed, original)
  assert_eq(got_header.name, "out.txt")
}

///|
test "GzipReader + GzipStreamWriter round-trip via pipe" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compress_dest = @stream.BufferWriter::new()
  let gzip_writer = @gzip.GzipStreamWriter::new(compress_dest)
  @stream.pipe(
    @stream.SliceReader::new(original, slice_length=500),
    gzip_writer,
  )
  let compressed = compress_dest.to_bytes()
  let reader = @gzip.GzipReader::new(@stream.SliceReader::new(compressed))
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}
