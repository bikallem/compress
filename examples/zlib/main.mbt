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
  let original = repeat_bytes(b"zlib framing with Adler-32 checksum. ", 200)

  // --- Compress/decompress ---
  let compressed = @zliblib.compress(original)
  let restored = @zliblib.decompress(compressed)
  assert_eq(restored, original)
  println("zlib: \{original.length()} -> \{compressed.length()} bytes")

  // --- With compression level ---
  let fast = @zliblib.compress(original, level=BestSpeed)
  let best = @zliblib.compress(original, level=BestCompression)
  println("BestSpeed: \{fast.length()}, BestCompression: \{best.length()}")

  // --- With preset dictionary ---
  let dict = b"zlib framing Adler checksum"
  let compressed_d = @zliblib.compress_with_dict(
    original,
    dict,
    level=DefaultCompression,
  )
  let restored_d = @zliblib.decompress_with_dict(compressed_d, dict)
  assert_eq(restored_d, original)
  println("With dict: \{compressed_d.length()} bytes")

  // --- Streaming API ---
  let dest = @stream.BytesWriter::new()
  let zlib_writer = @zliblib.ZlibStreamWriter::new(dest)
  @stream.pipe(
    @stream.BytesReader::new(original, slice_length=4096),
    zlib_writer,
  )
  let stream_compressed = dest.to_bytes()
  let reader = @zliblib.ZlibReader::new(
    @stream.BytesReader::new(stream_compressed),
  )
  let stream_restored = @stream.read_all(reader)
  assert_eq(stream_restored, original)
  println("Streaming: \{stream_compressed.length()} bytes, round-trip OK")

  // --- Error handling ---
  let result : Result[Bytes, Error] = try? @zliblib.decompress(b"\x00\x01\x02")
  match result {
    Err(e) => println("Expected error: \{e}")
    Ok(_) => println("Unexpected")
  }
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
