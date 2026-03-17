///|
test "round-trip: empty data" {
  let compressed = @brotli.compress(b"")
  assert_eq(compressed, b"\x06")
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, b"")
}

///|
test "round-trip: small data" {
  let data = b"The quick brown fox jumps over the lazy dog."
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "round-trip: large data" {
  let data = Bytes::makei(100000, fn(i) { (i % 251).to_byte() })
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "round-trip: chunked inflater input" {
  let data = Bytes::makei(70000, fn(i) { (i % 256).to_byte() })
  let compressed = @brotli.compress(data)
  let inflater = @brotli.Inflater::new()
  let out = @buffer.new()
  let mut pos = 0
  loop inflater.decode() {
    Await =>
      if pos >= compressed.length() {
        fail("unexpected Await after all compressed bytes consumed")
      } else {
        let end = if pos + 5 > compressed.length() {
          compressed.length()
        } else {
          pos + 5
        }
        let chunk = Bytes::makei(end - pos, fn(i) { compressed[pos + i] })
        inflater.src(chunk[:])
        pos = end
        continue inflater.decode()
      }
    Data(chunk) => {
      out.write_bytes(chunk)
      continue inflater.decode()
    }
    End => assert_eq(out.to_bytes(), data)
    Error(e) => raise e
  }
}

///|
test "round-trip: chunked deflater input" {
  let data = Bytes::makei(4096, fn(i) { (i * 17 % 251).to_byte() })
  let deflater = @brotli.Deflater::new()
  let out = @buffer.new()
  let mut pos = 0
  while pos < data.length() {
    let end = if pos + 257 > data.length() { data.length() } else { pos + 257 }
    let chunk = Bytes::makei(end - pos, fn(i) { data[pos + i] })
    match deflater.encode(Some(chunk[:])) {
      Ok => ()
      Data(bits) => out.write_bytes(bits)
      End => fail("unexpected end while feeding input")
      Error(e) => raise e
    }
    pos = end
  }
  loop deflater.encode(None) {
    Ok => continue deflater.encode(None)
    Data(bits) => {
      out.write_bytes(bits)
      continue deflater.encode(None)
    }
    End => break
    Error(e) => raise e
  }
  let decompressed = @brotli.decompress(out.to_bytes())
  assert_eq(decompressed, data)
}
