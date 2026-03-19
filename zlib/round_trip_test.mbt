///|
test "round-trip: all compression levels" {
  let test_data : Array[Bytes] = [
    b"",
    b"a",
    b"Hello, World!",
    Bytes::makei(1000, fn(i) { (i % 256).to_byte() }),
    Bytes::makei(10000, fn(i) { (i % 26 + 65).to_byte() }),
  ]
  for data in test_data {
    for
      lvl in [
        @flate.NoCompression,
        @flate.BestSpeed,
        @flate.Level(3),
        @flate.DefaultCompression,
        @flate.BestCompression,
        @flate.HuffmanOnly,
      ] {
      let compressed = @zlib.compress(data, level=lvl)
      let decompressed = @zlib.decompress(compressed)
      inspect(decompressed == data, content="true")
    }
  }
}

///|
test "round-trip: large repetitive data" {
  let buf = @buffer.new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @zlib.compress(data, level=@flate.BestCompression)
  let decompressed = @zlib.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Must actually compress
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: 32KB boundary all levels" {
  let data = Bytes::makei(32768, fn(i) { (i % 256).to_byte() })
  for
    lvl in [
      @flate.NoCompression,
      @flate.BestSpeed,
      @flate.Level(3),
      @flate.DefaultCompression,
      @flate.BestCompression,
    ] {
    let compressed = @zlib.compress(data, level=lvl)
    let decompressed = @zlib.decompress(compressed)
    inspect(decompressed.length(), content="32768")
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: sizes around 32KB" {
  for size in [32000, 32700, 32767, 32768, 32769, 33000, 40000, 65536] {
    let data = Bytes::makei(size, fn(i) { (i % 256).to_byte() })
    let compressed = @zlib.compress(data)
    let decompressed = @zlib.decompress(compressed)
    if decompressed.length() != size {
      fail("size \{size}: got \{decompressed.length()}")
    }
  }
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 200KB data (issue #4 stack overflow regression)" {
  let data = Bytes::make(200_000, b'\x41')
  let compressed = @zlib.compress(data)
  let decompressed = @zlib.decompress(compressed)
  inspect(decompressed.length(), content="200000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: with dictionary" {
  let dict : Bytes = b"the quick brown fox jumps over the lazy dog abcdefghijklmnop"
  let test_data : Array[Bytes] = [
    b"the quick brown fox",
    Bytes::makei(1000, fn(i) { (i % 256).to_byte() }),
    Bytes::makei(10000, fn(i) { (i % 26 + 97).to_byte() }),
  ]
  for data in test_data {
    let compressed = @zlib.compress(data, dict~)
    let decompressed = @zlib.decompress(compressed, dict~)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: dictionary with all compression levels" {
  let dict : Bytes = b"common prefix data that appears frequently in the input stream"
  let data = Bytes::makei(5000, fn(i) { (i % 26 + 65).to_byte() })
  for
    lvl in [
      @flate.NoCompression,
      @flate.BestSpeed,
      @flate.DefaultCompression,
      @flate.BestCompression,
    ] {
    let compressed = @zlib.compress(data, dict~, level=lvl)
    let decompressed = @zlib.decompress(compressed, dict~)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: dictionary improves compression of matching data" {
  let dict : Bytes = b"abcdefghijklmnop"
  // Data that heavily reuses the dictionary content
  let buf = @buffer.new()
  for _ in 0..<256 {
    buf.write_bytes(b"abcdefghijklmnop")
  }
  let data = buf.to_bytes()
  let compressed_no_dict = @zlib.compress(data)
  let compressed_with_dict = @zlib.compress(data, dict~)
  // With dictionary should compress at least as well
  inspect(
    compressed_with_dict.length() <= compressed_no_dict.length(),
    content="true",
  )
  // Both should roundtrip correctly
  let d1 = @zlib.decompress(compressed_no_dict)
  inspect(d1 == data, content="true")
  let d2 = @zlib.decompress(compressed_with_dict, dict~)
  inspect(d2 == data, content="true")
}

///|
test "signal protocol: chunked input" {
  let data : Bytes = b"Hello, World!"
  let compressed = @zlib.compress(data)
  let d = @zlib.Inflater::new()
  let buf = @buffer.new()
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
      } else {
        d.src([compressed[pos]])
        pos += 1
        continue d.decode()
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
test "signal protocol: chunked input 1KB" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @zlib.compress(data)
  let d = @zlib.Inflater::new()
  let buf = @buffer.new()
  let mut pos = 0
  // Feed in 16-byte chunks
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
      } else {
        let end = if pos + 16 > compressed.length() {
          compressed.length()
        } else {
          pos + 16
        }
        let chunk = Bytes::makei(end - pos, fn(i) { compressed[pos + i] })
        d.src(chunk)
        pos = end
        continue d.decode()
      }
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue d.decode()
    }
    End => inspect(buf.to_bytes() == data, content="true")
    Error(e) => raise e
  }
}
