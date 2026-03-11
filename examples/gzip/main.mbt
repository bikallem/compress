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
  let compressed = @gz.compress(original)
  println(
    "gzip compressed: \{original.length()} -> \{compressed.length()} bytes",
  )

  // --- Decompress (returns data + header) ---
  let (restored, header) = @gz.decompress(compressed)
  assert_eq(restored, original)
  println("Round-trip: OK")
  println("Header OS: \{header.os}")

  // --- Compress with custom header ---
  let hdr : @gz.Header = {
    name: "example.txt",
    comment: "compressed by blem/compress",
    extra: b"",
    mod_time: 1709856000U,
    os: b'\xff',
  }
  let compressed2 = @gz.compress(original, header=hdr, level=BestCompression)
  let (restored2, header2) = @gz.decompress(compressed2)
  assert_eq(restored2, original)
  println("Name:    \{header2.name}")
  println("Comment: \{header2.comment}")

  // --- Compress with different levels ---
  let fast = @gz.compress(original, level=BestSpeed)
  let best = @gz.compress(original, level=BestCompression)
  println("BestSpeed:       \{fast.length()} bytes")
  println("BestCompression: \{best.length()} bytes")

  // --- Streaming API (signal protocol) ---
  let deflater = @gz.Deflater::new(
    header={
      name: "streamed.txt",
      comment: "",
      extra: Bytes::default(),
      mod_time: 0U,
      os: b'\xFF',
    },
  )
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

  let inflater = @gz.Inflater::new()
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
  println(
    "Streaming: \{stream_compressed.length()} bytes, header.name=\"\{inflater.header().name}\"",
  )

  // --- Error handling ---
  let result : Result[(Bytes, @gz.Header), Error] = try? @gz.decompress(
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
