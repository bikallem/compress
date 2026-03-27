///|
test "round-trip: small data" {
  let test_data : Array[Bytes] = [
    b"a",
    b"Hello, World!",
    b"The quick brown fox jumps over the lazy dog.",
    Bytes::makei(100, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @brotli.compress(data)
    let decompressed = @brotli.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: 1KB data" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  inspect(decompressed.length(), content="1024")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 10KB data" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  inspect(decompressed.length(), content="10000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
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
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: all zeros 1KB" {
  let data = Bytes::make(1024, b'\x00')
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: all byte values" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: dictionary words compress well" {
  let data = b"function return value"
  let compressed = @brotli.compress(data, level=Best)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, data)
  assert_true(compressed.length() <= 18)
}

///|
fn brotli_search_depth_fixture() -> Bytes {
  let long = b"ABCDabcdefghijklmnopqrstuvwxyz0123456789"
  let short = b"ABCDzzzz"
  let buf = @blit.Buffer::new()
  for i in 0..<96 {
    buf.write_bytes(long)
    buf.write_byte((i % 251).to_byte())
    buf.write_bytes(b"--")
    buf.write_bytes(short)
    buf.write_byte((i * 17 % 251).to_byte())
    buf.write_bytes(b"++")
    buf.write_bytes(long)
    buf.write_byte((i % 13).to_byte())
    buf.write_bytes(b"\n")
  }
  buf.to_bytes()
}

///|
test "higher Brotli levels search deeper hash history" {
  let data = brotli_search_depth_fixture()
  let lvl9 = @brotli.compress(data, level=Level(9))
  let lvl11 = @brotli.compress(data, level=Level(11))
  assert_eq(@brotli.decompress(lvl9), data)
  assert_eq(@brotli.decompress(lvl11), data)
  assert_true(lvl11.length() <= lvl9.length())
}

///|
test "signal protocol: inflater accepts chunked input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @brotli.compress(data)
  let d = @brotli.Inflater::new()
  let buf = @blit.Buffer::new()
  let chunk_size = 7
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
  let d = @brotli.Deflater::new()
  let buf = @blit.Buffer::new()
  match d.encode(Some(data[:512])) {
    Ok => fail("brotli deflater should emit after first chunk")
    Data(out) => buf.write_bytesview(out)
    End => fail("brotli deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(Some(data[512:])) {
    Ok => fail("brotli deflater should emit after second chunk")
    Data(out) => buf.write_bytesview(out)
    End => fail("brotli deflater should not end before finish")
    Error(e) => raise e
  }
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok => fail("brotli finalization should not return Ok")
    Error(e) => raise e
  }
  let compressed = buf.to_bytes()
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
test "round-trip: 20MB default (multi-metablock)" {
  let data = Bytes::makei(20_000_000, fn(i) { (i % 256).to_byte() })
  let compressed = @brotli.compress(data)
  let decompressed = @brotli.decompress(compressed)
  inspect(decompressed.length(), content="20000000")
  // Check first mismatch position
  let mut first_diff = -1
  for i in 0..<decompressed.length() {
    if decompressed[i] != data[i] {
      first_diff = i
      break
    }
  }
  inspect(first_diff, content="-1")
}
