///|
test "LzwReader decompresses LZW data LSB" {
  let original = b"TOBEORNOTTOBEORTOBEORNOT"
  let compressed = @lzw.compress(original, LSB, 8)
  let reader = @lzw.LzwReader::new(@stream.BytesReader::new(compressed), LSB, 8)
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}

///|
test "LzwReader decompresses LZW data MSB" {
  let original = b"TOBEORNOTTOBEORTOBEORNOT"
  let compressed = @lzw.compress(original, MSB, 8)
  let reader = @lzw.LzwReader::new(@stream.BytesReader::new(compressed), MSB, 8)
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}

///|
test "LzwReader yields bounded chunks" {
  let original = Bytes::makei(5000, fn(i) { (i % 256).to_byte() })
  let compressed = @lzw.compress(original, LSB, 8)
  let reader = @lzw.LzwReader::new(
    @stream.BytesReader::new(compressed),
    LSB,
    8,
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
test "LzwStreamWriter compresses data LSB" {
  let original = b"TOBEORNOTTOBEORTOBEORNOT"
  let dest_buf = @stream.BufferWriter::new()
  let writer = @lzw.LzwStreamWriter::new(dest_buf, LSB, 8)
  writer.write(original[0:10])
  writer.write(original[10:])
  writer.write(b""[:])
  let compressed = dest_buf.to_bytes()
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  assert_eq(decompressed, original)
}

///|
test "LzwReader + LzwStreamWriter round-trip via pipe" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compress_dest = @stream.BufferWriter::new()
  let lzw_writer = @lzw.LzwStreamWriter::new(compress_dest, LSB, 8)
  @stream.pipe(@stream.BytesReader::new(original, slice_length=500), lzw_writer)
  let compressed = compress_dest.to_bytes()
  let reader = @lzw.LzwReader::new(@stream.BytesReader::new(compressed), LSB, 8)
  let result = @stream.read_all(reader)
  assert_eq(result, original)
}
