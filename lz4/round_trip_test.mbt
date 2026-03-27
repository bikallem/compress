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
  let buf = @blit.Buffer::new()
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
  let buf = @blit.Buffer::new()
  let chunk_size = 7
  let mut pos = 0
  let mut finished = false
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        if finished {
          fail("unexpected Await after lz4 finish")
        }
        d.finish()
        finished = true
        continue d.decode()
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
  let d = @lz4.Deflater::new()
  let buf = @blit.Buffer::new()
  match d.encode(Some(data[:512])) {
    Ok => fail("lz4 deflater should emit after first chunk")
    Data(out) => buf.write_bytesview(out)
    End => fail("lz4 deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(Some(data[512:])) {
    Ok => fail("lz4 deflater should emit after second chunk")
    Data(out) => buf.write_bytesview(out)
    End => fail("lz4 deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(None) {
    Data(out) => buf.write_bytesview(out)
    End => ()
    Ok => ()
    Error(e) => raise e
  }
  let compressed = buf.to_bytes()
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "signal protocol: inflater consumes concatenated frames" {
  let compressed = @lz4.compress(b"first frame") +
    @lz4.compress(b"second frame")
  let d = @lz4.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src(compressed[:])
  loop d.decode() {
    Await => {
      d.finish()
      continue d.decode()
    }
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), b"first framesecond frame")
}

///|
test "signal protocol: deflater supports external dictionaries" {
  let dict = b"shared dictionary block shared dictionary block shared dictionary block"
  let data = b"shared dictionary block shared dictionary block frame payload"
  let d = @lz4.Deflater::new_with_content_size(data.length(), dict~, options={
    block_independence: true,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0x0BADF00DU,
    block_max_size: Size64KB,
  })
  let out = @blit.Buffer::new()
  match d.encode(Some(data[:24])) {
    Data(chunk) => out.write_bytesview(chunk)
    Ok => fail("expected LZ4 streaming output after first chunk")
    End => fail("lz4 deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(Some(data[24:])) {
    Data(chunk) => out.write_bytesview(chunk)
    Ok => fail("expected LZ4 streaming output after second chunk")
    End => fail("lz4 deflater should not end before finish")
    Error(e) => raise e
  }
  loop d.encode(None) {
    Data(chunk) => {
      out.write_bytesview(chunk)
      continue d.encode(None)
    }
    End => break
    Ok => break
    Error(e) => raise e
  }
  let compressed = out.to_bytes()
  assert_true((compressed[4].to_int() & 0x01) != 0)
  let result = try? @lz4.decompress(compressed)
  guard result is Err(_) else {
    fail("expected dictionary-backed frame to require a dictionary")
  }
  let i = @lz4.Inflater::new_with_dictionary(
    @lz4.Dictionary::new(dict, dict_id=0x0BADF00DU),
  )
  let decoded = @blit.Buffer::new()
  i.src(compressed[:])
  i.finish()
  loop i.decode() {
    Await => fail("expected full compressed frame to decode without awaiting")
    Data(chunk) => {
      decoded.write_bytesview(chunk)
      continue i.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(decoded.to_bytes(), data)
}
