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
  let original = repeat_bytes(b"gzip example data for compression. ", 200)

  // --- Compress with default settings ---
  let compressed = @gz.compress(original)
  println(
    "gzip compressed: \{original.length()} -> \{compressed.length()} bytes",
  )

  // --- Decompress (returns data + header) ---
  let (restored, header) = @gz.decompress(compressed)
  assert_eq(restored, original)
  println("Round-trip: OK")
  println("Header OS: \{header.os}")

  // --- Compress with custom header ---
  let hdr : @gz.Header = {
    name: "example.txt",
    comment: "compressed by blem/compress",
    extra: b"",
    mod_time: 1709856000U,
    os: b'\xff',
  }
  let compressed2 = @gz.compress(original, header=hdr, level=BestCompression)
  let (restored2, header2) = @gz.decompress(compressed2)
  assert_eq(restored2, original)
  println("Name:    \{header2.name}")
  println("Comment: \{header2.comment}")

  // --- Compress with different levels ---
  let fast = @gz.compress(original, level=BestSpeed)
  let best = @gz.compress(original, level=BestCompression)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")

  // --- Streaming API ---
  let dest = @stream.BufferWriter::new()
  let gzip_writer = @gz.GzipStreamWriter::new(dest)
  @stream.pipe(
    @stream.SliceReader::new(original, slice_length=4096),
    gzip_writer,
  )
  let stream_compressed = dest.to_bytes()
  let reader = @gz.GzipReader::new(@stream.SliceReader::new(stream_compressed))
  let stream_restored = @stream.read_all(reader)
  assert_eq(stream_restored, original)
  println(
    "Streaming: \{stream_compressed.length()} bytes, header.name=\"\{reader.header().name}\"",
  )

  // --- Error handling ---
  let result : Result[(Bytes, @gz.Header), Error] = try? @gz.decompress(
    b"\x00\x01\x02",
  )
  match result {
    Err(e) => println("Expected: \{e}")
    Ok(_) => println("Unexpected result")
  }
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
