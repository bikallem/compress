///|
test "ZlibReader decompresses zlib data" {
  let original = b"Hello, World! This is a test of zlib streaming."
  let compressed = @zlib.compress(original)
  let reader = @zlib.ZlibReader::new(
    @stream.BytesReader::new(compressed, slice_length=16),
  )
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}

///|
test "ZlibReader yields bounded chunks" {
  let original = Bytes::makei(5000, fn(i) { (i % 256).to_byte() })
  let compressed = @zlib.compress(original)
  let reader = @zlib.ZlibReader::new(
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
test "ZlibStreamWriter compresses data" {
  let original = b"Hello, World! This is zlib streaming compression."
  let dest_buf = @stream.BytesWriter::new()
  let writer = @zlib.ZlibStreamWriter::new(dest_buf)
  writer.write(original[0:20])
  writer.write(original[20:])
  writer.write(b""[:])
  let compressed = dest_buf.content()
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "ZlibStreamWriter with compression levels" {
  let original = Bytes::makei(1000, fn(i) { (i % 26 + 65).to_byte() })
  let dest = @stream.BytesWriter::new()
  let writer = @zlib.ZlibStreamWriter::new(dest, level=NoCompression)
  writer.write(original[:])
  writer.write(b""[:])
  let decompressed = @zlib.decompress(dest.content())
  assert_eq(decompressed, original)
}

///|
test "ZlibReader + ZlibStreamWriter round-trip via pipe" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compress_dest = @stream.BytesWriter::new()
  let zlib_writer = @zlib.ZlibStreamWriter::new(compress_dest)
  @stream.pipe(
    @stream.BytesReader::new(original, slice_length=500),
    zlib_writer,
  )
  let compressed = compress_dest.content()
  let reader = @zlib.ZlibReader::new(@stream.BytesReader::new(compressed))
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}
