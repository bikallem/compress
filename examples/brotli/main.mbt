///|
fn repeat_bytes(b : Bytes, n : Int) -> Bytes {
  let buf = @buffer.new(size_hint=b.length() * n)
  for _ in 0..<n {
    buf.write_bytes(b)
  }
  buf.to_bytes()
}

///|
fn run() -> Unit raise {
  let original = repeat_bytes(
    b"brotli example data with repeated phrases and repeated phrases. ", 128,
  )

  // --- Compress/decompress ---
  let compressed = @br.compress(original)
  let restored = @br.decompress(compressed)
  assert_eq(restored, original)
  println("brotli: \{original.length()} -> \{compressed.length()} bytes")

  // --- Quality settings ---
  let fast = @br.compress(original, level=BestSpeed)
  let best = @br.compress(original, level=BestCompression)
  assert_eq(@br.decompress(fast), original)
  assert_eq(@br.decompress(best), original)
  println("BestSpeed: \{fast.length()}, BestCompression: \{best.length()}")

  // --- Streaming API (signal protocol) ---
  let deflater = @br.Deflater::new(level=BestCompression)
  let cbuf = @buffer.new()
  match deflater.encode(Some(original[:])) {
    Data(out) => cbuf.write_bytes(out)
    Ok | End | Error(_) => ()
  }
  loop deflater.encode(None) {
    Data(out) => {
      cbuf.write_bytes(out)
      continue deflater.encode(None)
    }
    End | Ok | Error(_) => break
  }
  let stream_compressed = cbuf.to_bytes()

  let inflater = @br.Inflater::new()
  let dbuf = @buffer.new()
  inflater.src(stream_compressed[:])
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
  let result : Result[Bytes, Error] = try? @br.decompress(b"\x00\x01\x02")
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
