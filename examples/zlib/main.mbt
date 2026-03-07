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
  let compressed = @zlib.compress(original)
  let restored = @zlib.decompress(compressed)
  assert_eq(restored, original)
  println("zlib: \{original.length()} -> \{compressed.length()} bytes")

  // --- With compression level ---
  let fast = @zlib.compress(original, level=BestSpeed)
  let best = @zlib.compress(original, level=BestCompression)
  println("BestSpeed: \{fast.length()}, BestCompression: \{best.length()}")

  // --- With preset dictionary ---
  let dict = b"zlib framing Adler checksum"
  let compressed_d = @zlib.compress_with_dict(
    original,
    dict,
    level=DefaultCompression,
  )
  let restored_d = @zlib.decompress_with_dict(compressed_d, dict)
  assert_eq(restored_d, original)
  println("With dict: \{compressed_d.length()} bytes")

  // --- Error handling ---
  let result : Result[Bytes, Error] = try? @zlib.decompress(b"\x00\x01\x02")
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
