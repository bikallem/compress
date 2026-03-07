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
  let original = repeat_bytes(b"Chunked compression without async. ", 500)

  // --- Compress: feed data, then finish ---
  let deflater = @flate_sync.Deflater::new(level=DefaultCompression)
  deflater.update(original)
  let compressed = deflater.finish()
  println("Compressed \{original.length()} -> \{compressed.length()} bytes")

  // --- Decompress ---
  let inflater = @flate_sync.Inflater::new()
  inflater.update(compressed)
  let restored = inflater.finish()
  assert_eq(restored, original)
  println("Round-trip: OK")

  // --- With dictionary ---
  let dict = b"chunked compression async"
  let deflater2 = @flate_sync.Deflater::new(level=DefaultCompression, dict~)
  deflater2.update(original)
  let compressed2 = deflater2.finish()

  let inflater2 = @flate_sync.Inflater::new(dict~)
  inflater2.update(compressed2)
  let restored2 = inflater2.finish()
  assert_eq(restored2, original)
  println("With dict: OK")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
