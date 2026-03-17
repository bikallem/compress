///|
test "round-trip: small data" {
  let test_data : Array[Bytes] = [
    b"a",
    b"Hello, World!",
    b"The quick brown fox jumps over the lazy dog.",
    Bytes::makei(100, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @lz4.compress(data)
    let decompressed = @lz4.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: 1KB data" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed.length(), content="1024")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 10KB data" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed.length(), content="10000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: large repetitive data" {
  let buf = @buffer.new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed == data, content="true")
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all zeros" {
  let data = Bytes::make(10000, b'\x00')
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed == data, content="true")
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all 0xFF" {
  let data = Bytes::make(10000, b'\xFF')
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: all byte values" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @lz4.compress(data)
  let decompressed = @lz4.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "signal protocol: chunked input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @lz4.compress(data)
  let d = @lz4.Inflater::new()
  d.src(compressed[:])
  let buf = @buffer.new()
  loop d.decode() {
    Await => {
      inspect(false, content="true")
      break
    }
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue d.decode()
    }
    End => inspect(buf.to_bytes() == data, content="true")
    Error(e) => raise e
  }
}

///|
test "signal protocol: deflater streaming" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let d = @lz4.Deflater::new()
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
  let buf = @buffer.new()
  match d.encode(None) {
    Data(out) => buf.write_bytes(out)
    End => ()
    Ok => ()
    Error(e) => raise e
  }
  let compressed = buf.to_bytes()
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, data)
}
