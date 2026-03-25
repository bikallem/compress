///|
test "round-trip: small data" {
  let test_data : Array[Bytes] = [
    b"a",
    b"Hello, World!",
    b"The quick brown fox jumps over the lazy dog.",
    Bytes::makei(100, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @zstd.compress(data)
    let decompressed = @zstd.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: 1KB data" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed.length(), content="1024")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 10KB data" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed.length(), content="10000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: large repetitive data" {
  let buf = @blit.Buffer::new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Compressed blocks should achieve meaningful compression on repetitive data
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all zeros 1KB" {
  let data = Bytes::make(1024, b'\x00')
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed == data, content="true")
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all byte values" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 1MB repeating text" {
  let pattern = "The quick brown fox jumps over the lazy dog. "
  let pattern_bytes = @utf8.encode(pattern[:])
  let plen = pattern_bytes.length()
  let buf = @blit.Buffer::new()
  let mut written = 0
  while written + plen <= 1048576 {
    buf.write_bytes(pattern_bytes)
    written += plen
  }
  let remaining = 1048576 - written
  for i in 0..<remaining {
    buf.write_byte(pattern_bytes[i])
  }
  let data = buf.to_bytes()
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(data.length(), decompressed.length())
  assert_eq(data, decompressed)
  // Should compress very well
  assert_true(compressed.length() < 300)
}

///|
test "signal protocol: chunked input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let d = @zstd.Inflater::new()
  let buf = @blit.Buffer::new()
  let chunk_size = 11
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
        break
      } else {
        let end = if pos + chunk_size > compressed.length() {
          compressed.length()
        } else {
          pos + chunk_size
        }
        let chunk = Bytes::makei(end - pos, fn(i) { compressed[pos + i] })
        d.src(chunk[:])
        pos = end
        continue d.decode()
      }
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => inspect(buf.to_bytes() == data, content="true")
    Error(e) => raise e
  }
}

///|
test "signal protocol: deflater streaming" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let d = @zstd.Deflater::new()
  match d.encode(Some(data[:512])) {
    Ok => ()
    Data(_) | End => ()
    Error(e) => raise e
  }
  match d.encode(Some(data[512:])) {
    Ok => ()
    Data(_) | End => ()
    Error(e) => raise e
  }
  let buf = @blit.Buffer::new()
  match d.encode(None) {
    Data(out) => buf.write_bytesview(out)
    End => ()
    Ok => ()
    Error(e) => raise e
  }
  let compressed = buf.to_bytes()
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, data)
}
