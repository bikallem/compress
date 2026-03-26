///|
test "round-trip: small data" {
  let test_data : Array[Bytes] = [
    b"a",
    b"Hello, World!",
    b"The quick brown fox jumps over the lazy dog.",
    Bytes::makei(100, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @snappy.compress(data)
    let decompressed = @snappy.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: 1KB data" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
  inspect(decompressed.length(), content="1024")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 10KB data" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
  inspect(decompressed.length(), content="10000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
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
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Must actually compress
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all zeros" {
  let data = Bytes::make(10000, b'\x00')
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
  inspect(decompressed == data, content="true")
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all 0xFF" {
  let data = Bytes::make(10000, b'\xFF')
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: all byte values" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @snappy.compress(data)
  let decompressed = @snappy.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "signal protocol: chunked input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @snappy.compress(data)
  let d = @snappy.Inflater::new()
  let buf = @blit.Buffer::new()
  let chunk_size = 5
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
  let d = @snappy.Deflater::new_known_length(data.length())
  let buf = @blit.Buffer::new()
  match d.encode(Some(data[:512])) {
    Ok => fail("snappy deflater should emit after first chunk")
    Data(out) => buf.write_bytesview(out)
    End => fail("snappy deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(Some(data[512:])) {
    Ok => fail("snappy deflater should emit after second chunk")
    Data(out) => buf.write_bytesview(out)
    End => fail("snappy deflater should not end before finish")
    Error(e) => raise e
  }
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok => fail("snappy finalization should not return Ok")
    Error(e) => raise e
  }
  let compressed = buf.to_bytes()
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "signal protocol: deflater buffered mode is explicit" {
  let data = b"buffered snappy payload buffered snappy payload"
  let d = @snappy.Deflater::new_buffered()
  match d.encode(Some(data[:16])) {
    Ok => ()
    Data(_) => fail("buffered snappy mode should not emit before finish")
    End => fail("buffered snappy mode should not end before finish")
    Error(e) => raise e
  }
  match d.encode(Some(data[16:])) {
    Ok => ()
    Data(_) => fail("buffered snappy mode should not emit before finish")
    End => fail("buffered snappy mode should not end before finish")
    Error(e) => raise e
  }
  let out = @blit.Buffer::new()
  loop d.encode(None) {
    Data(chunk) => {
      out.write_bytesview(chunk)
      continue d.encode(None)
    }
    End => break
    Ok => fail("buffered snappy finalization should not return Ok")
    Error(e) => raise e
  }
  let compressed = out.to_bytes()
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "signal protocol: deflater new() defaults to buffered mode" {
  let data = b"default constructor uses buffered snappy mode"
  let d = @snappy.Deflater::new()
  match d.encode(Some(data[:16])) {
    Ok => ()
    Data(_) => fail("default snappy constructor should buffer without length")
    End => fail("snappy deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(Some(data[16:])) {
    Ok => ()
    Data(_) => fail("default snappy constructor should buffer without length")
    End => fail("snappy deflater should not end before finish")
    Error(e) => raise e
  }
  let out = @blit.Buffer::new()
  loop d.encode(None) {
    Data(chunk) => {
      out.write_bytesview(chunk)
      continue d.encode(None)
    }
    End => break
    Ok => fail("buffered snappy finalization should not return Ok")
    Error(e) => raise e
  }
  let compressed = out.to_bytes()
  let decompressed = @snappy.decompress(compressed)
  assert_eq(decompressed, data)
}
