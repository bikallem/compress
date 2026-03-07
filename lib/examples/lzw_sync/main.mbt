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
  let original = repeat_bytes(b"LZW sync chunked data. ", 500)

  // --- Compress ---
  let comp = @lzw_sync.LzwCompressor::new(LSB, 8)
  comp.update(original)
  let compressed = comp.finish()
  println("Compressed: \{original.length()} -> \{compressed.length()} bytes")

  // --- Decompress ---
  let decomp = @lzw_sync.LzwDecompressor::new(LSB, 8)
  decomp.update(compressed)
  let restored = decomp.finish()
  assert_eq(restored, original)
  println("LZW sync round-trip: OK")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
