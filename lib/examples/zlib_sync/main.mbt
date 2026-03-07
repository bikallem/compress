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
  let original = repeat_bytes(b"Sync zlib chunked. ", 500)

  // --- Compress ---
  let comp = @zlib_sync.ZlibCompressor::new(level=BestSpeed)
  comp.update(original)
  let compressed = comp.finish()
  println("Compressed: \{original.length()} -> \{compressed.length()} bytes")

  // --- Decompress ---
  let decomp = @zlib_sync.ZlibDecompressor::new()
  decomp.update(compressed)
  let restored = decomp.finish()
  assert_eq(restored, original)
  println("zlib sync round-trip: OK")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
