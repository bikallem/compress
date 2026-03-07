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
  let original = repeat_bytes(b"Sync gzip streaming. ", 500)

  // --- Compress with custom header ---
  let hdr : @gzip.Header = {
    name: "data.txt",
    comment: "",
    extra: b"",
    mod_time: 0U,
    os: b'\xff',
  }
  let comp = @gzip_sync.GzipCompressor::new(
    level=DefaultCompression,
    header=hdr,
  )
  comp.update(original)
  let compressed = comp.finish()
  println("Compressed: \{compressed.length()} bytes")

  // --- Decompress ---
  let decomp = @gzip_sync.GzipDecompressor::new()
  decomp.update(compressed)
  let (restored, header) = decomp.finish()
  assert_eq(restored, original)
  println("Header name: \{header.name}")
  println("Round-trip: OK")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
