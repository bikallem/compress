///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for i = 0; i < n; i = i + 1 {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
fn run() -> Unit raise {
  let original = repeat_bytes(
    b"The quick brown fox jumps over the lazy dog. ", 100,
  )

  // --- Compress with default level (6) ---
  let compressed = @deflate.compress(original)
  println("Original:   \{original.length()} bytes")
  println("Compressed: \{compressed.length()} bytes")

  // --- Decompress ---
  let restored = @deflate.decompress(compressed)
  assert_eq(restored, original)
  println("Round-trip: OK")

  // --- Compress with specific levels ---
  let fast = @deflate.compress(original, level=BestSpeed)
  let best = @deflate.compress(original, level=BestCompression)
  let none = @deflate.compress(original, level=NoCompression)
  let huff = @deflate.compress(original, level=HuffmanOnly)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")
  println("NoCompression:   \{none.length()} bytes")
  println("HuffmanOnly:     \{huff.length()} bytes")

  // All decompress to the same original
  assert_eq(@deflate.decompress(fast), original)
  assert_eq(@deflate.decompress(best), original)
  assert_eq(@deflate.decompress(none), original)
  assert_eq(@deflate.decompress(huff), original)

  // --- Dictionary-based compression ---
  let dict = b"the quick brown fox lazy dog"
  let compressed_dict = @deflate.compress_with_dict(
    original,
    dict,
    level=DefaultCompression,
  )
  let restored_dict = @deflate.decompress_with_dict(compressed_dict, dict)
  assert_eq(restored_dict, original)
  println(
    "With dict:  \{compressed_dict.length()} bytes (vs \{compressed.length()} without)",
  )

  // --- Streaming API ---
  let dest = @stream.BytesWriter::new()
  let writer = @deflate.DeflateWriter::new(dest, level=DefaultCompression)
  @stream.pipe(@stream.BytesReader::new(original, slice_length=4096), writer)
  let stream_compressed = dest.content()
  let reader = @deflate.InflateReader::new(
    @stream.BytesReader::new(stream_compressed),
  )
  let stream_restored = @stream.read_all(reader)
  assert_eq(stream_restored, original)
  println("Streaming: \{stream_compressed.length()} bytes, round-trip OK")

  // --- Error handling ---
  let result : Result[Bytes, Error] = try? @deflate.decompress(b"\x00\xFF\xFE")
  match result {
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
