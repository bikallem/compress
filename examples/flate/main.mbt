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
  let compressed = @flate.compress(original)
  println("Original:   \{original.length()} bytes")
  println("Compressed: \{compressed.length()} bytes")

  // --- Decompress ---
  let restored = @flate.decompress(compressed)
  assert_eq(restored, original)
  println("Round-trip: OK")

  // --- Compress with specific levels ---
  let fast = @flate.compress(original, level=BestSpeed)
  let best = @flate.compress(original, level=BestCompression)
  let none = @flate.compress(original, level=NoCompression)
  let huff = @flate.compress(original, level=HuffmanOnly)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")
  println("NoCompression:   \{none.length()} bytes")
  println("HuffmanOnly:     \{huff.length()} bytes")

  // All decompress to the same original
  assert_eq(@flate.decompress(fast), original)
  assert_eq(@flate.decompress(best), original)
  assert_eq(@flate.decompress(none), original)
  assert_eq(@flate.decompress(huff), original)

  // --- Dictionary-based compression ---
  let dict = b"the quick brown fox lazy dog"
  let compressed_dict = @flate.compress_with_dict(
    original,
    dict,
    level=DefaultCompression,
  )
  let restored_dict = @flate.decompress_with_dict(compressed_dict, dict)
  assert_eq(restored_dict, original)
  println(
    "With dict:  \{compressed_dict.length()} bytes (vs \{compressed.length()} without)",
  )

  // --- Error handling ---
  let result : Result[Bytes, Error] = try? @flate.decompress(b"\x00\xFF\xFE")
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
