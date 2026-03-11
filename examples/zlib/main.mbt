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

  // --- Streaming API (signal protocol) ---
  let deflater = @zliblib.Deflater::new()
  let cbuf = @buffer.new()
  match deflater.encode(Some(original)) {
    Data(out) => cbuf.write_bytes(out)
    Ok => ()
    _ => ()
  }
  loop deflater.encode(None) {
    Data(out) => {
      cbuf.write_bytes(out)
      continue deflater.encode(None)
    }
    End => break
    _ => break
  }
  let stream_compressed = cbuf.to_bytes()

  let inflater = @zliblib.Inflater::new()
  let dbuf = @buffer.new()
  inflater.src(stream_compressed)
  loop inflater.decode() {
    Await => break
    Data(out) => {
      dbuf.write_bytes(out)
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
