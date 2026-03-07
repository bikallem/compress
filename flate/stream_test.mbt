///|
test "InflateReader decompresses DEFLATE data" {
  let original = b"Hello, World! This is a test of DEFLATE streaming compression."
  let compressed = @flate.compress(original)
  let reader = @flate.InflateReader::new(
    @stream.SliceReader::new(compressed, slice_length=16),
  )
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}

///|
test "InflateReader yields bounded chunks" {
  let original = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @flate.compress(original)
  let reader = @flate.InflateReader::new(
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
  assert_eq(total, 10000)
  assert_true(max_chunk <= 1000)
}

///|
test "DeflateWriter compresses data" {
  let original = b"Hello, World! This is a test of DEFLATE streaming compression."
  let dest_buf = @stream.BufferWriter::new()
  let writer = @flate.DeflateWriter::new(dest_buf)
  // Write in small chunks
  writer.write(original[0:20])
  writer.write(original[20:40])
  writer.write(original[40:])
  writer.write(b""[:]) // eod triggers compression
  let compressed = dest_buf.to_bytes()
  // Verify by decompressing
  let decompressed = @flate.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "InflateReader + DeflateWriter round-trip via pipe" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress
  let compress_dest = @stream.BufferWriter::new()
  let deflater = @flate.DeflateWriter::new(compress_dest)
  @stream.pipe(@stream.SliceReader::new(original, slice_length=500), deflater)
  let compressed = compress_dest.to_bytes()
  // Decompress
  let inflater = @flate.InflateReader::new(@stream.SliceReader::new(compressed))
  let result = @stream.read_all(inflater)
  assert_eq(result, original)
}

///|
test "DeflateWriter with compression levels" {
  let original = Bytes::makei(1000, fn(i) { (i % 26 + 65).to_byte() })
  // Test NoCompression
  let dest = @stream.BufferWriter::new()
  let writer = @flate.DeflateWriter::new(dest, level=NoCompression)
  writer.write(original[:])
  writer.write(b""[:])
  let decompressed = @flate.decompress(dest.to_bytes())
  assert_eq(decompressed, original)
  // Test BestSpeed
  let dest2 = @stream.BufferWriter::new()
  let writer2 = @flate.DeflateWriter::new(dest2, level=BestSpeed)
  writer2.write(original[:])
  writer2.write(b""[:])
  let decompressed2 = @flate.decompress(dest2.to_bytes())
  assert_eq(decompressed2, original)
}
