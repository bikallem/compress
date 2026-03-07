///|
fn run() -> Unit raise {
  // bzip2-compressed "Hello"
  let compressed : Bytes = [
    0x42, 0x5A, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x1A, 0x54, 0x64,
    0x92, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x40, 0x02, 0x04, 0xA0, 0x00, 0x21,
    0x9A, 0x68, 0x33, 0x4D, 0x13, 0x33, 0x8B, 0xB9, 0x22, 0x9C, 0x28, 0x48, 0x0D,
    0x2A, 0x32, 0x49, 0x00,
  ]
  let decompressed = @bz2.decompress(compressed)
  assert_eq(decompressed, b"Hello")
  println("bzip2 decompressed: \{decompressed.length()} bytes, content OK")

  // --- Streaming API ---
  let reader = @bz2.Bzip2Reader::new(
    @stream.SliceReader::new(compressed, slice_length=16),
  )
  let stream_result = @stream.read_all(reader)
  assert_eq(stream_result, b"Hello")
  println("Streaming decompress: OK")

  // --- Round-trip ---
  let original = b"Hello, bzip2 streaming!"
  let rt_compressed = @bz2.compress(original)
  let rt_reader = @bz2.Bzip2Reader::new(@stream.SliceReader::new(rt_compressed))
  let rt_result = @stream.read_all(rt_reader)
  assert_eq(rt_result, original)
  println("Round-trip: OK (\{rt_compressed.length()} bytes)")

  // --- Error handling ---
  let bad_result : Result[Bytes, Error] = try? @bz2.decompress(b"\x00\x01\x02")
  match bad_result {
    Err(e) => println("Expected error: \{e}")
    Ok(_) => println("Unexpected success")
  }
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
