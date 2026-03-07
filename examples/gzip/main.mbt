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
  let compressed = @gzip.compress(original)
  println(
    "gzip compressed: \{original.length()} -> \{compressed.length()} bytes",
  )

  // --- Decompress (returns data + header) ---
  let (restored, header) = @gzip.decompress(compressed)
  assert_eq(restored, original)
  println("Round-trip: OK")
  println("Header OS: \{header.os}")

  // --- Compress with custom header ---
  let hdr : @gzip.Header = {
    name: "example.txt",
    comment: "compressed by blem/compress",
    extra: b"",
    mod_time: 1709856000U,
    os: b'\xff',
  }
  let compressed2 = @gzip.compress(original, header=hdr, level=BestCompression)
  let (restored2, header2) = @gzip.decompress(compressed2)
  assert_eq(restored2, original)
  println("Name:    \{header2.name}")
  println("Comment: \{header2.comment}")

  // --- Compress with different levels ---
  let fast = @gzip.compress(original, level=BestSpeed)
  let best = @gzip.compress(original, level=BestCompression)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")

  // --- Error handling ---
  let result : Result[(Bytes, @gzip.Header), Error] = try? @gzip.decompress(
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
