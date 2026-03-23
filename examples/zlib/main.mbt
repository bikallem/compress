///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @blit.Buffer::new(size_hint=b.length() * n)
  for _ in 0..<n {
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
  let compressed_d = @zliblib.compress(
    original,
    dict~,
    level=DefaultCompression,
  )
  let restored_d = @zliblib.decompress(compressed_d, dict~)
  assert_eq(restored_d, original)
  println("With dict: \{compressed_d.length()} bytes")

  // --- Streaming API (signal protocol) ---
  let deflater = @zliblib.Deflater::new()
  let cbuf = @blit.Buffer::new()
  match deflater.encode(Some(original[:])) {
    Data(out) => cbuf.write_bytesview(out)
    Ok | End | Error(_) => ()
  }
  loop deflater.encode(None) {
    Data(out) => {
      cbuf.write_bytesview(out)
      continue deflater.encode(None)
    }
    End | Ok | Error(_) => break
  }
  let stream_compressed = cbuf.to_bytes()

  let inflater = @zliblib.Inflater::new()
  let dbuf = @blit.Buffer::new()
  inflater.src(stream_compressed[:])
  loop inflater.decode() {
    Await => break
    Data(out) => {
      dbuf.write_bytesview(out)
      continue inflater.decode()
    }
    End => break
    Error(_) => break
  }
  assert_eq(dbuf.to_bytes(), original)
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
